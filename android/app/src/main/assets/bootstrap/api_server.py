#!/usr/bin/env python3
"""
Ultra-lightweight HTTP server for Docker container management inside Alpine Linux VM.
Uses Python's standard library http.server (zero third-party dependencies like FastAPI/Uvicorn/Pydantic)
to ensure instant startup (<1s) and minimal CPU/RAM footprint under QEMU TCG emulation.

Listens on guest 0.0.0.0:7080 (QEMU SLIRP hostfwd delivers to the guest's
10.0.2.15, so loopback-only would be unreachable); the Android host reaches it
via hostfwd host 127.0.0.1:7081 -> guest 7080. Every endpoint except /health
requires the bearer token.
"""

import hmac
import json
import logging
import os
import re
import socket
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlparse

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

    # 2. Try kernel cmdline (/proc/cmdline: api_token=...)
    try:
        with open("/proc/cmdline", "r") as f:
            cmdline = f.read()
            for part in cmdline.split():
                if part.startswith("api_token="):
                    token = part.split("=", 1)[1].strip()
                    if token:
                        logger.info("Loaded API token from /proc/cmdline")
                        return token
    except OSError:
        pass

    # 3. Legacy token file. Current app versions no longer write it to the
    #    shared folder (external storage other apps can read); older ones did.
    try:
        with open(TOKEN_FILE_PATH, "r") as f:
            token = f.read().strip()
            if token:
                logger.info("Loaded API token from %s", TOKEN_FILE_PATH)
                return token
    except OSError:
        pass

    # 4. Environment variable fallback
    token = os.environ.get("API_TOKEN", "").strip()
    if token:
        logger.info("Loaded API token from environment")
        return token

    logger.warning("No API token found — auth will reject all protected requests")
    return ""


API_TOKEN = _load_token()

# Container names / IDs and image references are passed to the docker/podman
# CLI and interpolated into Docker Engine API paths. Reject anything that could
# be read as a CLI option (leading "-") or break the HTTP request line
# (whitespace, CR/LF, "?", "#").
_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$")
_IMAGE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/:@+-]{0,511}$")


def _valid_name(name) -> bool:
    return isinstance(name, str) and _NAME_RE.match(name) is not None


def _valid_image(image) -> bool:
    return isinstance(image, str) and _IMAGE_RE.match(image) is not None


def _q(value: str) -> str:
    """Percent-encode a validated name or image for a Docker Engine API path."""
    return quote(value, safe="/:@")


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


def _run_docker(args, timeout=1800):
    """Run a docker CLI command, returning (returncode, stdout, stderr)."""
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return result.returncode, result.stdout or "", result.stderr or ""
    except subprocess.TimeoutExpired:
        return 124, "", f"timed out after {timeout}s"
    except Exception as e:
        return -1, "", str(e)


# Guest-side export directory. Mirrors /mnt/sdcard (the Android-side shared folder
# mounted via virtio-9p), so exported tar files show up in the Files tab.
EXPORT_DIR = "/mnt/sdcard/linxr-exports"
GUEST_SHARE_DIR = "/mnt/sdcard"


def _safe_filename(name):
    """Sanitize a container/image name into a filesystem-safe filename stem."""
    safe = "".join(c if (c.isalnum() or c in "._-") else "_" for c in name)
    return safe.strip("._-") or "export"


def _resolve_share_file(file_name: str) -> str:
    """Safely resolve tar archive from shared folder or exports directory, preventing traversal."""
    if not file_name:
        return ""
    clean = os.path.basename(file_name.strip())
    # 1. Direct shared folder root
    p1 = os.path.join(GUEST_SHARE_DIR, clean)
    if os.path.isfile(p1):
        return p1
    # 2. Exports subfolder
    p2 = os.path.join(EXPORT_DIR, clean)
    if os.path.isfile(p2):
        return p2
    # 3. Explicit subpath without directory traversal
    p3 = os.path.realpath(os.path.join(GUEST_SHARE_DIR, file_name.strip()))
    if p3.startswith(GUEST_SHARE_DIR + os.sep) and os.path.isfile(p3):
        return p3
    return ""



def _is_port_listening(port_hex: str) -> bool:
    try:
        with open("/proc/net/tcp", "r") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 4 and parts[1].endswith(port_hex) and parts[3] == "0A":
                    return True
    except Exception:
        pass
    return False


# ── Virtual Desktop ──────────────────────────────────────────────────────────
# linxr-desktop.sh owns the desktop processes and records their state in the
# files below. /desktop/status reads those files directly, so the app's 5 s
# status poll never spawns a shell under TCG. Keep the paths and the "running"
# rule in sync with linxr-desktop.sh (status_json / desktop_healthy).
DESKTOP_STATE_DIR = "/run/linxr-desktop"
DESKTOP_LOG_DIR = "/var/log/linxr-desktop"
DESKTOP_CONF = "/etc/linxr/desktop.conf"
DESKTOP_X_SOCKET = "/tmp/.X11-unix/X1"
DESKTOP_VNC_PORT_HEX = ":170C"  # 5900
DESKTOP_WEB_PORT_HEX = ":17C0"  # 6080
DESKTOP_WEB_URL = (
    "http://127.0.0.1:6080/vnc.html?autoconnect=true&resize=scale&reconnect=true"
    "&reconnect_delay=2000&show_dot=true&path=websockify"
)
DESKTOP_WMS = {"openbox": "openbox", "lightweight": "openbox", "xfce4": "xfce4", "xfce": "xfce4", "full": "xfce4"}
DESKTOP_APPS = ("terminal", "files", "editor", "calculator", "calc")
DESKTOP_LOGS = ("desktop", "install", "xvfb", "wm", "panel", "xfdesktop", "xfsettingsd", "dbus", "x11vnc", "websockify", "apps")
# linxr-desktop gives up after 180 s; this only guards against a hung script.
DESKTOP_START_TIMEOUT = 300
# linxr-desktop exit codes -> HTTP status (anything else is a 500).
DESKTOP_RC_HTTP = {2: 400, 3: 409, 4: 409, 75: 409}
_desktop_start_lock = threading.Lock()


