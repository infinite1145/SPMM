#!/usr/bin/env python3
"""Row reordering utility for CSV-like sparse matrix scheduling.

The heuristic follows the FSpGEMM-style idea: rows sharing more nonzero
column indices should be placed close to each other, so CSV vectors formed from
neighboring rows can contain more valid lanes and reuse the same B row more.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Sequence, Set, Tuple

from fp16_utils import (
    ensure_dir,
    matrix_stats,
    read_dense_hex_matrix,
    read_json,
    write_dense_fp16_matrix,
    write_json,
)


def row_patterns(mat: Sequence[Sequence[float]], zero_eps: float = 0.0) -> List[Set[int]]:
    return [set(c for c, v in enumerate(row) if abs(float(v)) > zero_eps) for row in mat]


def build_similarity_graph(patterns: Sequence[Set[int]]) -> List[Dict[int, int]]:
    """Build weighted row graph: weight(i,j)=|S_i intersect S_j|."""
    col_to_rows: Dict[int, List[int]] = defaultdict(list)
    for r, cols in enumerate(patterns):
        for c in cols:
            col_to_rows[c].append(r)

    graph: List[Dict[int, int]] = [defaultdict(int) for _ in patterns]
    for rows in col_to_rows.values():
        # Add one similarity count for each shared column.
        for a_idx in range(len(rows)):
            a = rows[a_idx]
            for b in rows[a_idx + 1 :]:
                graph[a][b] += 1
                graph[b][a] += 1
    return [dict(g) for g in graph]


def greedy_row_reorder(mat: Sequence[Sequence[float]], zero_eps: float = 0.0) -> List[int]:
    """Return a row permutation using greedy maximum-similarity traversal."""
    patterns = row_patterns(mat, zero_eps=zero_eps)
    graph = build_similarity_graph(patterns)
    n = len(patterns)
    if n == 0:
        return []

    nnz = [len(p) for p in patterns]
    unvisited = set(range(n))
    order: List[int] = []

    # Start from the row with the highest number of nonzeros.
    cur = max(unvisited, key=lambda r: (nnz[r], -r))

    while unvisited:
        order.append(cur)
        unvisited.remove(cur)
        if not unvisited:
            break

        neighbors = [(v, w) for v, w in graph[cur].items() if v in unvisited]
        if neighbors:
            # Prefer highest similarity, then denser rows, then smaller index.
            cur = max(neighbors, key=lambda item: (item[1], nnz[item[0]], -item[0]))[0]
        else:
            # Start a new component.
            cur = max(unvisited, key=lambda r: (nnz[r], -r))

    return order


def apply_row_permutation(mat: Sequence[Sequence[float]], perm: Sequence[int]) -> List[List[float]]:
    return [list(mat[i]) for i in perm]


def estimate_csv_metrics(mat: Sequence[Sequence[float]], pe_lanes: int, zero_eps: float = 0.0) -> dict:
    """Estimate vector-major CSV utilization for consecutive row groups."""
    patterns = row_patterns(mat, zero_eps=zero_eps)
    vector_count = 0
    valid_count = 0
    block_count = 0
    block_utils: List[float] = []

    for base in range(0, len(patterns), pe_lanes):
        block = patterns[base : base + pe_lanes]
        if not block:
            continue
        union_cols = sorted(set().union(*block)) if block else []
        if not union_cols:
            block_count += 1
            block_utils.append(0.0)
            continue
        block_count += 1
        block_vectors = len(union_cols)
        block_valid = 0
        for c in union_cols:
            block_valid += sum(1 for pat in block if c in pat)
        vector_count += block_vectors
        valid_count += block_valid
        block_utils.append(block_valid / (block_vectors * pe_lanes))

    max_slots = vector_count * pe_lanes
    nnz = sum(len(p) for p in patterns)
    return {
        "pe_lanes": pe_lanes,
        "row_blocks": block_count,
        "csv_vector_count": vector_count,
        "valid_lane_count": valid_count,
        "nnz": nnz,
        "lane_utilization": (valid_count / max_slots) if max_slots else 0.0,
        "b_row_read_reduction": (1.0 - vector_count / nnz) if nnz else 0.0,
        "block_utilization_avg": (sum(block_utils) / len(block_utils)) if block_utils else 0.0,
    }


def run_case_dir(case_dir: Path, pe_lanes: int, output_dir: Path | None = None) -> None:
    cfg = read_json(case_dir / "config.json")
    M = int(cfg["M"])
    K = int(cfg["K"])
    a_path = case_dir / "a_original_dense.hex"
    if not a_path.exists():
        a_path = case_dir / "a_dense.hex"
    A = read_dense_hex_matrix(a_path, M, K, dtype="fp16")
    perm = greedy_row_reorder(A)
    A_reordered = apply_row_permutation(A, perm)

    out = output_dir or case_dir
    ensure_dir(out)
    write_json(out / "a_row_perm.json", {"perm": list(perm)})
    write_dense_fp16_matrix(out / "a_reordered_dense.hex", A_reordered)
    report = {
        "before": estimate_csv_metrics(A, pe_lanes),
        "after": estimate_csv_metrics(A_reordered, pe_lanes),
        "a_stats_before": matrix_stats(A),
        "a_stats_after": matrix_stats(A_reordered),
    }
    write_json(out / "reorder_report.json", report)
    print(f"[REORDER] case_dir={case_dir}")
    print(f"[REORDER] wrote {out / 'a_row_perm.json'}")
    print(f"[REORDER] util before={report['before']['lane_utilization']:.4f}, after={report['after']['lane_utilization']:.4f}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Reorder A rows to improve CSV vector utilization.")
    parser.add_argument("--case_dir", type=Path, help="Existing testcase directory containing config.json and A dense hex.")
    parser.add_argument("--input_hex", type=Path, help="Input dense A hex file, row-major FP16.")
    parser.add_argument("--rows", type=int, help="Number of rows for --input_hex.")
    parser.add_argument("--cols", type=int, help="Number of columns for --input_hex.")
    parser.add_argument("--pe_lanes", type=int, default=4)
    parser.add_argument("--out_dir", type=Path, default=None)
    args = parser.parse_args()

    if args.case_dir:
        run_case_dir(args.case_dir, args.pe_lanes, args.out_dir)
        return

    if not (args.input_hex and args.rows and args.cols):
        parser.error("Use either --case_dir or --input_hex with --rows and --cols")

    A = read_dense_hex_matrix(args.input_hex, args.rows, args.cols, dtype="fp16")
    perm = greedy_row_reorder(A)
    A_reordered = apply_row_permutation(A, perm)
    out = args.out_dir or args.input_hex.parent
    ensure_dir(out)
    write_json(out / "a_row_perm.json", {"perm": list(perm)})
    write_dense_fp16_matrix(out / "a_reordered_dense.hex", A_reordered)
    report = {
        "before": estimate_csv_metrics(A, args.pe_lanes),
        "after": estimate_csv_metrics(A_reordered, args.pe_lanes),
    }
    write_json(out / "reorder_report.json", report)
    print(f"[REORDER] util before={report['before']['lane_utilization']:.4f}, after={report['after']['lane_utilization']:.4f}")


if __name__ == "__main__":
    main()
