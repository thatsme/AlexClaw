"""Egress filter for the player's browser.

A recipe's navigations, and every request its pages make, leave from Chromium.
Chromium is forced through this forward proxy (see browser.chromium_args), which
applies the same rule as AlexClaw's HostGuard: resolve the name, refuse if the
name does not resolve or ANY address it resolves to is internal, then connect to
an address it checked — so there is no second lookup between check and connect.

Plain HTTP is forwarded one request per connection (the client is told
`Connection: close`), so every request is checked on its own, redirects
included. HTTPS and WebSockets over TLS arrive as CONNECT: the tunnel is opened
only to a checked address. A refusal is `403 Forbidden` with the header
`x-alexclaw-egress: refused`, which the player reads to tell a refused
navigation from a page that answered 403 itself.
"""

import asyncio
import ipaddress
import logging
import socket
from urllib.parse import urlsplit

logger = logging.getLogger(__name__)

_BLOCKED_NETWORKS = [
    ipaddress.ip_network(n)
    for n in (
        "0.0.0.0/8",
        "10.0.0.0/8",
        "100.64.0.0/10",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "198.18.0.0/15",
        "224.0.0.0/4",
        "240.0.0.0/4",
        "::1/128",
        "::/128",
        "fc00::/7",
        "fe80::/10",
    )
]

_MAX_HEAD = 64 * 1024
_CONNECT_TIMEOUT = 10
REFUSED_HEADER = "x-alexclaw-egress"
_HOP_BY_HOP = {b"connection", b"keep-alive", b"proxy-connection", b"proxy-authorization"}


class Blocked(Exception):
    """A destination the browser may not reach."""


def is_blocked_ip(ip: str) -> bool:
    """Whether `ip` is internal: loopback, private, shared, link-local,
    benchmarking, multicast, reserved, broadcast, or the IPv4-mapped form of one."""
    addr = ipaddress.ip_address(ip)
    if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped:
        addr = addr.ipv4_mapped
    return any(addr in net for net in _BLOCKED_NETWORKS if net.version == addr.version)


def check_host(host: str, port: int, allow: frozenset) -> list:
    """The addresses to connect to for `host:port`, or Blocked.

    `allow` holds exact "host:port" origins let through although internal.
    """
    addresses = _resolve(host, port)
    if not addresses:
        raise Blocked(f"{host} does not resolve")
    if f"{host}:{port}" in allow:
        return addresses
    if any(is_blocked_ip(a) for a in addresses):
        raise Blocked(f"{host}:{port} is internal")
    return addresses


def _resolve(host: str, port: int) -> list:
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except (socket.gaierror, UnicodeError):
        return []
    # An IPv6 link-local address may carry a zone ("fe80::1%eth0").
    return list(dict.fromkeys(info[4][0].split("%")[0] for info in infos))


