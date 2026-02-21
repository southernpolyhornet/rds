#!/usr/bin/env python3
"""Minimal RDS dashboard: serves static UI and API for engine status, start/stop, backup, browse URLs.
Auth: optional HTTP Basic (RDS_DASHBOARD_PASSWORD_FILE). CORS: only allowed origins (RDS_DASHBOARD_ALLOWED_ORIGINS)."""
from __future__ import annotations

import base64
import json
import os
import subprocess
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

ENGINES: list[str] = [
    e.strip() for e in os.environ.get("RDS_ENGINES", "").split(",") if e.strip()
]
BACKUP_ENGINES: list[str] = [
    e.strip()
    for e in os.environ.get("RDS_BACKUP_ENGINES", "").split(",")
    if e.strip()
]

# Auth: optional password file (one line). Username from env or "rds".
AUTH_USER: str = os.environ.get("RDS_DASHBOARD_AUTH_USER", "rds")
AUTH_PASSWORD: str | None = None
_password_file = os.environ.get("RDS_DASHBOARD_PASSWORD_FILE")
if _password_file and os.path.isfile(_password_file):
    with open(_password_file, "r") as f:
        AUTH_PASSWORD = f.read().strip()

# CORS: comma-separated allowed origins. Empty = no CORS header (same-origin only).
ALLOWED_ORIGINS: list[str] = [
    o.strip()
    for o in os.environ.get("RDS_DASHBOARD_ALLOWED_ORIGINS", "").split(",")
    if o.strip()
]


def get_browse_url(name: str) -> str | None:
    key = f"RDS_BROWSE_{name.replace('-', '_')}"
    return os.environ.get(key) or None


def get_connect_command(name: str) -> str:
    key = f"RDS_CONNECT_{name.replace('-', '_')}"
    return os.environ.get(key) or ""


