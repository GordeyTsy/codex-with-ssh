#!/usr/bin/env python3
"""Local HTTP listener that forwards traffic to a remote HTTPS endpoint."""
from __future__ import annotations

import argparse
import base64
import contextlib
import logging
import os
import select
import signal
import socket
import socketserver
import ssl
import sys
import threading
import time
from dataclasses import dataclass
from typing import Optional, Tuple
from urllib import request as urllib_request
from urllib.parse import urlparse


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Expose an HTTPS endpoint via a local HTTP listener.")
    parser.add_argument("--listen", default="127.0.0.1", help="Address to bind for the local HTTP listener (default: 127.0.0.1).")
    parser.add_argument("--listen-port", type=int, default=18080, help="Port for the local listener (default: 18080).")
    parser.add_argument("--target", required=True, help="HTTPS URL to connect to (e.g. https://example:6443).")
    parser.add_argument("--sni", default=None, help="Override SNI hostname when connecting upstream.")
    parser.add_argument("--ca-file", default=None, help="Optional CA bundle to trust for the upstream TLS connection.")
    parser.add_argument("--insecure", action="store_true", help="Disable TLS verification against the upstream endpoint.")
    parser.add_argument("--connect-timeout", type=float, default=None, help="Optional timeout (seconds) for establishing upstream connections.")
    parser.add_argument("--idle-timeout", type=float, default=None, help="Optional timeout (seconds) for idle connections.")
    parser.add_argument("--pid-file", required=True, help="File path where the bridge should write its PID.")
    parser.add_argument("--log-file", default=None, help="Redirect logging output to this file instead of stderr.")
    return parser.parse_args()


def configure_logging(log_file: Optional[str]) -> None:
    handlers = None
    if log_file:
        handlers = [logging.FileHandler(log_file)]
    logging.basicConfig(
        level=logging.INFO,
        format="[%(asctime)s] %(levelname)s %(message)s",
        handlers=handlers,
    )


def build_ssl_context(args: argparse.Namespace, hostname: str) -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    if args.ca_file:
        ctx.load_verify_locations(cafile=args.ca_file)
    if args.insecure:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    else:
        ctx.check_hostname = True
        ctx.verify_mode = ssl.CERT_REQUIRED
    return ctx


def select_proxy(target_url: str, hostname: str) -> Optional[str]:
    proxies = urllib_request.getproxies()
    if not proxies:
        return None

    try:
        bypass = urllib_request.proxy_bypass(hostname)
    except Exception:
        bypass = False
    if bypass:
        return None

    parsed_target = urlparse(target_url)
    scheme = parsed_target.scheme.lower()

    proxy = proxies.get(scheme)
    if proxy is None and scheme == "https":
        proxy = proxies.get("https") or proxies.get("http")
    if proxy is None:
        return None

    if "://" not in proxy:
        proxy = f"http://{proxy}"

    return proxy


def parse_proxy(proxy_url: str) -> Tuple[str, int, Optional[str], bool]:
    parsed = urlparse(proxy_url)
    if not parsed.scheme:
        parsed = urlparse(f"http://{proxy_url}")
    if parsed.scheme not in {"http", "https"}:
        raise ValueError(f"Unsupported proxy scheme: {parsed.scheme}")
    if not parsed.hostname:
        raise ValueError("Proxy URL must include a hostname")

    host = parsed.hostname
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    credentials = None
    if parsed.username or parsed.password:
        user = parsed.username or ""
        password = parsed.password or ""
        token = f"{user}:{password}".encode("utf-8")
        credentials = base64.b64encode(token).decode("ascii")

    return host, port, credentials, parsed.scheme == "https"


def read_proxy_response(sock: socket.socket, timeout: Optional[float]) -> bytes:
    if timeout is not None:
        sock.settimeout(timeout)
    response = bytearray()
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("Proxy closed connection before completing CONNECT handshake")
        response.extend(chunk)
        if len(response) > 65536:
            raise RuntimeError("Proxy response too large")
    sock.settimeout(None)
    return bytes(response)


