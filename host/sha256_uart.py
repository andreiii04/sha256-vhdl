#!/usr/bin/env python3
"""Host side of the sha256_uart_top protocol (115200 8N1).

    host -> FPGA   'S' <len> <len bytes>      SHA-256 of 0..55 bytes
                   'B' <80 bytes>             double SHA-256 of a block header
    FPGA -> host   'K' <32 bytes digest>  or  'E'

Examples:
    python3 host/sha256_uart.py --port /dev/tty.usbserial-XXXX string "abc"
    python3 host/sha256_uart.py --port /dev/tty.usbserial-XXXX genesis
    python3 host/sha256_uart.py --port /dev/tty.usbserial-XXXX selftest
    python3 host/sha256_uart.py --fake selftest      # no board: software model

Needs pyserial for real hardware (pip install pyserial).
"""
import argparse
import hashlib
import random
import sys

MAX_STRING_LEN = 55

GENESIS_HEADER = bytes.fromhex(
    "01000000" + "00" * 32
    + "3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a"
    + "29ab5f49" + "ffff001d" + "1dac2b7c"
)
BLOCK_125552_HEADER = bytes.fromhex(
    "01000000"
    + "81cd02ab7e569e8bcd9317e2fe99f2de44d49ab2b8851ba4a308000000000000"
    + "e320b6c2fffc8d750423db8b1eb942ae710e951ed797f7affc8892b0f1fc122b"
    + "c7f5d74d" + "f2b9441a" + "42a14695"
)


class ProtocolError(Exception):
    pass


def string_frame(msg: bytes) -> bytes:
    if len(msg) > MAX_STRING_LEN:
        raise ValueError(f"string is {len(msg)} bytes, the FPGA accepts at most {MAX_STRING_LEN}")
    return b"S" + bytes([len(msg)]) + msg


def header_frame(header: bytes) -> bytes:
    if len(header) != 80:
        raise ValueError(f"header is {len(header)} bytes, expected 80")
    return b"B" + header


class FakeDevice:
    """Software model of the FPGA side, for trying the script without a board."""

    def __init__(self):
        self._rx = b""

    def write(self, data: bytes) -> None:
        if data[:1] == b"S" and len(data) >= 2 and data[1] <= MAX_STRING_LEN:
            self._rx += b"K" + hashlib.sha256(data[2:2 + data[1]]).digest()
        elif data[:1] == b"B" and len(data) == 81:
            self._rx += b"K" + hashlib.sha256(hashlib.sha256(data[1:]).digest()).digest()
        else:
            self._rx += b"E"

    def read(self, n: int) -> bytes:
        out, self._rx = self._rx[:n], self._rx[n:]
        return out


class Sha256Fpga:
    def __init__(self, dev):
        self.dev = dev

    def _transact(self, frame: bytes) -> bytes:
        self.dev.write(frame)
        status = self.dev.read(1)
        if status == b"E":
            raise ProtocolError("FPGA replied 'E' (bad command or length)")
        if status != b"K":
            raise ProtocolError(f"no/invalid reply from FPGA: {status!r} (port, baud, reset?)")
        digest = self.dev.read(32)
        if len(digest) != 32:
            raise ProtocolError(f"short digest: {len(digest)} of 32 bytes")
        return digest

    def sha256(self, msg: bytes) -> bytes:
        return self._transact(string_frame(msg))

    def sha256d_header(self, header: bytes) -> bytes:
        return self._transact(header_frame(header))


def open_device(args):
    if args.fake:
        return FakeDevice()
    if not args.port:
        sys.exit("error: --port is required (or use --fake)")
    try:
        import serial
    except ImportError:
        sys.exit("error: pyserial is not installed (pip install pyserial)")
    return serial.Serial(args.port, args.baud, timeout=2)


def show(label: str, got: bytes, expected: bytes) -> bool:
    ok = got == expected
    print(f"{label:<28} {got.hex()}  {'OK' if ok else 'MISMATCH, expected ' + expected.hex()}")
    return ok


def cmd_string(fpga, text: str) -> bool:
    msg = text.encode("utf-8")
    return show(f"sha256({text!r})", fpga.sha256(msg), hashlib.sha256(msg).digest())


def cmd_header(fpga, header: bytes, name: str = "header") -> bool:
    got = fpga.sha256d_header(header)
    ok = show(f"sha256d({name})", got, hashlib.sha256(hashlib.sha256(header).digest()).digest())
    print(f"{'  block hash (display)':<28} {got[::-1].hex()}")
    return ok


def cmd_selftest(fpga, count: int) -> bool:
    ok = True
    for text in ["", "abc", "hello", "The quick brown fox jumps over the lazy dog 0123456789A"]:
        ok &= cmd_string(fpga, text)
    ok &= cmd_header(fpga, GENESIS_HEADER, "genesis")
    ok &= cmd_header(fpga, BLOCK_125552_HEADER, "block 125552")
    rng = random.Random(1)
    for i in range(count):
        msg = bytes(rng.randrange(256) for _ in range(rng.randrange(MAX_STRING_LEN + 1)))
        ok &= show(f"random string #{i} ({len(msg)} B)", fpga.sha256(msg), hashlib.sha256(msg).digest())
        hdr = bytes(rng.randrange(256) for _ in range(80))
        ok &= show(f"random header #{i}", fpga.sha256d_header(hdr),
                   hashlib.sha256(hashlib.sha256(hdr).digest()).digest())
    try:
        fpga._transact(b"X")
        print("bad command                  no error reply  MISMATCH")
        ok = False
    except ProtocolError:
        print("bad command                  'E'  OK")
    print("SELFTEST", "PASS" if ok else "FAIL")
    return ok


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", help="serial port, e.g. /dev/tty.usbserial-XXXX or COM5")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--fake", action="store_true", help="use a software model instead of a board")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("string", help="SHA-256 of a string (max 55 bytes UTF-8)")
    s.add_argument("text")
    h = sub.add_parser("header", help="double SHA-256 of an 80-byte header (160 hex chars, wire order)")
    h.add_argument("hex")
    sub.add_parser("genesis", help="double SHA-256 of the Bitcoin genesis header")
    t = sub.add_parser("selftest", help="known vectors + random inputs, all checked against hashlib")
    t.add_argument("--count", type=int, default=10)
    args = p.parse_args()

    fpga = Sha256Fpga(open_device(args))
    try:
        if args.cmd == "string":
            ok = cmd_string(fpga, args.text)
        elif args.cmd == "header":
            ok = cmd_header(fpga, bytes.fromhex(args.hex))
        elif args.cmd == "genesis":
            ok = cmd_header(fpga, GENESIS_HEADER, "genesis")
        else:
            ok = cmd_selftest(fpga, args.count)
    except (ProtocolError, ValueError) as exc:
        print("error:", exc, file=sys.stderr)
        return 1
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
