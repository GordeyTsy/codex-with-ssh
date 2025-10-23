#!/usr/bin/env python3
"""HTTP-based SSH tunnel gateway.

The gateway accepts authenticated HTTP requests and proxies traffic to the local
OpenSSH daemon. It intentionally exposes a very small surface:

  POST   /v1/ssh/session            -> create a new tunnel session
  POST   /v1/ssh/session/<id>/write -> send base64-encoded payload to the SSH socket
  GET    /v1/ssh/session/<id>/read  -> long-poll read (returns base64 payload)
  DELETE /v1/ssh/session/<id>       -> terminate the session explicitly

Each request must include `Authorization: Basic <user:token>` where the
credentials come from the Kubernetes secret `ssh-bastion-tunnel`.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import queue
import socket
import threading
import time
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Dict, Optional, Tuple
from urllib.parse import parse_qs, urlparse

HOST = os.environ.get("HTTP_TUNNEL_HOST", "127.0.0.1")
PORT = int(os.environ.get("HTTP_TUNNEL_PORT", "22"))
LISTEN_HOST = os.environ.get("HTTP_TUNNEL_LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("HTTP_TUNNEL_LISTEN_PORT", "8080"))
AUTH_CREDENTIALS = os.environ.get("HTTP_TUNNEL_AUTH", "")
SESSION_TTL = float(os.environ.get("HTTP_TUNNEL_SESSION_TTL", "300"))  # seconds
READ_TIMEOUT_DEFAULT = float(os.environ.get("HTTP_TUNNEL_READ_TIMEOUT", "25"))
MAX_CHUNK = int(os.environ.get("HTTP_TUNNEL_MAX_CHUNK", "65536"))
LOG_LEVEL = os.environ.get("HTTP_TUNNEL_LOG_LEVEL", "INFO").upper()

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s [%(levelname)s] %(message)s",
)


class TunnelSession:
    """Represents a single SSH TCP connection."""

    def __init__(self, target_host: str, target_port: int) -> None:
        self.id = uuid.uuid4().hex
        self.target_host = target_host
        self.target_port = target_port
        self.created_at = time.time()
        self.last_activity = self.created_at
        self.closed = False
        self._sock = socket.create_connection((target_host, target_port))
        self._sock.setblocking(True)
        self._send_lock = threading.Lock()
        self._recv_queue: "queue.Queue[Optional[bytes]]" = queue.Queue()
        self._reader_thread = threading.Thread(target=self._reader, name=f"ssh-tunnel-reader-{self.id}", daemon=True)
        self._reader_thread.start()

    def _reader(self) -> None:
        try:
            while not self.closed:
                data = self._sock.recv(MAX_CHUNK)
                if not data:
                    break
                self._recv_queue.put(data)
        except OSError as exc:
            logging.debug("Reader thread for session %s stopped: %s", self.id, exc)
        finally:
            self._recv_queue.put(None)

    def send(self, payload: bytes) -> None:
        if self.closed:
            raise RuntimeError("session closed")
        with self._send_lock:
            self._sock.sendall(payload)
        self.last_activity = time.time()

    def recv(self, timeout: float) -> Optional[bytes]:
        try:
            chunk = self._recv_queue.get(timeout=timeout)
        except queue.Empty:
            return b""
        if chunk is None:
            return None
        self.last_activity = time.time()
        return chunk

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        with self._send_lock:
            try:
                self._sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self._sock.close()
        self._recv_queue.put(None)


class SessionRegistry:
    """Tracks active tunnel sessions."""

    def __init__(self) -> None:
        self._sessions: Dict[str, TunnelSession] = {}
        self._lock = threading.Lock()
        self._gc_thread = threading.Thread(target=self._gc_loop, name="ssh-tunnel-gc", daemon=True)
        self._gc_thread.start()

    def _gc_loop(self) -> None:
        while True:
            time.sleep(30)
            now = time.time()
            with self._lock:
                expired = [sid for sid, sess in self._sessions.items() if now - sess.last_activity > SESSION_TTL]
            for sid in expired:
                logging.info("Session %s expired", sid)
                self.close(sid)

    def create(self) -> TunnelSession:
        session = TunnelSession(HOST, PORT)
        with self._lock:
            self._sessions[session.id] = session
        logging.info("Created session %s (target %s:%s)", session.id, HOST, PORT)
        return session

    def get(self, session_id: str) -> TunnelSession:
        with self._lock:
            session = self._sessions.get(session_id)
            if session is None:
                raise KeyError(session_id)
            return session

    def close(self, session_id: str) -> None:
        with self._lock:
            session = self._sessions.pop(session_id, None)
        if session:
            logging.info("Closing session %s", session_id)
            session.close()


SESSIONS = SessionRegistry()


def parse_authorization(header: str) -> Tuple[str, str]:
    if not header.startswith("Basic "):
        raise ValueError("Unsupported auth scheme")
    encoded = header.split(" ", 1)[1]
    try:
        decoded = base64.b64decode(encoded).decode("utf-8")
    except Exception as exc:  # noqa: BLE001
        raise ValueError("Invalid base64 token") from exc
    if ":" not in decoded:
        raise ValueError("Malformed credentials")
    user, token = decoded.split(":", 1)
    return user, token


class TunnelRequestHandler(BaseHTTPRequestHandler):
    server_version = "SSHHttpTunnel/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        logging.info("%s - %s", self.address_string(), fmt % args)

    def _send_json(self, status: HTTPStatus, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authenticate(self) -> bool:
        if not AUTH_CREDENTIALS:
            return True
        header = self.headers.get("Authorization", "")
        try:
            user, token = parse_authorization(header)
        except ValueError:
            self._send_json(HTTPStatus.UNAUTHORIZED, {"error": "invalid credentials"})
            return False
        if f"{user}:{token}" != AUTH_CREDENTIALS:
            self._send_json(HTTPStatus.FORBIDDEN, {"error": "forbidden"})
            return False
        return True

    def _read_json_body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(length) if length > 0 else b""
        if not data:
            return {}
        try:
            return json.loads(data.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise ValueError("Invalid JSON body") from exc

    def do_POST(self) -> None:  # noqa: N802
        if not self._authenticate():
            return
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")
        if path == "/v1/ssh/session":
            try:
                body = {}
                if int(self.headers.get("Content-Length", "0")) > 0:
                    body = self._read_json_body()
                target_override = body.get("target") if isinstance(body, dict) else None
                if target_override and target_override != f"{HOST}:{PORT}":
                    self._send_json(HTTPStatus.BAD_REQUEST, {"error": "target_override_not_allowed"})
                    return
                session = SESSIONS.create()
            except Exception as exc:  # noqa: BLE001
                logging.error("Failed to create session: %s", exc)
                self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "session_create_failed"})
                return
            self._send_json(HTTPStatus.CREATED, {"id": session.id, "ttl": SESSION_TTL})
            return
        if path.startswith("/v1/ssh/session/") and path.endswith("/write"):
            session_id = path.split("/")[4]
            try:
                session = SESSIONS.get(session_id)
            except KeyError:
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "unknown_session"})
                return
            try:
                payload = self._read_json_body()
                data_b64 = payload.get("data", "")
                if not data_b64:
                    self._send_json(HTTPStatus.BAD_REQUEST, {"error": "missing_data"})
                    return
                data = base64.b64decode(data_b64)
                session.send(data)
            except Exception as exc:  # noqa: BLE001
                logging.error("Failed to write to session %s: %s", session_id, exc)
                SESSIONS.close(session_id)
                self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "write_failed"})
                return
            self._send_json(HTTPStatus.NO_CONTENT, {})
            return
        self._send_json(HTTPStatus.NOT_FOUND, {"error": "unknown_endpoint"})

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/healthz":
            self._send_json(HTTPStatus.OK, {"status": "ok"})
            return
        if not self._authenticate():
            return
        if parsed.path.startswith("/v1/ssh/session/") and parsed.path.endswith("/read"):
            session_id = parsed.path.split("/")[4]
            try:
                session = SESSIONS.get(session_id)
            except KeyError:
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "unknown_session"})
                return
            params = parse_qs(parsed.query)
            timeout = READ_TIMEOUT_DEFAULT
            if "timeout" in params:
                try:
                    timeout = float(params["timeout"][0])
                except (ValueError, TypeError):
                    pass
            try:
                chunk = session.recv(timeout)
            except Exception as exc:  # noqa: BLE001
                logging.error("Failed to read from session %s: %s", session_id, exc)
                SESSIONS.close(session_id)
                self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "read_failed"})
                return
            if chunk is None:
                SESSIONS.close(session_id)
                self._send_json(HTTPStatus.OK, {"data": "", "closed": True})
                return
            if chunk == b"":
                self._send_json(HTTPStatus.OK, {"data": "", "closed": False})
                return
            encoded = base64.b64encode(chunk).decode("ascii")
            self._send_json(HTTPStatus.OK, {"data": encoded, "closed": False})
            return
        self._send_json(HTTPStatus.NOT_FOUND, {"error": "unknown_endpoint"})

    def do_DELETE(self) -> None:  # noqa: N802
        if not self._authenticate():
            return
        parsed = urlparse(self.path)
        if parsed.path.startswith("/v1/ssh/session/"):
            session_id = parsed.path.split("/")[4]
            SESSIONS.close(session_id)
            self._send_json(HTTPStatus.NO_CONTENT, {})
            return
        self._send_json(HTTPStatus.NOT_FOUND, {"error": "unknown_endpoint"})


def run_server() -> None:
    if not AUTH_CREDENTIALS:
        logging.warning("HTTP_TUNNEL_AUTH is empty; gateway will accept unauthenticated connections.")
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), TunnelRequestHandler)
    logging.info(
        "SSH HTTP tunnel listening on %s:%s -> %s:%s",
        LISTEN_HOST,
        LISTEN_PORT,
        HOST,
        PORT,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logging.info("Received interrupt, shutting down.")
    finally:
        server.server_close()


if __name__ == "__main__":
    run_server()
