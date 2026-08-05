#!/usr/bin/env python3
"""
FastAPI server for Docker container management inside Alpine Linux VM.
Runs on guest 127.0.0.1:7080, accessible from Android host via QEMU hostfwd.

Token is injected by the Android app via QEMU fw_cfg:
  -fw_cfg name=opt/api_token,string=<TOKEN>
Guest reads it from: /sys/firmware/qemu_fw_cfg/by_name/opt/api_token/raw
"""

import os
import subprocess
import logging
from typing import List, Optional

from fastapi import Depends, FastAPI, HTTPException, Header
from fastapi.responses import JSONResponse, PlainTextResponse
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Docker VM API", version="1.0.0")

# ---------------------------------------------------------------------------
# Token loading — checked once at startup
# ---------------------------------------------------------------------------

FW_CFG_TOKEN_PATH = "/sys/firmware/qemu_fw_cfg/by_name/opt/api_token/raw"
TOKEN_FILE_PATH = "/bootstrap/token"


def _load_token() -> str:
    # 1. Try fw_cfg (primary — injected by Android app via -fw_cfg QEMU flag)
    try:
        with open(FW_CFG_TOKEN_PATH, "r") as f:
            token = f.read().strip()
            if token:
                logger.info("Loaded API token from fw_cfg")
                return token
    except OSError:
        pass

    # 2. Try token file (written to bootstrap dir by asset extraction)
    try:
        with open(TOKEN_FILE_PATH, "r") as f:
            token = f.read().strip()
            if token:
                logger.info("Loaded API token from %s", TOKEN_FILE_PATH)
                return token
    except OSError:
        pass

    # 3. Environment variable fallback (useful for local development)
    token = os.environ.get("API_TOKEN", "").strip()
    if token:
        logger.info("Loaded API token from environment")
        return token

    logger.warning(
        "No API token found — auth will reject all requests. "
        "Check that QEMU was launched with -fw_cfg name=opt/api_token,string=<TOKEN>"
    )
    return ""


API_TOKEN = _load_token()

# ---------------------------------------------------------------------------
# Auth dependency
# ---------------------------------------------------------------------------


def require_auth(authorization: Optional[str] = Header(None)) -> None:
    if not API_TOKEN:
        raise HTTPException(status_code=503, detail="Server not ready: token not configured")
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing Authorization header")
    if authorization[len("Bearer "):] != API_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid token")


# ---------------------------------------------------------------------------
# Request/response models
# ---------------------------------------------------------------------------


class ContainerStartRequest(BaseModel):
    image: str
    name: str
    cmd: List[str] = []
    env: Optional[List[dict]] = []
    ports: Optional[List[dict]] = []
    # "host" shares the VM's eth0/SLIRP network — works without bridge kernel module.
    # "none" for isolated containers, "bridge" requires linux-virt kernel modules.
    network: Optional[str] = "host"


class ContainerStopRequest(BaseModel):
    name: str


class ImagePullRequest(BaseModel):
    image: str


class ExecRequest(BaseModel):
    name: str
    cmd: str


class VmExecRequest(BaseModel):
    cmd: str


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@app.get("/health")
async def health_check():
    """Health check — no auth required so the app can poll before token is verified."""
    runtime_ok = False
    version = "unknown"
    status = "degraded"

    try:
        result = subprocess.run(
            ["docker", "info"],
            capture_output=True, text=True, timeout=2
        )
        runtime_ok = result.returncode == 0
        if runtime_ok:
            status = "ok"
    except Exception as e:
        logger.warning("Docker info check failed or timed out: %s", e)

    try:
        ver = subprocess.run(
            ["docker", "--version"],
            capture_output=True, text=True, timeout=2
        )
        version = ver.stdout.strip() if ver.returncode == 0 else "unknown"
    except Exception as e:
        pass

    return {
        "status": status,
        "runtime": "docker",
        "version": version,
    }


