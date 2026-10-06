#!/usr/bin/env python3
"""Cross-check the testbench vectors against Python's hashlib.

The expected values live in the VHDL testbenches; this script parses them
so the vectors have a single source of truth. Exits non-zero on mismatch.
"""
import hashlib
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TB_SINGLE = ROOT / "tb" / "tb_sha256_single.vhd"
TB_DOUBLE = ROOT / "tb" / "tb_sha256_double.vhd"


def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def pad_single_block(msg: bytes) -> bytes:
    """FIPS 180-4 padding for a message that fits one 512-bit block."""
    assert len(msg) <= 55
    return msg + b"\x80" + b"\x00" * (55 - len(msg)) + struct.pack(">Q", 8 * len(msg))


def vhdl_string(expr: str) -> str:
    """Decode the string part of `"abc" & (4 to N => ' ')` or `(1 to N => ' ')`."""
    m = re.match(r'\s*"((?:[^"]|"")*)"', expr)
    return m.group(1).replace('""', '"') if m else ""


def check_single(text: str) -> int:
    pat = re.compile(
        r"input_string\s*=>\s*(?P<s>.*?),\s*"
        r"str_length\s*=>\s*(?P<n>\d+),\s*"
        r'expected_padded\s*=>\s*x"(?P<p>[0-9A-Fa-f]+)",\s*'
        r'expected_hash\s*=>\s*x"(?P<h>[0-9A-Fa-f]+)"',
        re.S,
    )
    errors = count = 0
    for m in pat.finditer(text):
        count += 1
        msg = vhdl_string(m["s"])[: int(m["n"])].encode("ascii")
        ok_pad = pad_single_block(msg).hex() == m["p"].lower()
        ok_hash = sha256(msg).hex() == m["h"].lower()
        print(f"  single {msg.decode()!r:<60} padding={'ok' if ok_pad else 'MISMATCH'} hash={'ok' if ok_hash else 'MISMATCH'}")
        errors += (not ok_pad) + (not ok_hash)
    return errors if count else 1


def check_double(text: str) -> int:
    pat = re.compile(
        r'block_header\s*=>\s*x"(?P<b>[0-9A-Fa-f]+)",\s*'
        r'expected_first\s*=>\s*x"(?P<f>[0-9A-Fa-f]+)",\s*'
        r'expected_final\s*=>\s*x"(?P<h>[0-9A-Fa-f]+)"',
        re.S,
    )
    errors = count = 0
    for m in pat.finditer(text):
        count += 1
        header = bytes.fromhex(m["b"])
        first = sha256(header)
        final = sha256(first)
        ok = len(header) == 80 and first.hex() == m["f"].lower() and final.hex() == m["h"].lower()
        print(f"  double {header[:6].hex()}... first/final={'ok' if ok else 'MISMATCH'}  display={final[::-1].hex()}")
        errors += not ok
    return errors if count else 1


def main() -> int:
    errors = check_single(TB_SINGLE.read_text()) + check_double(TB_DOUBLE.read_text())
    print("python cross-check:", "PASS" if errors == 0 else f"FAIL ({errors})")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
