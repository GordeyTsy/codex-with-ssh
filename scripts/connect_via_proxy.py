#!/usr/bin/env python3
"""ProxyCommand helper that tunnels SSH through HTTP(S) CONNECT proxies."""
from __future__ import annotations

import argparse
import base64
import logging
import os
import selectors
import socket
import ssl
import sys
import time
from typing import Optional, Tuple
from urllib.parse import urlparse


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Establish a TCP tunnel via an HTTP(S) proxy")
    parser.add_argument("--proxy", dest="proxy_url", required=True, help="Proxy URL (http:// or https://)")
    parser.add_argument("--destination-host", required=True, help="Destination host passed by ssh (%h)")
    parser.add_argument("--destination-port", required=True, help="Destination port passed by ssh (%p)")
    parser.add_argument("--connect-timeout", type=float, default=20.0, help="Timeout for establishing proxy and upstream connections")
    parser.add_argument("--idle-timeout", type=float, default=0.0, help="Abort if no traffic flows for N seconds (0 disables)")
    parser.add_argument("--read-timeout", type=float, default=0.0, help="Abort if proxy handshake stalls longer than N seconds (0 disables)")
    parser.add_argument("--log-level", default=os.environ.get("SSH_PROXY_LOG_LEVEL", "WARNING"))
    parser.add_argument("--ca-file", default=os.environ.get("SSH_PROXY_CA_FILE"), help="Custom CA bundle for HTTPS proxies")
    parser.add_argument("--insecure", action="store_true", default=os.environ.get("SSH_PROXY_INSECURE", "0") == "1", help="Disable TLS verification when talking to HTTPS proxy")
    return parser.parse_args()


def configure_logging(level: str) -> None:
    numeric = getattr(logging, level.upper(), logging.WARNING)
    logging.basicConfig(stream=sys.stderr, level=numeric, format="[%(asctime)s] %(levelname)s %(message)s")


def parse_proxy(proxy_url: str) -> Tuple[str, int, Optional[str], bool]:
    parsed = urlparse(proxy_url if "://" in proxy_url else f"http://{proxy_url}")
    if parsed.scheme not in {"http", "https"}:
        raise ValueError(f"Unsupported proxy scheme: {parsed.scheme}")
    if not parsed.hostname:
        raise ValueError("Proxy URL must include a hostname")
    host = parsed.hostname
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    auth_header: Optional[str] = None
    if parsed.username or parsed.password:
        user = parsed.username or ""
        password = parsed.password or ""
        token = f"{user}:{password}".encode("utf-8")
        auth_header = base64.b64encode(token).decode("ascii")
    return host, port, auth_header, parsed.scheme == "https"


def create_proxy_socket(host: str, port: int, timeout: float) -> socket.socket:
    return socket.create_connection((host, port), timeout=timeout)


def wrap_proxy_socket(sock: socket.socket, host: str, ca_file: Optional[str], insecure: bool) -> ssl.SSLSocket:
    ctx = ssl.create_default_context(cafile=ca_file) if ca_file else ssl.create_default_context()
    if insecure:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx.wrap_socket(sock, server_hostname=host)


def send_connect_request(sock: socket.socket, dest_host: str, dest_port: int, auth_header: Optional[str]) -> None:
    request_lines = [
        f"CONNECT {dest_host}:{dest_port} HTTP/1.1",
        f"Host: {dest_host}:{dest_port}",
    ]
    if auth_header:
        request_lines.append(f"Proxy-Authorization: Basic {auth_header}")
    request_lines.extend(["", ""])
    payload = "\r\n".join(request_lines).encode("ascii")
    sock.sendall(payload)


