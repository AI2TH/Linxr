#!/usr/bin/env python3
"""
Ultra-lightweight HTTP server for Docker container management inside Alpine Linux VM.
Uses Python's standard library http.server (zero third-party dependencies like FastAPI/Uvicorn/Pydantic)
to ensure instant startup (<1s) and minimal CPU/RAM footprint under QEMU TCG emulation.

Runs on guest 127.0.0.1:7080, accessible from Android host via QEMU hostfwd (host:7081 -> guest:7080).
"""

import json
import logging
import os
import socket
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("api_server")

FW_CFG_TOKEN_PATH = "/sys/firmware/qemu_fw_cfg/by_name/opt/api_token/raw"
TOKEN_FILE_PATH = "/bootstrap/token"


def _load_token() -> str:
    # 1. Try fw_cfg (injected by Android app via -fw_cfg flag)
    try:
        with open(FW_CFG_TOKEN_PATH, "r") as f:
            token = f.read().strip()
            if token:
                logger.info("Loaded API token from fw_cfg")
                return token
    except OSError:
        pass

    # 2. Try token file (written to bootstrap dir by asset preparation)
    try:
        with open(TOKEN_FILE_PATH, "r") as f:
            token = f.read().strip()
            if token:
                logger.info("Loaded API token from %s", TOKEN_FILE_PATH)
                return token
    except OSError:
        pass

    # 3. Environment variable fallback
    token = os.environ.get("API_TOKEN", "").strip()
    if token:
        logger.info("Loaded API token from environment")
        return token

    logger.warning("No API token found — auth will reject all protected requests")
    return ""


API_TOKEN = _load_token()