class EgressProxy:
    """A forward proxy on 127.0.0.1 that lets through only checked destinations."""

    def __init__(self, allow: frozenset = frozenset()):
        self.allow = frozenset(allow)
        self._server = None
        self._tasks: set = set()

    async def start(self) -> int:
        self._server = await asyncio.start_server(self._handle, "127.0.0.1", 0)
        return self._server.sockets[0].getsockname()[1]

    async def stop(self):
        if self._server:
            self._server.close()
            await self._server.wait_closed()
            self._server = None
        for task in list(self._tasks):
            task.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)

    async def _handle(self, reader, writer):
        task = asyncio.current_task()
        self._tasks.add(task)
        try:
            await self._serve(reader, writer)
        except (ConnectionError, ValueError, asyncio.IncompleteReadError, asyncio.LimitOverrunError):
            # A client that hangs up or sends something malformed gets the
            # connection closed; nothing is forwarded.
            pass
        finally:
            self._tasks.discard(task)
            writer.close()

    async def _serve(self, reader, writer):
        head = await reader.readuntil(b"\r\n\r\n")
        if len(head) > _MAX_HEAD:
            return await _refuse(writer, 431, "Request Header Fields Too Large")

        request_line, *header_lines = head[:-4].split(b"\r\n")
        try:
            method, target, version = request_line.decode("latin-1").split(" ")
        except ValueError:
            return await _refuse(writer, 400, "Bad Request")

        if method == "CONNECT":
            return await self._tunnel(target, reader, writer)
        if target.startswith("http://"):
            return await self._forward(method, target, version, header_lines, reader, writer)
        # Origin-form: a request for the proxy itself. It serves nothing.
        return await _refuse(writer, 400, "Bad Request")

    async def _open(self, host, port):
        addresses = await asyncio.to_thread(check_host, host, port, self.allow)
        last_error = None
        for address in addresses:
            try:
                return await asyncio.wait_for(
                    asyncio.open_connection(address, port), _CONNECT_TIMEOUT
                )
            except (OSError, asyncio.TimeoutError) as e:
                last_error = e
        raise ConnectionError(f"could not connect to {host}:{port}: {last_error}")

    async def _tunnel(self, target, reader, writer):
        host, port = _split_authority(target)
        if host is None or port is None:
            return await _refuse(writer, 400, "Bad Request")
        try:
            up_reader, up_writer = await self._open(host, port)
        except Blocked as e:
            logger.warning("Egress refused: CONNECT %s (%s)", target, e)
            return await _refuse(writer, 403, "Forbidden")
        except ConnectionError:
            return await _refuse(writer, 502, "Bad Gateway")

        writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await writer.drain()
        await _pipe_both(reader, writer, up_reader, up_writer)

    async def _forward(self, method, target, version, header_lines, reader, writer):
        url = urlsplit(target)
        host, port = url.hostname, url.port or 80
        if not host:
            return await _refuse(writer, 400, "Bad Request")

        headers = [h for h in header_lines if h.split(b":", 1)[0].strip().lower() not in _HOP_BY_HOP]
        if any(h.split(b":", 1)[0].strip().lower() == b"transfer-encoding" for h in headers):
            # A streamed request body cannot be bounded to this one request.
            return await _refuse(writer, 411, "Length Required")
        length = _content_length(headers)

        try:
            up_reader, up_writer = await self._open(host, port)
        except Blocked as e:
            logger.warning("Egress refused: %s %s://%s:%s (%s)", method, url.scheme, host, port, e)
            return await _refuse(writer, 403, "Forbidden")
        except ConnectionError:
            return await _refuse(writer, 502, "Bad Gateway")

        path = url.path or "/"
        if url.query:
            path += "?" + url.query
        request = [f"{method} {path} {version}".encode("latin-1"), *headers, b"Connection: close"]
        up_writer.write(b"\r\n".join(request) + b"\r\n\r\n")
        if length:
            up_writer.write(await reader.readexactly(length))
        await up_writer.drain()

        try:
            await _relay_response(up_reader, writer)
        finally:
            up_writer.close()


async def _relay_response(up_reader, writer):
    """Copy the response, telling the client this connection ends with it."""
    head = await up_reader.readuntil(b"\r\n\r\n")
    status_line, *header_lines = head[:-4].split(b"\r\n")
    headers = [h for h in header_lines if h.split(b":", 1)[0].strip().lower() not in _HOP_BY_HOP]
    writer.write(b"\r\n".join([status_line, *headers, b"Connection: close"]) + b"\r\n\r\n")
    await _pipe(up_reader, writer)


def _split_authority(authority: str):
    """("host", port) from a CONNECT target, "host:port" or "[v6]:port";
    (None, None) if malformed."""
    host, sep, port = authority.rpartition(":")
    host = host.strip("[]")
    if not sep or not host or not port.isdigit() or not 0 < int(port) < 65536:
        return None, None
    return host, int(port)


def _content_length(headers) -> int:
    for h in headers:
        name, _, value = h.partition(b":")
        if name.strip().lower() == b"content-length":
            return int(value.strip())
    return 0


async def _refuse(writer, status: int, reason: str):
    marker = f"{REFUSED_HEADER}: refused\r\n" if status == 403 else ""
    writer.write(
        f"HTTP/1.1 {status} {reason}\r\n{marker}Content-Length: 0\r\nConnection: close\r\n\r\n".encode()
    )
    await writer.drain()


async def _pipe(reader, writer):
    while data := await reader.read(65536):
        writer.write(data)
        await writer.drain()


async def _pipe_both(reader, writer, up_reader, up_writer):
    """Relay a tunnel both ways; when either side closes, the tunnel ends."""
    tasks = [
        asyncio.ensure_future(_pipe(reader, up_writer)),
        asyncio.ensure_future(_pipe(up_reader, writer)),
    ]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        up_writer.close()
