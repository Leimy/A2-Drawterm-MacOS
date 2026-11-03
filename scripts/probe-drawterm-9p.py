#!/usr/bin/env python3
"""Paint a test pattern through drawterm's shell-free 9P device export."""

import argparse
import os
from pathlib import Path
import socket
import struct
import subprocess
import time


TVERSION, TATTACH, TWALK, TOPEN, TREAD, TWRITE, TCLUNK = 100, 104, 110, 112, 116, 118, 120
RERROR = 107


def p9str(value):
    data = value.encode()
    return struct.pack("<H", len(data)) + data


def message(kind, tag, body=b""):
    return struct.pack("<IBH", 7 + len(body), kind, tag) + body


def read_exact(sock, count):
    result = b""
    while len(result) < count:
        part = sock.recv(count - len(result))
        if not part:
            raise EOFError("drawterm closed the 9P stream")
        result += part
    return result


class NineP:
    def __init__(self, sock):
        self.sock = sock
        self.tag = 1

    def rpc(self, kind, body=b"", tag=None):
        if tag is None:
            tag = self.tag
            self.tag += 1
        self.sock.sendall(message(kind, tag, body))
        header = read_exact(self.sock, 7)
        size, reply_kind, reply_tag = struct.unpack("<IBH", header)
        reply = read_exact(self.sock, size - 7)
        if reply_tag != tag:
            raise RuntimeError(f"9P tag mismatch: sent {tag}, received {reply_tag}")
        if reply_kind == RERROR:
            length = struct.unpack_from("<H", reply)[0]
            raise RuntimeError(reply[2:2 + length].decode(errors="replace"))
        if reply_kind != kind + 1:
            raise RuntimeError(f"unexpected 9P reply {reply_kind} to request {kind}")
        return reply

    def walk(self, source_fid, fid, path):
        names = path.split("/")
        body = struct.pack("<IIH", source_fid, fid, len(names))
        reply = self.rpc(TWALK, body + b"".join(p9str(name) for name in names))
        count = struct.unpack_from("<H", reply)[0]
        if count != len(names):
            raise RuntimeError(f"partial walk of {path}: {count}/{len(names)}")

    def open(self, fid, mode):
        self.rpc(TOPEN, struct.pack("<IB", fid, mode))

    def read(self, fid, count, offset=0):
        reply = self.rpc(TREAD, struct.pack("<IQI", fid, offset, count))
        length = struct.unpack_from("<I", reply)[0]
        return reply[4:4 + length]

    def write(self, fid, data, offset=0):
        reply = self.rpc(TWRITE, struct.pack("<IQI", fid, offset, len(data)) + data)
        length = struct.unpack_from("<I", reply)[0]
        if length != len(data):
            raise RuntimeError(f"short 9P write: {length}/{len(data)}")

    def clunk(self, fid):
        self.rpc(TCLUNK, struct.pack("<I", fid))


def draw_rect_header(x0, y0, x1, y1):
    # Plan 9's BPLONG draw-protocol encoding is little-endian.
    return b"y" + struct.pack("<Iiiii", 0, x0, y0, x1, y1)


def pixels(x0, y0, width, height):
    data = bytearray(width * height * 4)
    n = 0
    for y in range(y0, y0 + height):
        for x in range(x0, x0 + width):
            # drawterm's ARGB32 screen is copied to a BGRA8 Metal texture.
            data[n:n + 4] = bytes(((x + y) & 255, (2 * y) & 255, (2 * x) & 255, 255))
            n += 4
    return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--drawterm", default=os.environ.get("A2_DRAWTERM", str(Path(__file__).resolve().parents[1] / "build/native-desktop/drawterm")))
    parser.add_argument("--hold", type=float, default=3.0)
    args = parser.parse_args()

    parent, child = socket.socketpair()
    process = subprocess.Popen(
        [args.drawterm, "-D"], stdin=child, stdout=child, stderr=subprocess.PIPE,
        close_fds=True,
    )
    child.close()
    parent.settimeout(10)
    ninep = NineP(parent)
    try:
        reply = ninep.rpc(TVERSION, struct.pack("<I", 65536) + p9str("9P2000"), 0xFFFF)
        msize = struct.unpack_from("<I", reply)[0]
        ninep.rpc(TATTACH, struct.pack("<II", 1, 0xFFFFFFFF) + p9str("oberon") + p9str(""))

        ninep.walk(1, 2, "dev/draw/new")
        ninep.open(2, 2)
        fields = ninep.read(2, 12 * 12).decode().split()
        if len(fields) != 12:
            raise RuntimeError(f"invalid draw control record: {fields!r}")
        client_id = int(fields[0])
        channel = fields[2]
        x0, y0, x1, y1 = map(int, fields[4:8])
        print(f"draw control: client={client_id} channel={channel} rect=({x0},{y0})-({x1},{y1})")
        if channel != "a8r8g8b8":
            raise RuntimeError(f"unsupported screen channel {channel}; expected a8r8g8b8")

        ninep.walk(1, 3, f"dev/draw/{client_id}/data")
        ninep.open(3, 1)
        width = x1 - x0
        max_payload = msize - 23
        rows = max(1, (max_payload - 21) // (width * 4))
        for top in range(y0, y1, rows):
            bottom = min(top + rows, y1)
            data = draw_rect_header(x0, top, x1, bottom)
            data += pixels(x0, top, width, bottom - top)
            ninep.write(3, data)
        ninep.write(3, b"v")
        print(f"painted {width}x{y1-y0} {channel} screen via drawterm client {client_id}")
        time.sleep(args.hold)
        ninep.clunk(3)
        ninep.clunk(2)
    finally:
        parent.close()
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
        error = process.stderr.read().decode(errors="replace")
        if error:
            print(error, end="", file=__import__("sys").stderr)


if __name__ == "__main__":
    main()
