#!/usr/bin/env python3
"""Compare RTL result hex with golden dense C hex."""
from __future__ import annotations

import argparse
from pathlib import Path

from fp16_utils import fp16_bits_to_float, read_hex_words, write_json


def main() -> None:
    parser = argparse.ArgumentParser(description="Check RTL result against golden C hex.")
    parser.add_argument("--golden", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--mode", choices=["bit", "float"], default="bit")
    parser.add_argument("--atol", type=float, default=0.0)
    args = parser.parse_args()

    golden = read_hex_words(args.golden)
    result = read_hex_words(args.result)
    total = max(len(golden), len(result))
    mismatch = []
    max_abs_error = 0.0

    for i in range(total):
        g = golden[i] if i < len(golden) else None
        r = result[i] if i < len(result) else None
        ok = False
        abs_err = None
        if g is not None and r is not None:
            if args.mode == "bit":
                ok = ((g & 0xFFFF) == (r & 0xFFFF))
                abs_err = abs(fp16_bits_to_float(g) - fp16_bits_to_float(r))
            else:
                abs_err = abs(fp16_bits_to_float(g) - fp16_bits_to_float(r))
                ok = abs_err <= args.atol
            max_abs_error = max(max_abs_error, abs_err)
        if not ok:
            mismatch.append({
                "index": i,
                "golden_hex": None if g is None else f"{g & 0xFFFF:04X}",
                "result_hex": None if r is None else f"{r & 0xFFFF:04X}",
                "golden_float": None if g is None else fp16_bits_to_float(g),
                "result_float": None if r is None else fp16_bits_to_float(r),
                "abs_error": abs_err,
            })
            if len(mismatch) >= 32:
                # Keep report compact.
                break

    report = {
        "pass": len(mismatch) == 0 and len(golden) == len(result),
        "mode": args.mode,
        "golden_len": len(golden),
        "result_len": len(result),
        "total_checked": total,
        "mismatch_count_first_32": len(mismatch),
        "max_abs_error": max_abs_error,
        "first_mismatches": mismatch,
    }
    write_json(args.out, report)
    print(f"[CHECK] pass={report['pass']} result={args.out}")
    if not report["pass"] and mismatch:
        print(f"[CHECK] first mismatch: {mismatch[0]}")


if __name__ == "__main__":
    main()
