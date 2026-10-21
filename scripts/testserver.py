#!/usr/bin/env python3
"""Local web server for the UI and download tests.

Serves a static folder (TestSite/) plus generated binary files, with HTTP Range support so
pause/resume can be tested. Query options on any file:
  ?download=1  add Content-Disposition: attachment
  ?rate=256    throttle the body to about 256 KB/s
Generated files: /generated/<size>.bin, e.g. /generated/20MB.bin or /generated/512KB.bin.

Usage: python3 scripts/testserver.py --root TestSite --port 8000
"""

import argparse
import email.utils
import mimetypes
import os
import re
import socket
import sys
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

CHUNK = 64 * 1024
# Byte at offset p is p % 256; a 64 KiB block repeats exactly, so any range can be sliced from it.
PATTERN = bytes(i % 256 for i in range(CHUNK))
SIZE_RE = re.compile(r"^/generated/(\d+)(KB|MB|B)\.bin$", re.IGNORECASE)
# Streaming types the system's table may not know (HLS playlists and segments).
for media_type, extension in [("application/vnd.apple.mpegurl", ".m3u8"), ("video/mp2t", ".ts"),
                              ("video/iso.segment", ".m4s"), ("video/mp4", ".mp4"), ("audio/aac", ".aac")]:
    mimetypes.add_type(media_type, extension)


class Handler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "BrowserTestServer/1.0"

    def do_GET(self):
        self.respond(send_body=True)

    def do_HEAD(self):
        self.respond(send_body=False)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.log_date_time_string(), fmt % args))

    def respond(self, send_body):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/generated/tone.wav":
            data = tone_wav()
            self.send_bytes(data, "audio/wav", query, send_body)
            return
        match = SIZE_RE.match(parsed.path)
        if match:
            size = int(match.group(1)) * {"b": 1, "kb": 1024, "mb": 1024 * 1024}[match.group(2).lower()]
            name = os.path.basename(parsed.path)
            self.send_ranged(size, "application/octet-stream", name, None, query, send_body, generated=True)
            return

        path = self.translate_path(unquote(parsed.path))
        if os.path.isdir(path):
            path = os.path.join(path, "index.html")
        if not os.path.isfile(path):
            self.send_error(404, "Not found")
            return
        content_type = mimetypes.guess_type(path)[0] or "application/octet-stream"
        size = os.path.getsize(path)
        with open(path, "rb") as handle:
            self.send_ranged(size, content_type, os.path.basename(path), handle, query, send_body,
                             generated=False, mtime=os.path.getmtime(path))

    def send_bytes(self, data, content_type, query, send_body):
        import io
        self.send_ranged(len(data), content_type, "tone.wav", io.BytesIO(data), query, send_body, generated=False)

    def send_ranged(self, size, content_type, name, handle, query, send_body, generated, mtime=None):
        start, end = 0, size - 1
        status = 200
        range_header = self.headers.get("Range")
        if range_header:
            parsed = parse_range(range_header, size)
            if parsed is None:
                self.send_response(416)
                self.send_header("Content-Range", "bytes */%d" % size)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            start, end = parsed
            status = 206
        length = max(0, end - start + 1)

        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", '"%s-%d"' % (name, size))
        self.send_header("Last-Modified", email.utils.formatdate(mtime or 0, usegmt=True))
        self.send_header("Cache-Control", "no-store")
        if status == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        if generated or query.get("download") == ["1"]:
            self.send_header("Content-Disposition", 'attachment; filename="%s"' % name)
        self.end_headers()
        if not send_body or length == 0:
            return

        rate = int(query.get("rate", ["0"])[0] or 0) * 1024
        sent = 0
        began = time.monotonic()
        position = start
        try:
            if handle is not None:
                handle.seek(start)
            while sent < length:
                count = min(CHUNK, length - sent)
                if handle is not None:
                    data = handle.read(count)
                else:
                    offset = position % CHUNK
                    data = (PATTERN[offset:] + PATTERN)[:count]
                if not data:
                    break
                self.wfile.write(data)
                sent += len(data)
                position += len(data)
                if rate:
                    expected = sent / rate
                    elapsed = time.monotonic() - began
                    if expected > elapsed:
                        time.sleep(expected - elapsed)
        except (BrokenPipeError, ConnectionResetError):
            pass


_TONE = None


def tone_wav(seconds=8, rate=22050, frequency=440):
    """A mono 16-bit sine tone, built once."""
    global _TONE
    if _TONE is None:
        import math
        import struct
        frames = b"".join(
            struct.pack("<h", int(12000 * math.sin(2 * math.pi * frequency * i / rate)))
            for i in range(seconds * rate))
        header = b"RIFF" + struct.pack("<I", 36 + len(frames)) + b"WAVEfmt " + struct.pack(
            "<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16) + b"data" + struct.pack("<I", len(frames))
        _TONE = header + frames
    return _TONE


def parse_range(header, size):
    """Returns (start, end) for a single 'bytes=' range, or None when it can't be satisfied."""
    match = re.match(r"^bytes=(\d*)-(\d*)$", header.strip())
    if not match or size == 0:
        return None
    first, last = match.groups()
    if first == "" and last == "":
        return None
    if first == "":
        suffix = int(last)
        if suffix == 0:
            return None
        return max(0, size - suffix), size - 1
    start = int(first)
    end = int(last) if last else size - 1
    if start >= size or end < start:
        return None
    return start, min(end, size - 1)


class DualStackServer(ThreadingHTTPServer):
    """Listens on IPv6 and IPv4 so both ::1 and 127.0.0.1 reach it as "localhost"."""

    address_family = socket.AF_INET6
    daemon_threads = True

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default="TestSite")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    root = os.path.abspath(args.root)
    handler = lambda *a, **kw: Handler(*a, directory=root, **kw)
    try:
        server = DualStackServer(("::", args.port), handler)
    except OSError:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    print("Serving %s on port %d" % (root, args.port), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