@app.get("/containers", dependencies=[Depends(require_auth)])
async def list_containers():
    """List running containers."""
    try:
        result = subprocess.run(
            ["docker", "ps", "-a", "--format", "{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}"],
            capture_output=True, text=True, check=True
        )
        containers = []
        for line in result.stdout.strip().splitlines():
            if not line:
                continue
            parts = line.split("|")
            if len(parts) >= 3:
                containers.append({
                    "name": parts[0],
                    "image": parts[1],
                    "status": parts[2],
                    "ports": [parts[3]] if len(parts) > 3 and parts[3] else [],
                })
        return containers
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=500, detail=f"Docker error: {e.stderr}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/containers/start", dependencies=[Depends(require_auth)])
async def start_container(req: ContainerStartRequest):
    """Start a container (pulls image first if not cached)."""
    network = req.network or "host"

    # Pull image explicitly so we can give it a generous timeout independently
    # of the docker run step. Implicit pull inside docker run would share the
    # same 30s run timeout and time out on slow networks.
    logger.info("Pulling image: %s", req.image)
    try:
        subprocess.run(
            ["docker", "pull", req.image],
            capture_output=True, text=True, check=True, timeout=300
        )
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="Image pull timed out")
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=500, detail=f"Docker error: {e.stderr}")

    cmd = ["docker", "run", "-d", "--network", network, "--name", req.name]

    for env in (req.env or []):
        if "key" in env and "value" in env:
            cmd += ["-e", f"{env['key']}={env['value']}"]

    for port in (req.ports or []):
        if "host" in port and "container" in port:
            cmd += ["-p", f"{port['host']}:{port['container']}"]

    cmd.append(req.image)
    cmd.extend(req.cmd)

    logger.info("Starting container: %s", " ".join(cmd))
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=30)
        return {"status": "started", "name": req.name, "id": result.stdout.strip()}
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=500, detail=f"Docker error: {e.stderr}")
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="Container start timed out")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/containers/stop", dependencies=[Depends(require_auth)])
async def stop_container(req: ContainerStopRequest):
    """Stop a container."""
    try:
        subprocess.run(
            ["docker", "stop", req.name],
            capture_output=True, text=True, check=True, timeout=15
        )
        return {"status": "stopped", "name": req.name}
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=500, detail=f"Docker error: {e.stderr}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/images/pull", dependencies=[Depends(require_auth)])
async def pull_image(req: ImagePullRequest):
    """Pull a Docker image."""
    try:
        result = subprocess.run(
            ["docker", "pull", req.image],
            capture_output=True, text=True, check=True, timeout=300
        )
        return {"status": "pulled", "image": req.image, "output": result.stdout}
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="Image pull timed out")
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=500, detail=f"Docker error: {e.stderr}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/logs", dependencies=[Depends(require_auth)])
async def get_logs(name: str, tail: int = 100):
    """Get container logs."""
    try:
        result = subprocess.run(
            ["docker", "logs", "--tail", str(tail), name],
            capture_output=True, text=True, check=True
        )
        return PlainTextResponse(result.stdout)
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=500, detail=f"Docker error: {e.stderr}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/vm/exec", dependencies=[Depends(require_auth)])
async def vm_exec(req: VmExecRequest):
    """Execute a shell command on the VM host (not inside a container)."""
    try:
        result = subprocess.run(
            ["sh", "-c", req.cmd],
            capture_output=True, text=True, timeout=30
        )
        return {
            "stdout": result.stdout,
            "stderr": result.stderr,
            "exitCode": result.returncode,
        }
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="Command timed out")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/exec", dependencies=[Depends(require_auth)])
async def exec_in_container(req: ExecRequest):
    """Execute a command in a running container."""
    try:
        result = subprocess.run(
            ["docker", "exec", req.name, "sh", "-c", req.cmd],
            capture_output=True, text=True, timeout=30
        )
        return {
            "stdout": result.stdout,
            "stderr": result.stderr,
            "exitCode": result.returncode,
        }
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="Exec timed out")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn
    logger.info("Starting Docker VM API server on 127.0.0.1:7080")
    uvicorn.run(app, host="0.0.0.0", port=7080, log_level="info")