def _read_text(path: str) -> str:
    try:
        with open(path, "r", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def _tail_lines(path: str, n: int) -> list:
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 128 * 1024))
            data = f.read().decode("utf-8", errors="replace")
    except OSError:
        return []
    return data.splitlines()[-n:] if n > 0 else []


def _pid_alive(pid_str: str) -> bool:
    """True if the process exists and is not a zombie (os.kill(pid, 0) accepts zombies)."""
    if not pid_str.isascii() or not pid_str.isdigit():
        return False
    try:
        with open(f"/proc/{pid_str}/stat", "r") as f:
            stat = f.read()
    except OSError:
        return False
    fields = stat.rsplit(")", 1)[-1].split()
    return bool(fields) and fields[0] != "Z"


def _desktop_alive(name: str) -> bool:
    return _pid_alive(_read_text(os.path.join(DESKTOP_STATE_DIR, name + ".pid")))


def _has_bin(name: str) -> bool:
    return os.path.isfile(f"/usr/bin/{name}") or os.path.isfile(f"/usr/local/bin/{name}")


def _desktop_installed(wm: str) -> bool:
    base = (
        _has_bin("Xvfb") and _has_bin("x11vnc") and _has_bin("websockify") and
        os.path.isfile("/usr/share/novnc/vnc.html")
    )
    if not base:
        return False
    if wm == "xfce4":
        return _has_bin("xfwm4") and _has_bin("xfce4-panel")
    return _has_bin("openbox")


def _valid_resolution(value) -> bool:
    if not isinstance(value, str):
        return False
    w, sep, h = value.partition("x")
    if not sep or not (w.isascii() and w.isdigit() and h.isascii() and h.isdigit()):
        return False
    if len(w) > 4 or len(h) > 4:
        return False
    return 320 <= int(w) <= 4096 and 240 <= int(h) <= 4096


def _desktop_conf() -> tuple:
    res, wm = "1280x720", "openbox"
    for line in _read_text(DESKTOP_CONF).splitlines():
        key, _, value = line.partition("=")
        if key == "RES" and _valid_resolution(value):
            res = value
        elif key == "WM" and value in DESKTOP_WMS:
            wm = DESKTOP_WMS[value]
    return res, wm


def _desktop_install_info() -> dict:
    state = _read_text(os.path.join(DESKTOP_STATE_DIR, "install.state")) or "idle"
    error = _read_text(os.path.join(DESKTOP_STATE_DIR, "install.error"))
    if state == "running" and not _desktop_alive("install"):
        state = "failed"
        error = error or "The installer stopped unexpectedly; see the install log"
    progress, step = "", ""
    lines = [l for l in _tail_lines(os.path.join(DESKTOP_LOG_DIR, "install.log"), 60) if l.strip()]
    if lines:
        step = lines[-1].strip()[:160]
    for line in reversed(lines):
        s = line.strip()
        # apk prints "( 12/199) Installing foo (1.0-r0)"
        if s.startswith("(") and ")" in s:
            done, sep, total = s[1:s.index(")")].replace(" ", "").partition("/")
            if sep and done.isdigit() and total.isdigit():
                progress = f"{done}/{total}"
                break
    return {
        "install_state": state,
        "install_mode": _read_text(os.path.join(DESKTOP_STATE_DIR, "install.mode")),
        "install_progress": progress,
        "install_step": step,
        "install_error": error,
    }


def _get_desktop_status() -> dict:
    res, wm = _desktop_conf()
    xvfb = _desktop_alive("xvfb")
    wm_up = _desktop_alive("wm")
    vnc = _desktop_alive("x11vnc")
    ws = _desktop_alive("websockify")
    vnc_listening = _is_port_listening(DESKTOP_VNC_PORT_HEX)
    web_listening = _is_port_listening(DESKTOP_WEB_PORT_HEX)
    running = (
        xvfb and os.path.exists(DESKTOP_X_SOCKET) and wm_up and
        vnc and vnc_listening and ws and web_listening
    )
    supervised = _desktop_alive("monitor")
    state = _read_text(os.path.join(DESKTOP_STATE_DIR, "phase")) or "stopped"
    if running:
        state = "degraded" if state == "degraded" else "running"
    elif supervised:
        # The supervisor is starting the desktop or restarting a component.
        state = "starting" if state == "starting" else "degraded"
    elif state != "failed":
        state = "stopped"

    status = {
        "installed": _desktop_installed(wm),
        "running": running,
        "state": state,
        "supervised": supervised,
        "openbox_installed": _desktop_installed("openbox"),
        "xfce_installed": _desktop_installed("xfce4"),
        "xvfb": xvfb,
        "window_manager": wm_up,
        "x11vnc": vnc,
        "websockify": ws,
        "vnc_listening": vnc_listening,
        "web_listening": web_listening,
        "display": ":1",
        "resolution": res,
        "wm": wm,
        "web_port": 6080,
        "vnc_port": 5900,
        "web_url": DESKTOP_WEB_URL,
        "error": "" if state == "running" else _read_text(os.path.join(DESKTOP_STATE_DIR, "error")),
        "failed_component": _read_text(os.path.join(DESKTOP_STATE_DIR, "failed_component")),
        "stage": _read_text(os.path.join(DESKTOP_STATE_DIR, "stage")),
    }
    status.update(_desktop_install_info())
    return status


