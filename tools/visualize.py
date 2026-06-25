#!/usr/bin/env python3
"""Visualize dense matrix hex files as value heatmaps, nonzero maps, or mismatch maps."""
from __future__ import annotations

import argparse
from pathlib import Path
from typing import List, Optional

from fp16_utils import ensure_dir, read_dense_hex_matrix, read_json


def infer_shape(config: dict, matrix: str) -> tuple[int, int]:
    matrix = matrix.upper()
    if matrix == "A":
        return int(config["M"]), int(config["K"])
    if matrix == "B":
        return int(config["K"]), int(config["N"])
    if matrix == "C":
        return int(config["M"]), int(config["N"])
    raise ValueError("matrix must be A, B, or C")


def to_binary_nonzero(mat: List[List[float]]) -> List[List[float]]:
    return [[1.0 if float(v) != 0.0 else 0.0 for v in row] for row in mat]


def abs_diff(a: List[List[float]], b: List[List[float]]) -> List[List[float]]:
    rows = len(a)
    cols = len(a[0]) if rows else 0
    return [[abs(float(a[r][c]) - float(b[r][c])) for c in range(cols)] for r in range(rows)]


def max_abs(mat: List[List[float]]) -> float:
    ans = 0.0
    for row in mat:
        for v in row:
            ans = max(ans, abs(float(v)))
    return ans


def should_annotate(rows: int, cols: int, annotate_arg: str) -> bool:
    if annotate_arg == "on":
        return True
    if annotate_arg == "off":
        return False
    return rows <= 24 and cols <= 24


def format_cell_value(v: float, mode: str) -> str:
    v = float(v)
    if mode == "nonzero":
        return "1" if v != 0.0 else "0"
    if v == 0.0:
        return "0"
    abs_v = abs(v)
    if abs_v >= 100:
        return f"{v:.0f}"
    if abs_v >= 10:
        return f"{v:.1f}"
    if abs_v >= 1:
        return f"{v:.2f}"
    return f"{v:.3g}"


def default_output_path(
    out_dir: Path,
    case: str,
    matrix: str,
    mode: str,
    input_path: Optional[Path],
    result_path: Optional[Path],
) -> Path:
    case_dir = out_dir / case
    if mode == "diff":
        stem = result_path.stem if result_path is not None else "result"
        return case_dir / f"{matrix.upper()}_diff_{stem}.png"

    stem = input_path.stem if input_path is not None else "matrix"
    return case_dir / f"{matrix.upper()}_{mode}_{stem}.png"


def plot_matrix(
    mat: List[List[float]],
    out: Path,
    title: str,
    mode: str,
    annotate: bool,
) -> None:
    try:
        import matplotlib.pyplot as plt
        import matplotlib.colors as colors
    except ImportError as exc:
        raise SystemExit(
            "matplotlib is required for visualize.py. "
            "Install it with: python3 -m pip install -r requirements.txt"
        ) from exc

    ensure_dir(out.parent)

    rows = len(mat)
    cols = len(mat[0]) if rows else 0

    if rows == 0 or cols == 0:
        raise ValueError("Cannot visualize an empty matrix")

    fig_w = max(6.0, min(18.0, cols * 0.55 if annotate else cols * 0.25))
    fig_h = max(5.0, min(18.0, rows * 0.55 if annotate else rows * 0.25))

    plt.figure(figsize=(fig_w, fig_h))

    if mode == "nonzero":
        data = to_binary_nonzero(mat)
        im = plt.imshow(data, aspect="auto", interpolation="nearest", vmin=0, vmax=1)
        plt.colorbar(im, label="nonzero")
        display_data = data
    else:
        data = [[float(v) for v in row] for row in mat]
        max_v = max_abs(data)

        if mode in ("value", "diff") and max_v > 0:
            has_pos = any(float(v) > 0 for row in data for v in row)
            has_neg = any(float(v) < 0 for row in data for v in row)

            if has_pos and has_neg:
                norm = colors.TwoSlopeNorm(vmin=-max_v, vcenter=0.0, vmax=max_v)
                im = plt.imshow(data, aspect="auto", interpolation="nearest", norm=norm)
            else:
                im = plt.imshow(data, aspect="auto", interpolation="nearest")
        else:
            im = plt.imshow(data, aspect="auto", interpolation="nearest")

        label = "absolute error" if mode == "diff" else "value"
        plt.colorbar(im, label=label)
        display_data = data

    if annotate:
        for r in range(rows):
            for c in range(cols):
                txt = format_cell_value(display_data[r][c], mode)
                plt.text(
                    c,
                    r,
                    txt,
                    ha="center",
                    va="center",
                    fontsize=7,
                    color="black",
                )

    plt.title(title)
    plt.xlabel("col")
    plt.ylabel("row")
    plt.xticks(range(cols) if cols <= 32 else [])
    plt.yticks(range(rows) if rows <= 32 else [])
    plt.tight_layout()
    plt.savefig(out, dpi=180)
    plt.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Visualize dense matrix hex files.")
    parser.add_argument("--case", type=str, default="default", help="Case name, used for output subdirectory")
    parser.add_argument("--input", type=Path, help="Input dense matrix hex file")
    parser.add_argument("--golden", type=Path, help="Golden dense matrix hex file")
    parser.add_argument("--result", type=Path, help="RTL result dense matrix hex file")
    parser.add_argument("--config", type=Path, help="config.json to infer matrix shape")
    parser.add_argument("--matrix", choices=["A", "B", "C"], default="C")
    parser.add_argument("--rows", type=int)
    parser.add_argument("--cols", type=int)
    parser.add_argument("--mode", choices=["value", "nonzero", "diff"], default="value")
    parser.add_argument("--out", type=Path, default=None, help="Output image path")
    parser.add_argument("--out_dir", type=Path, default=Path("visual_result"), help="Output root directory")
    parser.add_argument("--title", type=str, default=None)
    parser.add_argument(
        "--annotate",
        choices=["auto", "on", "off"],
        default="auto",
        help="Show numeric value in each cell. auto enables it for small matrices.",
    )
    args = parser.parse_args()

    if args.config:
        cfg = read_json(args.config)
        rows, cols = infer_shape(cfg, args.matrix)
    else:
        if args.rows is None or args.cols is None:
            parser.error("Provide either --config or --rows/--cols")
        rows, cols = args.rows, args.cols

    annotate = should_annotate(rows, cols, args.annotate)

    if args.out is None:
        args.out = default_output_path(
            out_dir=args.out_dir,
            case=args.case,
            matrix=args.matrix,
            mode=args.mode,
            input_path=args.input,
            result_path=args.result,
        )

    if args.mode == "diff":
        if not args.golden or not args.result:
            parser.error("--mode diff requires --golden and --result")

        golden = read_dense_hex_matrix(args.golden, rows, cols, dtype="fp16")
        result = read_dense_hex_matrix(args.result, rows, cols, dtype="fp16")
        mat = abs_diff(golden, result)

        title = args.title or f"{args.case}: abs diff ({args.result.name} vs {args.golden.name})"
        plot_matrix(mat, args.out, title=title, mode="diff", annotate=annotate)

    else:
        if not args.input:
            parser.error("--input is required unless --mode diff")

        mat = read_dense_hex_matrix(args.input, rows, cols, dtype="fp16")
        title = args.title or f"{args.case}: {args.matrix.upper()} {args.mode} ({args.input.name})"
        plot_matrix(mat, args.out, title=title, mode=args.mode, annotate=annotate)

    print(f"[VIS] wrote {args.out}")


if __name__ == "__main__":
    main()