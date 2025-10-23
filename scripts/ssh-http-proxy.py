#!/usr/bin/env python3
"""ProxyCommand helper that tunnels SSH over an HTTPS-based API."""

from __future__ import annotations

import argparse
import base64
import json
import os
import queue
import sys
import threading
import time
from typing import Optional
from urllib import request as urllib_request
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="ProxyCommand helper for the codex SSH HTTP tunnel.")
    parser.add_argument("--endpoint", default=os.environ.get("SSH_HTTP_ENDPOINT", ""), help="HTTPS endpoint of the tunnel gateway (e.g. https://example:443).")
    parser.add_argument("--user", default=os.environ.get("SSH_HTTP_USER", "codex"), help="Tunnel username (defaults to env SSH_HTTP_USER or 'codex').")
    parser.add_argument("--token", default=os.environ.get("SSH_HTTP_TOKEN", ""), help="Tunnel token (defaults to env SSH_HTTP_TOKEN).")
    parser.add_argument("--target", default=os.environ.get("SSH_HTTP_TARGET", "127.0.0.1:22"), help="Backend target host:port (defaults to 127.0.0.1:22).")
    parser.add_argument("--read-timeout", type=float, default=float(os.environ.get("SSH_HTTP_READ_TIMEOUT", "25")), help="Long-poll read timeout in seconds (default: 25).")
    parser.add_argument("--max-chunk", type=int, default=int(os.environ.get("SSH_HTTP_MAX_CHUNK", "65536")), help="Max chunk size per HTTP write (default: 65536).")
    parser.add_argument("--verbose", action="store_true", help="Verbose logging to stderr.")
    return parser


def log(message: str, verbose: bool) -> None:
    if verbose:
        sys.stderr.write(f"[ssh-http-proxy] {message}\n")
        sys.stderr.flush()


class TunnelClient:
    def __init__(self, endpoint: str, credentials: str, read_timeout: float, verbose: bool) -> None:
        self.endpoint = endpoint.rstrip("/")
        self.credentials = credentials
        self.read_timeout = read_timeout
        self.verbose = verbose

    def _request(self, method: str, path: str, payload: Optional[dict] = None, timeout: Optional[float] = None) -> dict:
        url = urljoin(self.endpoint + "/", path.lstrip("/"))
        data_bytes = None
        headers = {
            "Accept": "application/json",
            "Authorization": f"Basic {self.credentials}",
        }
        if payload is not None:
            data_bytes = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib_request.Request(url, data=data_bytes, headers=headers, method=method)
        try:
            with urllib_request.urlopen(req, timeout=timeout) as resp:
                body = resp.read()
                if not body:
                    return {}
                return json.loads(body.decode("utf-8"))
        except HTTPError as exc:
            error_body = exc.read().decode("utf-8", errors="ignore")
            log(f"HTTP error {exc.code} for {method} {path}: {error_body}", self.verbose)
            raise
        except URLError as exc:
            log(f"Network error {exc} for {method} {path}", self.verbose)
            raise

    def create_session(self, target: str) -> str:
        payload: Optional[dict]
        if target:
            payload = {"target": target}
        else:
            payload = None
        body = self._request("POST", "/v1/ssh/session", payload)
        session_id = body.get("id")
        if not session_id:
            raise RuntimeError("Gateway did not return session id")
        return str(session_id)

    def write(self, session_id: str, chunk: bytes) -> None:
        payload = {"data": base64.b64encode(chunk).decode("ascii")}
        self._request("POST", f"/v1/ssh/session/{session_id}/write", payload)

    def read(self, session_id: str) -> dict:
        return self._request("GET", f"/v1/ssh/session/{session_id}/read?timeout={self.read_timeout}", timeout=self.read_timeout + 5)

    def close(self, session_id: str) -> None:
        try:
            self._request("DELETE", f"/v1/ssh/session/{session_id}")
        except Exception:
            pass


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if not args.endpoint:
        parser.error("--endpoint is required (or set SSH_HTTP_ENDPOINT)")
    if not args.token:
        parser.error("--token is required (or set SSH_HTTP_TOKEN)")

    creds = base64.b64encode(f"{args.user}:{args.token}".encode("utf-8")).decode("ascii")
    client = TunnelClient(args.endpoint, creds, args.read_timeout, args.verbose)
    stdout = sys.stdout.buffer
    stdin = sys.stdin.buffer
    stop_event = threading.Event()
    exit_status = 0
    error_queue: "queue.Queue[str]" = queue.Queue()

    try:
        session_id = client.create_session(args.target)
    except Exception as exc:  # noqa: BLE001
        log(f"Failed to create tunnel session: {exc}", args.verbose)
        return 1

    def reader() -> None:
        nonlocal exit_status
        try:
            while not stop_event.is_set():
                try:
                    response = client.read(session_id)
                except Exception as exc:  # noqa: BLE001
                    error_queue.put(f"read failed: {exc}")
                    exit_status = 1
                    stop_event.set()
                    break
                if response.get("data"):
                    try:
                        chunk = base64.b64decode(response["data"])
                    except Exception as exc:  # noqa: BLE001
                        error_queue.put(f"decode failed: {exc}")
                        exit_status = 1
                        stop_event.set()
                        break
                    stdout.write(chunk)
                    stdout.flush()
                if response.get("closed"):
                    stop_event.set()
                    break
        finally:
            stop_event.set()

    def writer() -> None:
        nonlocal exit_status
        try:
            while not stop_event.is_set():
                chunk = stdin.read(args.max_chunk)
                if not chunk:
                    break
                client.write(session_id, chunk)
        except Exception as exc:  # noqa: BLE001
            error_queue.put(f"write failed: {exc}")
            exit_status = 1
        finally:
            stop_event.set()

    reader_thread = threading.Thread(target=reader, name="ssh-http-reader", daemon=True)
    writer_thread = threading.Thread(target=writer, name="ssh-http-writer", daemon=True)
    reader_thread.start()
    writer_thread.start()

    try:
        while not stop_event.is_set():
            time.sleep(0.1)
    except KeyboardInterrupt:
        stop_event.set()
        exit_status = max(exit_status, 130)
    finally:
        client.close(session_id)
        reader_thread.join()
        writer_thread.join()

    while not error_queue.empty():
        log(error_queue.get(), True)

    return exit_status


if __name__ == "__main__":
    sys.exit(main())