def _desktop_log_text(name: str, lines: int) -> str:
    if name != "all":
        return "\n".join(_tail_lines(os.path.join(DESKTOP_LOG_DIR, name + ".log"), lines))
    st = _get_desktop_status()
    out = [
        f"state={st['state']} running={st['running']} wm={st['wm']} resolution={st['resolution']} "
        f"xvfb={st['xvfb']} window_manager={st['window_manager']} x11vnc={st['x11vnc']} "
        f"(port 5900 listening={st['vnc_listening']}) websockify={st['websockify']} "
        f"(port 6080 listening={st['web_listening']}) install={st['install_state']}",
    ]
    if st["error"]:
        out.append(f"error: {st['error']}")
    if st["install_error"]:
        out.append(f"install error: {st['install_error']}")
    for log_name in DESKTOP_LOGS:
        tail = _tail_lines(os.path.join(DESKTOP_LOG_DIR, log_name + ".log"), lines if log_name in ("desktop", "install") else 40)
        if any(l.strip() for l in tail):
            out.append("")
            out.append(f"===== {log_name}.log =====")
            out.extend(tail)
    return "\n".join(out)


def _run_desktop_cmd(args: list, timeout: int) -> tuple:
    """Run linxr-desktop. Returns (exit code, dict from its last JSON line, stderr)."""
    res = subprocess.run(
        [_resolve_desktop_bin()] + args,
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout,
    )
    result = {}
    for line in reversed(res.stdout.splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                parsed = json.loads(line)
                if isinstance(parsed, dict):
                    result = parsed
            except ValueError:
                pass
            break
    return res.returncode, result, res.stderr or ""


def _wait_for_desktop_install(proc, seconds: float) -> None:
    """Wait until the install script has recorded its pid (it does so first
    thing) or has exited, so the reply already describes this install."""
    import time  # local: keeps this change independent of the module imports
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline and proc.poll() is None:
        if _read_text(os.path.join(DESKTOP_STATE_DIR, "install.pid")) == str(proc.pid):
            return
        time.sleep(0.2)


def _desktop_error_detail(result: dict, stderr: str, fallback: str) -> str:
    detail = str(result.get("error") or "").strip()
    if not detail:
        lines = [l.strip() for l in stderr.splitlines() if l.strip()]
        detail = lines[-1] if lines else fallback
    if detail.startswith("Error: "):
        detail = detail[len("Error: "):]
    return detail[:800]


def _resolve_desktop_bin() -> str:
    target = "/usr/local/bin/linxr-desktop"
    for src in ["/bootstrap/linxr-desktop.sh", "/mnt/sdcard/bootstrap/linxr-desktop.sh"]:
        if os.path.isfile(src):
            try:
                needs_sync = False
                if not os.path.isfile(target):
                    needs_sync = True
                else:
                    s_stat = os.stat(src)
                    t_stat = os.stat(target)
                    if s_stat.st_size != t_stat.st_size or (s_stat.st_mtime - t_stat.st_mtime > 2):
                        needs_sync = True
                if needs_sync:
                    import shutil
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    shutil.copyfile(src, target)
                    os.chmod(target, 0o755)
                if os.path.isfile(target) and os.access(target, os.X_OK):
                    return target
            except Exception as e:
                logger.warning("Could not sync %s to %s: %s", src, target, e)
            if os.path.isfile(src) and os.access(src, os.X_OK):
                return src
    if os.path.isfile(target) and os.access(target, os.X_OK):
        return target
    for src in ["/bootstrap/linxr-desktop.sh", "/mnt/sdcard/bootstrap/linxr-desktop.sh"]:
        if os.path.isfile(src):
            return src
    return target

ENGINE_MODE_FILE = "/etc/linxr_engine.mode"


def _get_engine_mode() -> str:
    """Returns 'fasttrack' (daemonless crun/podman) or 'docker' (dockerd daemon)."""
    if os.path.isfile(ENGINE_MODE_FILE):
        try:
            with open(ENGINE_MODE_FILE, "r") as f:
                mode = f.read().strip().lower()
                if mode in ("fasttrack", "docker"):
                    return mode
        except Exception:
            pass
    return "fasttrack"


def _set_engine_mode(mode: str) -> dict:
    mode = mode.strip().lower()
    if mode not in ("fasttrack", "docker"):
        mode = "fasttrack"
    try:
        with open(ENGINE_MODE_FILE, "w") as f:
            f.write(mode)
    except Exception as e:
        logger.warning("Could not write engine mode: %s", e)

    if mode == "docker":
        if not os.path.exists("/var/run/docker.sock"):
            logger.info("Starting Docker daemon on demand...")
            subprocess.Popen(
                "containerd >/var/log/containerd.log 2>&1 & dockerd --containerd=/run/containerd/containerd.sock >/var/log/dockerd.log 2>&1 &",
                shell=True
            )
    else:
        logger.info("Stopping Docker daemon to free emulated CPU...")
        subprocess.run("killall -9 dockerd containerd 2>/dev/null || true", shell=True)

    return _get_engine_info()


def _get_engine_info() -> dict:
    mode = _get_engine_mode()
    has_docker = os.path.exists("/var/run/docker.sock")
    has_crun = shutil.which("crun") is not None
    has_podman = shutil.which("podman") is not None
    has_buildah = shutil.which("buildah") is not None

    return {
        "mode": mode,
        "dockerRunning": has_docker,
        "fasttrackAvailable": (has_crun or has_podman),
        "runtimes": {
            "oci": "crun" if has_crun else ("runc" if shutil.which("runc") else "none"),
            "podman": has_podman,
            "buildah": has_buildah,
            "dockerd": has_docker
        },
        "description": "FastTrack (daemonless crun/podman)" if mode == "fasttrack" else "Standard Docker Daemon"
    }


def _engine_cli() -> str:
    """CLI for the active engine: podman in FastTrack mode, docker otherwise.

    In FastTrack mode dockerd is not running, so the docker CLI would fail.
    """
    if _get_engine_mode() == "fasttrack" and shutil.which("podman"):
        return "podman"
    return "docker"


def _run_engine_cmd(args, timeout=600):
    """Run container CLI using active engine (podman for fasttrack, docker for docker mode)."""
    cli = _engine_cli()
    try:
        result = subprocess.run([cli] + args, capture_output=True, text=True, timeout=timeout)
        return result.returncode, result.stdout or "", result.stderr or ""
    except subprocess.TimeoutExpired:
        return 124, "", f"timed out after {timeout}s"
    except Exception as e:
        return -1, "", str(e)

class VmApiHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def address_string(self):
        # Override to prevent expensive reverse DNS lookup (socket.getfqdn) on private network
        return self.client_address[0]

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
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True

    def _send_text(self, status_code: int, text: str):
        body = text.encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True

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
        if not hmac.compare_digest(sent_token.encode("utf-8"), API_TOKEN.encode("utf-8")):
            self._send_error(401, "Invalid token")
            return False
        return True

    def _read_json_body(self) -> dict:
        try:
            content_length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            return {}
        if content_length <= 0 or content_length > 1024 * 1024:
            return {}
        raw = self.rfile.read(content_length).decode("utf-8", errors="replace")
        try:
            data = json.loads(raw)
        except Exception:
            return {}
        # Handlers call data.get(...); a JSON list or string would crash them.
        return data if isinstance(data, dict) else {}

    def _require_name(self, name) -> bool:
        if not _valid_name(name):
            self._send_error(400, "Invalid container name")
            return False
        return True

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        # /health endpoint — no auth required
        if path == "/health":
            mode = _get_engine_mode()
            if mode == "fasttrack":
                is_crun = shutil.which("crun") is not None
                is_podman = shutil.which("podman") is not None
                is_ok = is_crun or is_podman
                self._send_json(200, {
                    "status": "ok" if is_ok else "degraded",
                    "runtime": "fasttrack",
                    "version": "crun OCI (daemonless)",
                    "mode": mode,
                })
            else:
                is_ok, ver = _check_docker_socket()
                self._send_json(200, {
                    "status": "ok" if is_ok else "degraded",
                    "runtime": "docker",
                    "version": ver,
                    "mode": mode,
                })
            return

        # Protected endpoints
        if not self._check_auth():
            return

        if path == "/desktop/status":
            self._send_json(200, _get_desktop_status())
            return

        if path == "/engine":
            self._send_json(200, _get_engine_info())
            return

        if path == "/system/release":
            self._send_json(200, _get_system_release())
            return

        if path == "/containers":
            mode = _get_engine_mode()
            if mode == "fasttrack" or not os.path.exists("/var/run/docker.sock"):
                rc, out, err = _run_engine_cmd(["ps", "-a", "--format", "json"], timeout=20)
                if rc == 0 and out.strip():
                    try:
                        raw = json.loads(out)
                        if not isinstance(raw, list):
                            raw = [raw]
                        containers = []
                        for c in raw:
                            names = c.get("Names") or [c.get("Id", "")[:12]]
                            if isinstance(names, str):
                                names = [names]
                            name = names[0].lstrip("/") if names else "unknown"
                            image = c.get("Image", "")
                            status = c.get("Status", "") or c.get("State", "")
                            ports = []
                            for p in c.get("Ports", []):
                                if isinstance(p, dict):
                                    hp = p.get("hostPort") or p.get("PublicPort")
                                    cp = p.get("containerPort") or p.get("PrivatePort")
                                    proto = p.get("protocol") or p.get("Type") or "tcp"
                                    if hp and cp:
                                        ports.append(f"{hp}->{cp}/{proto}")
                                elif isinstance(p, str):
                                    ports.append(p)
                            containers.append({
                                "name": name,
                                "image": image,
                                "status": status,
                                "ports": ports,
                            })
                        self._send_json(200, containers)
                        return
                    except Exception as e:
                        logger.error("FastTrack ps parse error: %s", e)
                self._send_json(200, [])
                return

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
            if not self._require_name(name):
                return
            if tail != "all" and not tail.isdigit():
                tail = "100"
            rc, out, err = _run_engine_cmd(["logs", "--tail", tail, name], timeout=10)
            if rc != 0:
                self._send_error(500, (err or out or "logs failed").strip()[:500])
                return
            # Container logs mix stdout and stderr; return both.
            self._send_text(200, (out + err) if (out and err) else (out or err or ""))
            return

        if path == "/containers/inspect":
            params = parse_qs(parsed.query)
            name = params.get("name", [""])[0]
            if not name:
                self._send_error(400, "Container name required")
                return
            if not self._require_name(name):
                return
            rc, out, err = _run_engine_cmd(["inspect", "--type", "container", name], timeout=30)
            if rc != 0:
                self._send_error(404, (err or out or "Not found").strip()[:500])
                return
            try:
                c = json.loads(out)[0]
                host_config = c.get("HostConfig", {}) or {}
                restart_policy = (host_config.get("RestartPolicy") or {}).get("Name", "no")
                memory_bytes = host_config.get("Memory", 0) or 0
                nano_cpus = host_config.get("NanoCpus", 0) or 0
                conf = c.get("Config", {}) or {}
                self._send_json(200, {
                    "name": name,
                    "image": conf.get("Image", ""),
                    "restartPolicy": restart_policy,
                    "memoryMb": int(memory_bytes // (1024 * 1024)),
                    "cpus": round(nano_cpus / 1e9, 2) if nano_cpus else 0,
                })
            except Exception as e:
                self._send_error(500, str(e))
            return

        if path == "/images":
            mode = _get_engine_mode()
            if mode == "fasttrack" or not os.path.exists("/var/run/docker.sock"):
                rc, out, err = _run_engine_cmd(["images", "--format", "json"], timeout=20)
                if rc == 0 and out.strip():
                    try:
                        raw = json.loads(out)
                        if not isinstance(raw, list):
                            raw = [raw]
                        images = []
                        for img in raw:
                            names = img.get("Names") or img.get("RepoTags") or []
                            if isinstance(names, str):
                                names = [names]
                            tag = names[0] if names else ((img.get("Id") or "")[:12] or "<none>")
                            images.append({
                                "repoTag": tag,
                                "id": (img.get("Id") or "")[:12],
                                "size": img.get("Size") or 0,
                            })
                        self._send_json(200, images)
                        return
                    except Exception as e:
                        logger.error("FastTrack images parse error: %s", e)
                self._send_json(200, [])
                return

            code, data = _docker_socket_request("GET", "/images/json")
            if code != 200:
                self._send_error(500, "Docker daemon socket error")
                return
            try:
                raw_list = json.loads(data.decode("utf-8", errors="ignore"))
                images = []
                for img in raw_list:
                    tags = img.get("RepoTags") or []
                    tag = tags[0] if tags else (img.get("Id", "")[:12] or "<none>")
                    images.append({
                        "repoTag": tag,
                        "id": img.get("Id", "")[:12],
                        "size": img.get("Size", 0),
                    })
                self._send_json(200, images)
            except Exception as e:
                self._send_error(500, str(e))
            return

        if path == "/desktop/log":
            params = parse_qs(parsed.query)
            name = params.get("name", ["all"])[0]
            try:
                lines = max(1, min(int(params.get("lines", ["200"])[0]), 2000))
            except ValueError:
                lines = 200
            if name != "all" and name not in DESKTOP_LOGS:
                self._send_error(400, "Unknown log name")
                return
            self._send_text(200, _desktop_log_text(name, lines) or "(the log is empty)")
            return

        self._send_error(404, "Not found")

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if not self._check_auth():
            return

        data = self._read_json_body()

        # ── Virtual Desktop (GUI) ────────────────────────────────────────────
        if path == "/desktop/start":
            resolution = data.get("resolution", "1280x720")
            wm = DESKTOP_WMS.get(data.get("wm", "openbox"))
            if not _valid_resolution(resolution):
                self._send_error(400, "Invalid resolution: use WIDTHxHEIGHT, for example 1280x720")
                return
            if wm is None:
                self._send_error(400, "Unknown desktop environment: use openbox or xfce4")
                return
            if not _desktop_start_lock.acquire(blocking=False):
                self._send_error(409, "Another desktop start is already in progress")
                return
            try:
                # Blocks until every component is up or one has failed (the
                # script waits up to 180 s), so a 200 means the desktop works.
                rc, result, err = _run_desktop_cmd(["start", resolution, wm], DESKTOP_START_TIMEOUT)
            except subprocess.TimeoutExpired:
                try:
                    _run_desktop_cmd(["stop"], 60)
                except Exception:
                    pass
                self._send_error(504, f"The desktop did not start within {DESKTOP_START_TIMEOUT} s. See the desktop log.")
                return
            except Exception as e:
                self._send_error(500, f"Desktop start failed: {e}")
                return
            finally:
                _desktop_start_lock.release()
            status = _get_desktop_status()
            if rc == 0 and status.get("running"):
                self._send_json(200, status)
                return
            detail = _desktop_error_detail(result, err, f"The desktop did not start (exit {rc}). See the desktop log.")
            status["error"] = detail
            status["detail"] = detail
            self._send_json(DESKTOP_RC_HTTP.get(rc, 500), status)
            return

        if path == "/desktop/stop":
            try:
                rc, result, err = _run_desktop_cmd(["stop"], 60)
            except Exception as e:
                self._send_error(500, f"Desktop stop failed: {e}")
                return
            status = _get_desktop_status()
            if rc != 0 or status.get("running"):
                status["detail"] = _desktop_error_detail(result, err, "The desktop did not stop. See the desktop log.")
                self._send_json(500, status)
                return
            self._send_json(200, status)
            return

        if path == "/desktop/install":
            # Installing XFCE under TCG can take many minutes, so the install
            # runs in the background; the app polls /desktop/status for
            # install_state / install_progress / install_error.
            mode = DESKTOP_WMS.get(data.get("mode", "openbox"))
            if mode is None:
                self._send_error(400, "Unknown desktop environment: use openbox or xfce4")
                return
            if _desktop_install_info()["install_state"] == "running":
                self._send_json(202, _get_desktop_status())
                return
            try:
                proc = subprocess.Popen(
                    [_resolve_desktop_bin(), "install", mode],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
            except Exception as e:
                self._send_error(500, f"Desktop install failed to start: {e}")
                return
            threading.Thread(target=proc.wait, daemon=True).start()
            _wait_for_desktop_install(proc, 5)
            status = _get_desktop_status()
            rc = proc.poll()
            if rc is not None and rc != 0:
                status["detail"] = status.get("install_error") or f"Desktop install failed (exit {rc}). See the install log."
                self._send_json(DESKTOP_RC_HTTP.get(rc, 500), status)
                return
            self._send_json(202 if rc is None else 200, status)
            return

        if path == "/desktop/app":
            app = data.get("app", "terminal")
            if app not in DESKTOP_APPS:
                self._send_error(400, "Unknown app: use terminal, files, editor or calculator")
                return
            try:
                rc, result, err = _run_desktop_cmd(["app", app], 20)
            except Exception as e:
                self._send_error(500, f"Desktop app launch failed: {e}")
                return
            if rc != 0:
                self._send_error(
                    DESKTOP_RC_HTTP.get(rc, 500),
                    _desktop_error_detail(result, err, f"Could not open {app} (exit {rc})"),
                )
                return
            self._send_json(200, result or {"status": "ok", "app": app})
            return

        if path == "/engine":
            req_mode = data.get("mode", "fasttrack")
            info = _set_engine_mode(req_mode)
            self._send_json(200, info)
            return

        if path in ("/containers/start", "/containers"):
            image = data.get("image", "").strip()
            name = data.get("name", "").strip()
            if not image or not name:
                self._send_error(400, "image and name required")
                return
            if not self._require_name(name):
                return
            if not _valid_image(image):
                self._send_error(400, "Invalid image reference")
                return

            cmd_args = data.get("cmd", [])
            env_vars = data.get("env", [])
            ports = data.get("ports", [])
            network = data.get("network") or "host"

            mode = _get_engine_mode()
            cli = _engine_cli()

            # Remove existing container with same name if stopped or stale to prevent 409 conflict
            if cli == "docker":
                _docker_socket_request("DELETE", f"/containers/{_q(name)}?force=true")
                # Check if image already exists locally via direct socket (<2ms) to avoid redundant 300s pull
                code, _ = _docker_socket_request("GET", f"/images/{_q(image)}/json")
                image_cached = code == 200
            else:
                # FastTrack: dockerd is not running, so use podman for both.
                _run_engine_cmd(["rm", "-f", name], timeout=60)
                rc, _, _ = _run_engine_cmd(["image", "exists", image], timeout=30)
                image_cached = rc == 0
            if not image_cached:
                logger.info("Pulling image: %s", image)
                try:
                    pull_res = subprocess.run(
                        [cli, "pull", image],
                        capture_output=True, text=True, timeout=2400
                    )
                    if pull_res.returncode != 0:
                        err_msg = (pull_res.stderr or pull_res.stdout or "Unknown pull error").strip()
                        self._send_error(500, f"Image pull failed: {err_msg}")
                        return
                except subprocess.TimeoutExpired:
                    self._send_error(504, f"Image pull timed out for '{image}'. Mobile CPU emulation requires extra time for large images.")
                    return
                except Exception as e:
                    self._send_error(500, f"Image pull failed: {e}")
                    return
            else:
                logger.info("Image %s already cached locally, skipping pull", image)

            cmd = [cli, "run", "-d", "--network", network, "--name", name]
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

            logger.info("[%s] Starting container: %s", mode, " ".join(cmd))
            try:
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=2400)
                if result.returncode != 0:
                    err = result.stderr.strip() or result.stdout.strip()
                    self._send_error(500, f"{cli} run error: {err}")
                    return
                self._send_json(200, {"status": "started", "name": name, "id": result.stdout.strip(), "engine": mode})
            except subprocess.TimeoutExpired:
                # Self-healing: On TCG emulation, docker run may complete or start the container.
                # Check via docker socket if the container is running.
                time.sleep(1)
                if cli != "docker":
                    rc, out, _ = _run_engine_cmd(["inspect", "--format", "{{.Id}}", name], timeout=30)
                    if rc == 0 and out.strip():
                        self._send_json(200, {"status": "started", "name": name, "id": out.strip(), "engine": mode})
                        return
                c_code, c_data = _docker_socket_request("GET", f"/containers/{_q(name)}/json")
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
            if not self._require_name(name):
                return
            if _engine_cli() != "docker":
                _run_engine_cmd(["stop", name], timeout=60)
            else:
                _docker_socket_request("POST", f"/containers/{_q(name)}/stop")
            self._send_json(200, {"status": "stopped", "name": name})
            return

        if path == "/images/pull":
            image = data.get("image", "").strip()
            if not image:
                self._send_error(400, "image required")
                return
            if not _valid_image(image):
                self._send_error(400, "Invalid image reference")
                return
            rc, out, err = _run_engine_cmd(["pull", image], timeout=2400)
            if rc == 124:
                self._send_error(504, "Image pull timed out")
            elif rc != 0:
                self._send_error(500, (err or out or "Pull failed").strip()[:500])
            else:
                self._send_json(200, {"status": "pulled", "image": image, "output": out})
            return

        if path == "/ssh/app-key":
            try:
                self._send_json(200, {"privateKey": _create_app_ssh_key()})
            except Exception as e:
                logger.warning("Could not create the app SSH key: %s", e)
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
            if not self._require_name(name):
                return
            try:
                result = subprocess.run([_engine_cli(), "exec", name, "sh", "-c", cmd_str], capture_output=True, text=True, timeout=45)
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

        # ── Container lifecycle management ───────────────────────────────────

        if path == "/containers/start-existing":
            name = data.get("name", "").strip()
            if not name:
                self._send_error(400, "name required")
                return
            if not self._require_name(name):
                return
            if _engine_cli() != "docker":
                rc, out, err = _run_engine_cmd(["start", name], timeout=60)
                if rc != 0:
                    self._send_error(500, f"Failed to start: {err or out}")
                    return
            else:
                code, _ = _docker_socket_request("POST", f"/containers/{_q(name)}/start")
                if code not in (200, 204, 304):
                    self._send_error(500, f"Failed to start container (status {code})")
                    return
            self._send_json(200, {"status": "started", "name": name})
            return

        if path == "/containers/restart":
            name = data.get("name", "").strip()
            if not name:
                self._send_error(400, "name required")
                return
            if not self._require_name(name):
                return
            if _engine_cli() != "docker":
                rc, out, err = _run_engine_cmd(["restart", name], timeout=60)
                if rc != 0:
                    self._send_error(500, f"Failed to restart: {err or out}")
                    return
            else:
                code, _ = _docker_socket_request("POST", f"/containers/{_q(name)}/restart")
                if code not in (200, 204):
                    self._send_error(500, f"Failed to restart container (status {code})")
                    return
            self._send_json(200, {"status": "restarted", "name": name})
            return

        if path == "/containers/delete":
            name = data.get("name", "").strip()
            if not name:
                self._send_error(400, "name required")
                return
            if not self._require_name(name):
                return
            if _engine_cli() != "docker":
                rc, out, err = _run_engine_cmd(["rm", "-f", name], timeout=60)
                if rc != 0:
                    self._send_error(500, f"Failed to delete: {err or out}")
                    return
            else:
                code, _ = _docker_socket_request("DELETE", f"/containers/{_q(name)}?force=true")
                if code not in (200, 204):
                    self._send_error(500, f"Failed to delete container (status {code})")
                    return
            self._send_json(200, {"status": "deleted", "name": name})
            return

        if path == "/containers/update":
            name = data.get("name", "").strip()
            if not name:
                self._send_error(400, "name required")
                return
            if not self._require_name(name):
                return
            cmd = [_engine_cli(), "update"]
            restart_policy = data.get("restartPolicy")
            if restart_policy:
                cmd += ["--restart", str(restart_policy)]
            memory_mb = data.get("memoryMb")
            if memory_mb:
                try:
                    cmd += ["--memory", f"{int(memory_mb)}m"]
                except (TypeError, ValueError):
                    pass
            cpus = data.get("cpus")
            if cpus:
                try:
                    cmd += ["--cpus", str(float(cpus))]
                except (TypeError, ValueError):
                    pass
            cmd.append(name)
            rc, out, err = _run_docker(cmd, timeout=120)
            if rc != 0:
                self._send_error(500, (err or out or "Update failed").strip()[:500])
                return
            self._send_json(200, {"status": "updated", "name": name})
            return

        if path == "/containers/export":
            name = data.get("name", "").strip()
            if not name:
                self._send_error(400, "name required")
                return
            if not self._require_name(name):
                return
            if not os.path.isdir(GUEST_SHARE_DIR):
                self._send_error(500, "Shared folder (/mnt/sdcard) not available")
                return
            try:
                os.makedirs(EXPORT_DIR, exist_ok=True)
            except Exception as e:
                self._send_error(500, f"Could not create export dir: {e}")
                return
            file_path = os.path.join(EXPORT_DIR, f"{_safe_filename(name)}.tar")
            rc, out, err = _run_docker([_engine_cli(), "export", "-o", file_path, name], timeout=2400)
            if rc != 0:
                self._send_error(500, (err or out or "Export failed").strip()[:500])
                return
            self._send_json(200, {"status": "exported", "name": name, "file": os.path.basename(file_path)})
            return

        if path == "/containers/import":
            name = data.get("name", "").strip()
            file_name = data.get("file", "").strip()
            if not name or not file_name:
                self._send_error(400, "name and file required")
                return
            if not _valid_image(name):
                self._send_error(400, "Invalid image name")
                return
            src = _resolve_share_file(file_name)
            if not src:
                self._send_error(404, f"File not found in shared folder or linxr-exports: {file_name}")
                return
            rc, out, err = _run_docker([_engine_cli(), "import", src, name], timeout=2400)
            if rc != 0:
                self._send_error(500, (err or out or "Import failed").strip()[:500])
                return
            self._send_json(200, {"status": "imported", "image": name, "output": out.strip()[-300:]})
            return

        # ── Image save/load ──────────────────────────────────────────────────

        if path == "/images/save":
            image = data.get("image", "").strip()
            if not image:
                self._send_error(400, "image required")
                return
            if not _valid_image(image):
                self._send_error(400, "Invalid image reference")
                return
            if not os.path.isdir(GUEST_SHARE_DIR):
                self._send_error(500, "Shared folder (/mnt/sdcard) not available")
                return
            try:
                os.makedirs(EXPORT_DIR, exist_ok=True)
            except Exception as e:
                self._send_error(500, f"Could not create export dir: {e}")
                return
            file_path = os.path.join(EXPORT_DIR, f"{_safe_filename(image)}.tar")
            rc, out, err = _run_docker([_engine_cli(), "save", "-o", file_path, image], timeout=2400)
            if rc != 0:
                self._send_error(500, (err or out or "Save failed").strip()[:500])
                return
            self._send_json(200, {"status": "saved", "image": image, "file": os.path.basename(file_path)})
            return

        if path == "/images/load":
            file_name = data.get("file", "").strip()
            if not file_name:
                self._send_error(400, "file required")
                return
            src = _resolve_share_file(file_name)
            if not src:
                self._send_error(404, f"File not found in shared folder or linxr-exports: {file_name}")
                return
            rc, out, err = _run_docker([_engine_cli(), "load", "-i", src], timeout=2400)
            if rc != 0:
                self._send_error(500, (err or out or "Load failed").strip()[:500])
                return
            self._send_json(200, {"status": "loaded", "output": (out or err).strip()[-500:]})
            return

        self._send_error(404, "Not found")


LINXR_RELEASE_FILE = "/etc/linxr-release"


def _get_system_release() -> dict:
    """Versions inside the VM, for Settings > About.

    /etc/linxr-release (KEY=VALUE lines) is written by scripts/_build_rootfs.sh
    since #34; older images fall back to /etc/alpine-release.
    """
    info = {}
    try:
        with open(LINXR_RELEASE_FILE, "r") as f:
            for line in f:
                key, sep, value = line.strip().partition("=")
                if sep and key:
                    info[key] = value.strip()
    except OSError:
        pass
    alpine = info.get("ALPINE_VERSION", "")
    if not alpine:
        try:
            with open("/etc/alpine-release", "r") as f:
                alpine = f.read().strip()
        except OSError:
            alpine = ""
    return {
        "alpineVersion": alpine,
        "kernelVersion": info.get("KERNEL_VERSION", ""),
        "runningKernel": os.uname().release,
        "buildDate": info.get("BUILD_DATE", ""),
        "hasReleaseFile": bool(info),
    }


APP_KEY_COMMENT = "linxr-app"
AUTHORIZED_KEYS = "/root/.ssh/authorized_keys"


def _create_app_ssh_key() -> str:
    """Create an ed25519 key pair for the Linxr app and authorize it for root.

    The public key replaces any earlier app key in authorized_keys; the private
    key is returned to the app (which stores it in Android Keystore) and is not
    kept in the guest.
    """
    import tempfile

    if shutil.which("ssh-keygen") is None:
        subprocess.run(["apk", "add", "--no-cache", "openssh-keygen"], capture_output=True, timeout=300)
    if shutil.which("ssh-keygen") is None:
        raise RuntimeError("ssh-keygen not found and openssh-keygen could not be installed")
    os.makedirs("/root/.ssh", mode=0o700, exist_ok=True)
    os.chmod("/root/.ssh", 0o700)
    tmpdir = tempfile.mkdtemp(prefix="linxr-key-")
    try:
        key_path = os.path.join(tmpdir, "id_ed25519")
        subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", APP_KEY_COMMENT, "-f", key_path],
            check=True, capture_output=True, timeout=60,
        )
        with open(key_path, "r") as f:
            private_key = f.read()
        with open(key_path + ".pub", "r") as f:
            public_key = f.read().strip()
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    lines = []
    try:
        with open(AUTHORIZED_KEYS, "r") as f:
            lines = [ln.rstrip("\n") for ln in f if not ln.rstrip().endswith(" " + APP_KEY_COMMENT)]
    except OSError:
        pass
    lines.append(public_key)
    tmp_auth = AUTHORIZED_KEYS + ".tmp"
    with open(tmp_auth, "w") as f:
        f.write("\n".join(ln for ln in lines if ln.strip()) + "\n")
    os.chmod(tmp_auth, 0o600)
    os.replace(tmp_auth, AUTHORIZED_KEYS)
    return private_key


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
        # With shell=True and a list, only "nft" ran (the rule became $0), so
        # these rules were never added. Pass each nft command as one argument.
        for nft_cmd in (
            "add table ip6 filter",
            "add chain ip6 filter output { type filter hook output priority 0 ; policy accept ; }",
            "add table ip filter",
            "add chain ip filter output { type filter hook output priority 0 ; policy accept ; }",
        ):
            subprocess.run(["nft", nft_cmd], capture_output=True, timeout=5)
        # Rules are appended, so only add them once (init_bootstrap.sh may
        # already have added them).
        for family, rule, marker in (
            ("ip6", "add rule ip6 filter output reject", "reject"),
            ("ip", "add rule ip filter output tcp flags syn tcp option maxseg size set 1160", "maxseg size set 1160"),
        ):
            listing = subprocess.run(["nft", "list", "chain", family, "filter", "output"],
                                     capture_output=True, text=True, timeout=5)
            if marker not in (listing.stdout or ""):
                subprocess.run(["nft", rule], capture_output=True, timeout=5)
    except Exception as e:
        logger.warning("Could not apply network hardening: %s", e)


def run_server():
    server_address = ("0.0.0.0", 7080)
    ThreadingHTTPServer.allow_reuse_address = True
    httpd = ThreadingHTTPServer(server_address, VmApiHandler)
    logger.info("Serving lightweight Docker VM API on 0.0.0.0:7080")
    threading.Thread(target=_apply_network_hardening, daemon=True).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    run_server()