def engine_status(name: str) -> str:
    unit = f"rds-{name}.service"
    try:
        r = subprocess.run(
            ["systemctl", "is-active", unit],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return (r.stdout or "").strip() or "inactive"
    except Exception:
        return "unknown"


def api_engines() -> list[dict]:
    return [
        {
            "name": n,
            "status": engine_status(n),
            "browseUrl": get_browse_url(n),
            "connectCommand": get_connect_command(n),
            "hasBackup": n in BACKUP_ENGINES,
        }
        for n in ENGINES
    ]


def api_engine_action(name: str, action: str) -> tuple[int, dict]:
    if name not in ENGINES:
        return 404, {"error": "unknown engine"}
    unit = f"rds-{name}.service"
    try:
        if action == "start":
            subprocess.run(["systemctl", "start", unit], check=True, timeout=30)
        elif action == "stop":
            subprocess.run(["systemctl", "stop", unit], check=True, timeout=30)
        elif action == "restart":
            subprocess.run(["systemctl", "restart", unit], check=True, timeout=30)
        else:
            return 400, {"error": "bad action"}
        return 200, {"ok": True}
    except subprocess.CalledProcessError as e:
        return 502, {"error": str(e)}
    except Exception as e:
        return 500, {"error": str(e)}


def api_backup_list(name: str) -> tuple[int, dict]:
    if name not in BACKUP_ENGINES:
        return 404, {"error": "backup not enabled"}
    try:
        r = subprocess.run(
            ["rds", "backup", "list", name],
            capture_output=True,
            text=True,
            timeout=30,
        )
        ids = [
            line.strip()
            for line in (r.stdout or "").strip().splitlines()
            if line.strip()
        ]
        return 200, {"backups": ids}
    except Exception as e:
        return 500, {"error": str(e)}


def api_backup_trigger(name: str) -> tuple[int, dict]:
    if name not in BACKUP_ENGINES:
        return 404, {"error": "backup not enabled"}
    try:
        subprocess.run(["rds", "backup", name], check=True, timeout=300)
        return 200, {"ok": True}
    except subprocess.CalledProcessError as e:
        return 502, {"error": str(e)}
    except Exception as e:
        return 500, {"error": str(e)}


def api_backup_restore(name: str, backup_id: str) -> tuple[int, dict]:
    if name not in BACKUP_ENGINES:
        return 404, {"error": "backup not enabled"}
    if not backup_id:
        return 400, {"error": "backup id required"}
    try:
        subprocess.run(["rds", "restore", name, backup_id], check=True, timeout=600)
        return 200, {"ok": True}
    except subprocess.CalledProcessError as e:
        return 502, {"error": str(e)}
    except Exception as e:
        return 500, {"error": str(e)}


def check_auth(handler: BaseHTTPRequestHandler) -> bool:
    """Return True if auth is disabled or Basic auth matches. Else send 401 and return False."""
    if not AUTH_PASSWORD:
        return True
    auth = handler.headers.get("Authorization")
    if not auth or not auth.startswith("Basic "):
        handler.send_response(401)
        handler.send_header("WWW-Authenticate", 'Basic realm="RDS dashboard"')
        _add_cors(handler)
        handler.end_headers()
        return False
    try:
        raw = base64.b64decode(auth[6:]).decode()
        user, _, password = raw.partition(":")
        if user == AUTH_USER and password == AUTH_PASSWORD:
            return True
    except Exception:
        pass
    handler.send_response(401)
    handler.send_header("WWW-Authenticate", 'Basic realm="RDS dashboard"')
    _add_cors(handler)
    handler.end_headers()
    return False


def _add_cors(handler: BaseHTTPRequestHandler) -> None:
    """Set CORS headers if Origin is in ALLOWED_ORIGINS. No header = same-origin only."""
    origin = handler.headers.get("Origin")
    if origin and origin in ALLOWED_ORIGINS:
        handler.send_header("Access-Control-Allow-Origin", origin)
        handler.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        handler.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        handler.send_header("Access-Control-Max-Age", "86400")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        pass

    def send_json(self, status: int, obj: dict) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        _add_cors(self)
        self.end_headers()
        self.wfile.write(json.dumps(obj).encode())

    def do_OPTIONS(self) -> None:
        _add_cors(self)
        self.send_response(204)
        self.end_headers()

    def do_GET(self) -> None:
        if not check_auth(self):
            return
        path = urllib.parse.unquote(self.path).split("?")[0].rstrip("/") or "/"
        if path == "/api/engines":
            self.send_json(200, {"engines": api_engines()})
            return
        if path.startswith("/api/engines/") and path.endswith("/backups"):
            name = path.split("/")[3]
            status, body = api_backup_list(name)
            self.send_json(status, body)
            return
        if path == "/" or path == "/index.html":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            _add_cors(self)
            self.end_headers()
            index = os.path.join(os.path.dirname(__file__), "static", "index.html")
            with open(index, "rb") as f:
                self.wfile.write(f.read())
            return
        self.send_response(404)
        _add_cors(self)
        self.end_headers()

    def do_POST(self) -> None:
        if not check_auth(self):
            return
        path = urllib.parse.unquote(self.path).rstrip("/")
        if path.startswith("/api/engines/"):
            parts = path.split("/")
            if len(parts) >= 4:
                name = parts[3]
                action = parts[4] if len(parts) > 4 else None
                if action in ("start", "stop", "restart"):
                    status, body = api_engine_action(name, action)
                    self.send_json(status, body)
                    return
                if action == "backup":
                    status, body = api_backup_trigger(name)
                    self.send_json(status, body)
                    return
                if action == "restore":
                    length = int(self.headers.get("Content-Length", 0))
                    raw = self.rfile.read(length).decode() if length else "{}"
                    try:
                        data = json.loads(raw)
                        bid = data.get("id", "")
                    except Exception:
                        bid = ""
                    status, body = api_backup_restore(name, bid)
                    self.send_json(status, body)
                    return
        self.send_response(404)
        _add_cors(self)
        self.end_headers()


def main() -> None:
    host = os.environ.get("RDS_DASHBOARD_HOST", "127.0.0.1")
    port = int(os.environ.get("RDS_DASHBOARD_PORT", "8765"))
    HTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