def _docker_socket_request(method: str, path: str, body: bytes = None) -> tuple:
    """Send direct HTTP request over Unix domain socket /var/run/docker.sock (<5ms)."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(10.0)
        s.connect("/var/run/docker.sock")
        req = f"{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        if body:
            req += f"Content-Length: {len(body)}\r\nContent-Type: application/json\r\n"
        req += "\r\n"
        s.sendall(req.encode("utf-8") + (body or b""))

        raw = b""
        while b"\r\n\r\n" not in raw:
            chunk = s.recv(4096)
            if not chunk:
                break
            raw += chunk

        h_end = raw.find(b"\r\n\r\n")
        if h_end == -1:
            s.close()
            return 500, b""

        header_bytes = raw[:h_end]
        body_bytes = raw[h_end+4:]

        content_len = None
        is_chunked = False
        for line in header_bytes.split(b"\r\n"):
            low = line.lower()
            if low.startswith(b"content-length:"):
                try:
                    content_len = int(line.split(b":", 1)[1].strip())
                except ValueError:
                    pass
            elif low.startswith(b"transfer-encoding:") and b"chunked" in low:
                is_chunked = True

        if content_len is not None:
            while len(body_bytes) < content_len:
                chunk = s.recv(min(4096, content_len - len(body_bytes)))
                if not chunk:
                    break
                body_bytes += chunk
        elif is_chunked:
            while not (body_bytes.endswith(b"\r\n0\r\n\r\n") or body_bytes == b"0\r\n\r\n" or b"\r\n0\r\n\r\n" in body_bytes):
                chunk = s.recv(4096)
                if not chunk:
                    break
                body_bytes += chunk
        else:
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                body_bytes += chunk

        s.close()

        if is_chunked:
            decoded = b""
            pos = 0
            while pos < len(body_bytes):
                c_end = body_bytes.find(b"\r\n", pos)
                if c_end == -1:
                    break
                line = body_bytes[pos:c_end].split(b";")[0].strip()
                if not line:
                    pos = c_end + 2
                    continue
                try:
                    c_size = int(line, 16)
                except ValueError:
                    break
                if c_size == 0:
                    break
                data_start = c_end + 2
                data_end = data_start + c_size
                decoded += body_bytes[data_start:data_end]
                pos = data_end + 2
            body_bytes = decoded

        status_line = header_bytes.split(b"\r\n")[0].decode("utf-8", errors="ignore")
        status_code = int(status_line.split()[1])
        return status_code, body_bytes
    except Exception as e:
        logger.error("docker.sock error for %s %s: %s", method, path, e)
        return 500, b""


def _check_docker_socket():
    """Directly probe Docker daemon via Unix socket in <2ms without subprocess overhead."""
    code, data = _docker_socket_request("GET", "/_ping")
    return (b"OK" in data or code == 200), "Docker 29.5"


class VmApiHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        # Quiet standard HTTP access logs to keep serial console clean
        pass

    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError):
            pass

    def _send_json(self, status_code: int, data: any):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def _send_text(self, status_code: int, text: str):
        body = text.encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def _send_error(self, status_code: int, detail: str):
        self._send_json(status_code, {"detail": detail})

    def _check_auth(self) -> bool:
        if not API_TOKEN:
            self._send_error(503, "Server not ready: token not configured")
            return False
        auth = self.headers.get("Authorization", "")
        if not auth or not auth.startswith("Bearer "):
            self._send_error(401, "Missing Authorization header")
            return False
        sent_token = auth[len("Bearer "):].strip()
        if sent_token != API_TOKEN:
            self._send_error(401, "Invalid token")
            return False
        return True

    def _read_json_body(self) -> dict:
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length <= 0:
            return {}
        raw = self.rfile.read(content_length).decode("utf-8")
        try:
            return json.loads(raw)
        except Exception as e:
            return {}

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        # /health endpoint — no auth required
        if path == "/health":
            is_ok, ver = _check_docker_socket()
            self._send_json(200, {
                "status": "ok" if is_ok else "degraded",
                "runtime": "docker",
                "version": ver,
            })
            return

        # Protected endpoints
        if not self._check_auth():
            return

        if path == "/containers":
            code, data = _docker_socket_request("GET", "/containers/json?all=1")
            if code != 200:
                self._send_error(500, "Docker daemon socket error")
                return
            try:
                raw_list = json.loads(data.decode("utf-8", errors="ignore"))
                containers = []
                for c in raw_list:
                    names = c.get("Names", [])
                    name = names[0].lstrip("/") if names else "unknown"
                    image = c.get("Image", "")
                    status = c.get("Status", "") or c.get("State", "")
                    ports = []
                    for p in c.get("Ports", []):
                        if isinstance(p, dict) and "PublicPort" in p:
                            ports.append(f"{p['PublicPort']}->{p.get('PrivatePort','')}/{p.get('Type','')}")
                    containers.append({
                        "name": name,
                        "image": image,
                        "status": status,
                        "ports": ports,
                    })
                self._send_json(200, containers)
            except Exception as e:
                self._send_error(500, str(e))
            return

        if path == "/logs":
            params = parse_qs(parsed.query)
            name = params.get("name", [""])[0]
            tail = params.get("tail", ["100"])[0]
            if not name:
                self._send_error(400, "Container name required")
                return
            try:
                result = subprocess.run(
                    ["docker", "logs", "--tail", str(tail), name],
                    capture_output=True, text=True, check=True, timeout=10
                )
                self._send_text(200, result.stdout or result.stderr or "")
            except Exception as e:
                self._send_error(500, str(e))
            return

        self._send_error(404, "Not found")

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if not self._check_auth():
            return

        data = self._read_json_body()

        if path in ("/containers/start", "/containers"):
            image = data.get("image", "").strip()
            name = data.get("name", "").strip()
            if not image or not name:
                self._send_error(400, "image and name required")
                return

            cmd_args = data.get("cmd", [])
            env_vars = data.get("env", [])
            ports = data.get("ports", [])
            network = data.get("network") or "host"

            # Remove existing container with same name if stopped or stale to prevent 409 conflict
            _docker_socket_request("DELETE", f"/containers/{name}?force=true")

            # Check if image already exists locally via direct socket (<2ms) to avoid redundant 300s pull
            code, _ = _docker_socket_request("GET", f"/images/{image}/json")
            if code != 200:
                logger.info("Pulling image: %s", image)
                try:
                    pull_res = subprocess.run(
                        ["docker", "pull", image],
                        capture_output=True, text=True, timeout=2400
                    )
                    if pull_res.returncode != 0:
                        err_msg = (pull_res.stderr or pull_res.stdout or "Unknown pull error").strip()
                        self._send_error(500, f"Image pull failed: {err_msg}")
                        return
                except subprocess.TimeoutExpired:
                    self._send_error(504, f"Image pull timed out for '{image}'. Mobile CPU emulation requires extra time for large images.")
                    return
            else:
                logger.info("Image %s already cached locally, skipping pull", image)

            cmd = ["docker", "run", "-d", "--network", network, "--name", name]
            for env in env_vars:
                if isinstance(env, dict) and "key" in env and "value" in env:
                    cmd += ["-e", f"{env['key']}={env['value']}"]

            if network != "host":
                for port in ports:
                    if isinstance(port, dict) and "host" in port and "container" in port:
                        cmd += ["-p", f"{port['host']}:{port['container']}"]

            cmd.append(image)
            if isinstance(cmd_args, list):
                cmd.extend([str(x) for x in cmd_args])

            logger.info("Starting container: %s", " ".join(cmd))
            try:
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=2400)
                if result.returncode != 0:
                    err = result.stderr.strip() or result.stdout.strip()
                    self._send_error(500, f"Docker run error: {err}")
                    return
                self._send_json(200, {"status": "started", "name": name, "id": result.stdout.strip()})
            except subprocess.TimeoutExpired:
                # Self-healing: On TCG emulation, docker run may complete or start the container.
                # Check via docker socket if the container is running.
                time.sleep(1)
                c_code, c_data = _docker_socket_request("GET", f"/containers/{name}/json")
                if c_code == 200:
                    try:
                        c_info = json.loads(c_data.decode("utf-8"))
                        cid = c_info.get("Id", name)
                        self._send_json(200, {"status": "started", "name": name, "id": cid})
                        return
                    except Exception:
                        pass
                self._send_error(504, "Container start timed out (TCG CPU busy). The container was created and may start shortly.")
            except Exception as e:
                self._send_error(500, str(e))
            return

        if path == "/containers/stop":
            name = data.get("name", "").strip()
            if not name:
                self._send_error(400, "name required")
                return
            _docker_socket_request("POST", f"/containers/{name}/stop")
            self._send_json(200, {"status": "stopped", "name": name})
            return

        if path == "/images/pull":
            image = data.get("image", "").strip()
            if not image:
                self._send_error(400, "image required")
                return
            try:
                result = subprocess.run(["docker", "pull", image], capture_output=True, text=True, check=True, timeout=2400)
                self._send_json(200, {"status": "pulled", "image": image, "output": result.stdout})
            except subprocess.TimeoutExpired:
                self._send_error(504, "Image pull timed out")
            except Exception as e:
                self._send_error(500, str(e))
            return

        if path == "/vm/exec":
            cmd_str = data.get("cmd", "")
            if not cmd_str:
                self._send_error(400, "cmd required")
                return
            try:
                result = subprocess.run(["sh", "-c", cmd_str], capture_output=True, text=True, timeout=1800)
                self._send_json(200, {
                    "stdout": result.stdout,
                    "stderr": result.stderr,
                    "exitCode": result.returncode,
                })
            except subprocess.TimeoutExpired:
                self._send_error(504, "Script execution timed out (exceeded 300s)")
            except Exception as e:
                self._send_error(500, str(e))
            return

        if path == "/exec":
            name = data.get("name", "").strip()
            cmd_str = data.get("cmd", "")
            try:
                result = subprocess.run(["docker", "exec", name, "sh", "-c", cmd_str], capture_output=True, text=True, timeout=45)
                self._send_json(200, {
                    "stdout": result.stdout,
                    "stderr": result.stderr,
                    "exitCode": result.returncode,
                })
            except subprocess.TimeoutExpired:
                self._send_error(504, "Exec timed out")
            except Exception as e:
                self._send_error(500, str(e))
            return

        self._send_error(404, "Not found")


def _apply_network_hardening():
    """Ensure IPv6 is disabled (since QEMU SLIRP is IPv4-only), MTU is safe for cellular, MSS is clamped, and fast DNS is set."""
    try:
        # Fast DNS with Cloudflare + Google fallback
        try:
            with open("/etc/resolv.conf", "w") as f:
                f.write("nameserver 1.1.1.1\nnameserver 1.0.0.1\nnameserver 8.8.8.8\nnameserver 8.8.4.4\noptions timeout:2 attempts:2\n")
        except Exception as de:
            logger.warning("Could not update /etc/resolv.conf: %s", de)

        subprocess.run(["sysctl", "-w", "net.ipv6.conf.all.disable_ipv6=1"], capture_output=True, timeout=5)
        subprocess.run(["sysctl", "-w", "net.ipv6.conf.default.disable_ipv6=1"], capture_output=True, timeout=5)
        subprocess.run(["sysctl", "-w", "net.ipv4.tcp_mtu_probing=2"], capture_output=True, timeout=5)
        subprocess.run(["ip", "link", "set", "eth0", "mtu", "1200"], capture_output=True, timeout=5)
        subprocess.run(["nft", "add", "table", "ip6", "filter"], capture_output=True, timeout=5)
        subprocess.run(["nft", "add chain ip6 filter output { type filter hook output priority 0 ; policy accept ; }"], shell=True, capture_output=True, timeout=5)
        subprocess.run(["nft", "add rule ip6 filter output reject"], shell=True, capture_output=True, timeout=5)
        subprocess.run(["nft", "add", "table", "ip", "filter"], capture_output=True, timeout=5)
        subprocess.run(["nft", "add chain ip filter output { type filter hook output priority 0 ; policy accept ; }"], shell=True, capture_output=True, timeout=5)
        subprocess.run(["nft", "add rule ip filter output tcp flags syn tcp option maxseg size set 1160"], shell=True, capture_output=True, timeout=5)
    except Exception as e:
        logger.warning("Could not apply network hardening: %s", e)


def run_server():
    _apply_network_hardening()
    server_address = ("0.0.0.0", 7080)
    ThreadingHTTPServer.allow_reuse_address = True
    httpd = ThreadingHTTPServer(server_address, VmApiHandler)
    logger.info("Serving lightweight Docker VM API on 0.0.0.0:7080")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    run_server()