def establish_upstream_socket(
    config: "BridgeConfig",
    wrap_tls: bool,
) -> socket.socket:
    proxy_url = select_proxy(config.target_url, config.target_host)
    raw_sock: Optional[socket.socket] = None
    try:
        if proxy_url:
            proxy_host, proxy_port, proxy_auth, proxy_is_tls = parse_proxy(proxy_url)
            logging.info(
                "Connecting to upstream %s:%s via proxy %s://%s:%s",
                config.target_host,
                config.target_port,
                "https" if proxy_is_tls else "http",
                proxy_host,
                proxy_port,
            )
            raw_sock = socket.create_connection((proxy_host, proxy_port), timeout=config.connect_timeout)
            if proxy_is_tls:
                proxy_ctx = ssl.create_default_context()
                raw_sock = proxy_ctx.wrap_socket(raw_sock, server_hostname=proxy_host)
            request_lines = [
                f"CONNECT {config.target_host}:{config.target_port} HTTP/1.1",
                f"Host: {config.target_host}:{config.target_port}",
            ]
            if proxy_auth:
                request_lines.append(f"Proxy-Authorization: Basic {proxy_auth}")
            request_lines.extend(["", ""])
            raw_sock.sendall("\r\n".join(request_lines).encode("ascii"))
            response = read_proxy_response(raw_sock, config.connect_timeout)
            status_line = response.split(b"\r\n", 1)[0].decode("iso-8859-1", errors="replace")
            parts = status_line.split(" ")
            if len(parts) < 2:
                raise RuntimeError(f"Invalid response from proxy: {status_line!r}")
            try:
                status_code = int(parts[1])
            except ValueError as exc:
                raise RuntimeError(f"Invalid status code from proxy: {status_line!r}") from exc
            if status_code != 200:
                raise RuntimeError(f"Proxy CONNECT failed with status {status_code}")
        else:
            logging.info("Connecting directly to upstream %s:%s", config.target_host, config.target_port)
            raw_sock = socket.create_connection((config.target_host, config.target_port), timeout=config.connect_timeout)

        if wrap_tls:
            if config.connect_timeout is not None:
                raw_sock.settimeout(config.connect_timeout)
            ssl_sock = config.ssl_context.wrap_socket(raw_sock, server_hostname=config.server_hostname)
            ssl_sock.settimeout(None)
            return ssl_sock
        raw_sock.settimeout(None)
        return raw_sock
    except Exception:
        if raw_sock is not None:
            with contextlib.suppress(Exception):
                raw_sock.close()
        raise


def relay_bidirectional(
    client_sock: socket.socket,
    upstream_sock: socket.socket,
    idle_timeout: Optional[float],
    initial_client_data: bytes = b"",
) -> None:
    sockets = {client_sock: upstream_sock, upstream_sock: client_sock}
    timeout = idle_timeout if idle_timeout and idle_timeout > 0 else None
    if initial_client_data:
        try:
            upstream_sock.sendall(initial_client_data)
        except (OSError, ssl.SSLWantWriteError) as exc:
            logging.debug("Failed to send initial client data: %s", exc)
            return

    while True:
        try:
            readable, _, _ = select.select(list(sockets.keys()), [], [], timeout)
        except (OSError, ValueError) as exc:
            logging.debug("select() failed: %s", exc)
            break
        if not readable:
            logging.warning("Closing connection after %.1fs of inactivity", idle_timeout)
            break
        for sock in readable:
            other = sockets[sock]
            try:
                data = sock.recv(65536)
            except (OSError, ssl.SSLWantReadError) as exc:
                logging.debug("recv() failed: %s", exc)
                data = b""
            if not data:
                return
            try:
                other.sendall(data)
            except (OSError, ssl.SSLWantWriteError) as exc:
                logging.debug("sendall() failed: %s", exc)
                return


@dataclass
class BridgeConfig:
    target_url: str
    target_host: str
    target_port: int
    ssl_context: ssl.SSLContext
    server_hostname: str
    connect_timeout: Optional[float]
    idle_timeout: Optional[float]


class BridgeTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, server_address: Tuple[str, int], handler_class, config: BridgeConfig):
        super().__init__(server_address, handler_class)
        self.bridge_config = config


def parse_client_preamble(client_sock: socket.socket) -> Tuple[str, Optional[str], bytes, bytes]:
    buffer = bytearray()
    separator = None
    try:
        client_sock.settimeout(1.0)
        while len(buffer) < 65536:
            chunk = client_sock.recv(4096)
            if not chunk:
                break
            buffer.extend(chunk)
            if b"\r\n\r\n" in buffer:
                separator = b"\r\n\r\n"
                break
            if b"\n\n" in buffer:
                separator = b"\n\n"
                break
            if len(chunk) < 4096:
                break
    except socket.timeout:
        pass
    finally:
        client_sock.settimeout(None)

    if not buffer:
        return "none", None, b"", b""

    if separator is None:
        return "direct", None, bytes(buffer), b""

    header_end = buffer.find(separator) + len(separator)
    header_bytes = bytes(buffer[:header_end])
    remainder = bytes(buffer[header_end:])
    first_line = header_bytes.splitlines()[0].strip()
    if first_line.upper().startswith(b"CONNECT "):
        parts = first_line.split()
        if len(parts) >= 2:
            return "connect", parts[1].decode("ascii", errors="ignore"), header_bytes, remainder
        return "connect", None, header_bytes, remainder
    return "direct", None, bytes(buffer), b""


class BridgeRequestHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        config: BridgeConfig = self.server.bridge_config  # type: ignore[attr-defined]
        peer = self.client_address
        logging.info(
            "Accepted connection from %s -> forwarding to %s:%s",
            peer,
            config.target_host,
            config.target_port,
        )
        mode, target, header_bytes, remainder = parse_client_preamble(self.request)

        try:
            upstream = establish_upstream_socket(config, wrap_tls=(mode != "connect"))
        except Exception as exc:
            logging.exception("Failed to connect to upstream %s:%s: %s", config.target_host, config.target_port, exc)
            return

        initial_data = b""

        if mode == "connect":
            host_port = target or ""
            host, _, port_str = host_port.partition(":")
            port = int(port_str) if port_str else 443
            if not host:
                logging.warning("CONNECT request missing host from %s", peer)
                self.request.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
                upstream.close()
                return
            if host.lower() not in {config.target_host.lower()}:
                logging.warning("Rejecting CONNECT request to %s from %s", target, peer)
                self.request.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
                upstream.close()
                return
            if port != config.target_port:
                logging.warning("Rejecting CONNECT request to %s (port mismatch) from %s", target, peer)
                self.request.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
                upstream.close()
                return
            self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            initial_data = remainder
        else:
            initial_data = header_bytes if header_bytes else remainder

        try:
            relay_bidirectional(
                self.request,
                upstream,
                config.idle_timeout,
                initial_client_data=initial_data,
            )
        finally:
            with contextlib.suppress(Exception):
                upstream.shutdown(socket.SHUT_RDWR)
            with contextlib.suppress(Exception):
                upstream.close()
            with contextlib.suppress(Exception):
                self.request.shutdown(socket.SHUT_RDWR)
            with contextlib.suppress(Exception):
                self.request.close()
            logging.info("Connection from %s closed", peer)


def run_bridge(args: argparse.Namespace) -> None:
    parsed = urlparse(args.target)
    if parsed.scheme.lower() != "https":
        raise ValueError("Only https:// targets are supported")
    if not parsed.hostname:
        raise ValueError("HTTPS target must include a hostname")

    target_host = parsed.hostname
    target_port = parsed.port or 443
    ssl_context = build_ssl_context(args, target_host)
    server_hostname = args.sni or target_host

    config = BridgeConfig(
        target_url=args.target,
        target_host=target_host,
        target_port=target_port,
        ssl_context=ssl_context,
        server_hostname=server_hostname,
        connect_timeout=args.connect_timeout,
        idle_timeout=args.idle_timeout,
    )

    server = BridgeTCPServer((args.listen, args.listen_port), BridgeRequestHandler, config)
    stop_event = threading.Event()

    def handle_signal(signum: int, _frame: Optional[object]) -> None:
        logging.info("Received signal %s, shutting down", signum)
        stop_event.set()
        server.shutdown()

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        with contextlib.suppress(NotImplementedError):
            signal.signal(sig, handle_signal)

    pid_dir = os.path.dirname(os.path.abspath(args.pid_file)) or "."
    os.makedirs(pid_dir, exist_ok=True)
    with open(args.pid_file, "w", encoding="utf-8") as fh:
        fh.write(str(os.getpid()))

    logging.info(
        "Bridge listening on http://%s:%s -> https://%s:%s",
        args.listen,
        args.listen_port,
        target_host,
        target_port,
    )

    server_thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.5}, daemon=True)
    server_thread.start()

    try:
        while not stop_event.is_set():
            time.sleep(0.5)
    except KeyboardInterrupt:
        logging.info("KeyboardInterrupt received, shutting down")
        stop_event.set()
        server.shutdown()
    finally:
        server.shutdown()
        server.server_close()
        server_thread.join()
        with contextlib.suppress(FileNotFoundError):
            if os.path.exists(args.pid_file):
                os.remove(args.pid_file)


def main() -> None:
    args = parse_args()
    configure_logging(args.log_file)
    try:
        run_bridge(args)
    except Exception as exc:
        logging.error("Bridge terminated due to error: %s", exc)
        sys.exit(1)


if __name__ == "__main__":
    main()