def read_proxy_response(sock: socket.socket, read_timeout: float) -> None:
    buffer = bytearray()
    deadline = time.monotonic() + read_timeout if read_timeout > 0 else None
    while b"\r\n\r\n" not in buffer:
        if deadline and time.monotonic() > deadline:
            raise TimeoutError("Timed out waiting for proxy response")
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("Proxy closed the connection during CONNECT handshake")
        buffer.extend(chunk)
        if len(buffer) > 65536:
            raise ValueError("Proxy response too large")
    status_line = buffer.split(b"\r\n", 1)[0].decode("iso-8859-1", errors="replace")
    parts = status_line.split()
    if len(parts) < 2:
        raise ValueError(f"Invalid response from proxy: {status_line!r}")
    try:
        status_code = int(parts[1])
    except ValueError as exc:  # noqa: B904
        raise ValueError(f"Invalid proxy status line: {status_line!r}") from exc
    if status_code != 200:
        raise ConnectionError(f"Proxy CONNECT failed with status {status_code}")


def pump_streams(sock: socket.socket, idle_timeout: float) -> None:
    sel = selectors.DefaultSelector()
    sock.setblocking(False)
    stdin_fd = sys.stdin.buffer.fileno()
    stdout_fd = sys.stdout.buffer.fileno()
    os.set_blocking(stdin_fd, False)
    os.set_blocking(stdout_fd, False)

    sel.register(sock, selectors.EVENT_READ, "sock")
    sel.register(stdin_fd, selectors.EVENT_READ, "stdin")

    eof_from_stdin = False
    last_activity = time.monotonic()

    def send_all(data: bytes) -> None:
        view = memoryview(data)
        while view:
            sent = sock.send(view)
            if sent == 0:
                raise ConnectionError("Proxy socket closed while sending data")
            view = view[sent:]

    while True:
        timeout = None
        if idle_timeout > 0:
            timeout = max(0.0, idle_timeout - (time.monotonic() - last_activity))
        events = sel.select(timeout)
        if not events:
            if idle_timeout > 0 and (time.monotonic() - last_activity) >= idle_timeout:
                raise TimeoutError("Idle timeout reached")
            continue
        for key, _ in events:
            if key.data == "stdin":
                try:
                    chunk = os.read(stdin_fd, 32768)
                except BlockingIOError:
                    continue
                if not chunk:
                    if not eof_from_stdin:
                        try:
                            sock.shutdown(socket.SHUT_WR)
                        except OSError:
                            pass
                        eof_from_stdin = True
                    sel.unregister(stdin_fd)
                else:
                    send_all(chunk)
                    last_activity = time.monotonic()
            else:
                try:
                    data = sock.recv(32768)
                except BlockingIOError:
                    continue
                if not data:
                    return
                os.write(stdout_fd, data)
                last_activity = time.monotonic()


def main() -> int:
    args = parse_args()
    configure_logging(args.log_level)

    try:
        dest_port = int(args.destination_port)
    except ValueError:
        logging.error("Invalid destination port: %s", args.destination_port)
        return 2

    try:
        proxy_host, proxy_port, auth_header, is_tls = parse_proxy(args.proxy_url)
    except Exception as exc:  # noqa: BLE001
        logging.error("%s", exc)
        return 2

    logging.info("Connecting to proxy %s:%s", proxy_host, proxy_port)
    proxy_sock: Optional[socket.socket] = None
    try:
        proxy_sock = create_proxy_socket(proxy_host, proxy_port, timeout=args.connect_timeout)
        if is_tls:
            proxy_sock = wrap_proxy_socket(proxy_sock, proxy_host, args.ca_file, args.insecure)
        send_connect_request(proxy_sock, args.destination_host, dest_port, auth_header)
        read_proxy_response(proxy_sock, args.read_timeout)
        logging.info("Proxy CONNECT established to %s:%s", args.destination_host, dest_port)
        pump_streams(proxy_sock, args.idle_timeout)
        return 0
    except Exception as exc:  # noqa: BLE001
        logging.error("Proxy tunnel failed: %s", exc)
        return 1
    finally:
        if proxy_sock is not None:
            try:
                proxy_sock.close()
            except Exception:  # noqa: BLE001
                pass


if __name__ == "__main__":
    sys.exit(main())
