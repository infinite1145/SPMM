#!/usr/bin/env python3
"""Generate sparse-matrix testcases for pe_framework.

Generated testcase layout:
  testcases/<case>/
    config.json
    meta.json
    a_original_dense.hex
    a_dense.hex              # after optional row reorder
    b_dense.hex
    a_csr_row_ptr.hex
    a_csr_entry.hex
    b_csr_row_ptr.hex
    b_csr_entry.hex
    a_csv.hex                # 32-bit words, vector-major CSV-like
    a_csv_vectors.json
    golden_c.hex             # dense C, FP16 row-major
    golden_c_float.txt
"""
from __future__ import annotations

import argparse
import random
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

from fp16_utils import (
    dense_to_csr,
    ensure_dir,
    float_to_fp16_bits,
    int_to_hex,
    matmul_dense,
    matrix_stats,
    pack_idx_val,
    write_dense_fp16_matrix,
    write_hex_words,
    write_json,
)
from reorder import apply_row_permutation, estimate_csv_metrics, greedy_row_reorder


VALUE_TABLE = [-4.0, -3.0, -2.0, -1.5, -1.0, -0.5, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0]


def random_value(rng: random.Random) -> float:
    return rng.choice(VALUE_TABLE)


def gen_a_matrix(M: int, K: int, sparsity: float, rng: random.Random) -> List[List[float]]:
    max_row_nnz = max(1, int(K * sparsity)) if K > 0 else 0
    A = [[0.0 for _ in range(K)] for _ in range(M)]
    for i in range(M):
        # Randomize around target density while respecting max row density.
        target = max(0, min(max_row_nnz, int(round(K * sparsity))))
        lo = 0 if target == 0 else max(0, target - max(1, target // 2))
        hi = max_row_nnz
        count = rng.randint(lo, hi) if hi >= lo else 0
        cols = rng.sample(range(K), count) if count else []
        for k in cols:
            A[i][k] = random_value(rng)
    return A


def gen_b_matrix(K: int, N: int, sparsity: float, rng: random.Random) -> List[List[float]]:
    """Generate B as KxN, limiting column nnz roughly by sparsity*K."""
    max_col_nnz = max(1, int(K * sparsity)) if K > 0 else 0
    B = [[0.0 for _ in range(N)] for _ in range(K)]
    for j in range(N):
        target = max(0, min(max_col_nnz, int(round(K * sparsity))))
        lo = 0 if target == 0 else max(0, target - max(1, target // 2))
        hi = max_col_nnz
        count = rng.randint(lo, hi) if hi >= lo else 0
        rows = rng.sample(range(K), count) if count else []
        for k in rows:
            B[k][j] = random_value(rng)
    return B


def build_csv_vectors(A: Sequence[Sequence[float]], pe_lanes: int) -> List[dict]:
    """Build simple vector-major CSV-like vectors from row groups.

    Each vector is encoded as:
      word0 = {row_base[15:0], k[15:0]}
      word1 = {eor_mask[15:0], valid_mask[15:0]}
      word2..word(2+P-1) = {16'h0, a_val[p][15:0]}
    """
    M = len(A)
    K = len(A[0]) if M else 0
    vectors: List[dict] = []

    # Precompute row nonzero columns and last column for eor.
    row_cols: List[List[int]] = []
    for row in A:
        cols = [k for k, v in enumerate(row) if float(v) != 0.0]
        row_cols.append(cols)

    for row_base in range(0, M, pe_lanes):
        rows = list(range(row_base, min(row_base + pe_lanes, M)))
        union_cols = sorted(set().union(*(set(row_cols[r]) for r in rows))) if rows else []
        for k in union_cols:
            valid_mask = 0
            eor_mask = 0
            a_vals_bits = [0 for _ in range(pe_lanes)]
            lane_info = []
            for p in range(pe_lanes):
                row = row_base + p
                if row >= M:
                    lane_info.append(None)
                    continue
                val = float(A[row][k]) if k < K else 0.0
                if val != 0.0:
                    valid_mask |= (1 << p)
                    a_vals_bits[p] = float_to_fp16_bits(val)
                    is_eor = (row_cols[row] and k == row_cols[row][-1])
                    if is_eor:
                        eor_mask |= (1 << p)
                    lane_info.append({"row": row, "k": k, "value": val, "eor": bool(is_eor)})
                else:
                    lane_info.append(None)
            if valid_mask == 0:
                continue
            vectors.append({
                "row_base": row_base,
                "k": k,
                "valid_mask": valid_mask,
                "eor_mask": eor_mask,
                "a_vals_bits": a_vals_bits,
                "lanes": lane_info,
            })
    return vectors


def encode_csv_vectors(vectors: Sequence[dict], pe_lanes: int) -> List[int]:
    words: List[int] = []
    for vec in vectors:
        row_base = int(vec["row_base"])
        k = int(vec["k"])
        valid_mask = int(vec["valid_mask"])
        eor_mask = int(vec["eor_mask"])
        words.append(((row_base & 0xFFFF) << 16) | (k & 0xFFFF))
        words.append(((eor_mask & 0xFFFF) << 16) | (valid_mask & 0xFFFF))
        vals = list(vec["a_vals_bits"])
        for p in range(pe_lanes):
            words.append(vals[p] & 0xFFFF)
    return words


def write_float_text(path: Path, mat: Sequence[Sequence[float]]) -> None:
    ensure_dir(path.parent)
    with open(path, "w", encoding="utf-8") as f:
        for row in mat:
            f.write(" ".join(f"{float(v): .8g}" for v in row) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate sparse matrix testcase for PE framework.")
    parser.add_argument("--out_dir", type=Path, default=Path("testcases"))
    parser.add_argument("--case", type=str, default="default")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--M", type=int, default=16)
    parser.add_argument("--N", type=int, default=16)
    parser.add_argument("--K", type=int, default=16)
    parser.add_argument("--sparsity", type=float, default=0.3)
    parser.add_argument("--pe_lanes", type=int, default=4)
    parser.add_argument("--reorder", choices=["none", "greedy"], default="greedy")
    args = parser.parse_args()

    rng = random.Random(args.seed)
    case_dir = ensure_dir(args.out_dir / args.case)

    A_original = gen_a_matrix(args.M, args.K, args.sparsity, rng)
    B = gen_b_matrix(args.K, args.N, args.sparsity, rng)

    before_csv = estimate_csv_metrics(A_original, args.pe_lanes)
    row_perm = list(range(args.M))
    A = A_original
    if args.reorder == "greedy":
        row_perm = greedy_row_reorder(A_original)
        A = apply_row_permutation(A_original, row_perm)
    after_csv = estimate_csv_metrics(A, args.pe_lanes)

    C = matmul_dense(A, B)

    # Dense matrices.
    write_dense_fp16_matrix(case_dir / "a_original_dense.hex", A_original)
    write_dense_fp16_matrix(case_dir / "a_dense.hex", A)
    write_dense_fp16_matrix(case_dir / "b_dense.hex", B)
    write_dense_fp16_matrix(case_dir / "golden_c.hex", C)
    write_float_text(case_dir / "golden_c_float.txt", C)

    # CSR files.
    a_row_ptr, a_entries = dense_to_csr(A)
    b_row_ptr, b_entries = dense_to_csr(B)
    write_hex_words(case_dir / "a_csr_row_ptr.hex", a_row_ptr, width=32)
    write_hex_words(case_dir / "a_csr_entry.hex", a_entries, width=32)
    write_hex_words(case_dir / "b_csr_row_ptr.hex", b_row_ptr, width=32)
    write_hex_words(case_dir / "b_csr_entry.hex", b_entries, width=32)

    # CSV-like files.
    csv_vectors = build_csv_vectors(A, args.pe_lanes)
    csv_words = encode_csv_vectors(csv_vectors, args.pe_lanes)
    write_hex_words(case_dir / "a_csv.hex", csv_words, width=32)
    # JSON version is useful for human inspection/debug.
    json_vectors = []
    for v in csv_vectors:
        json_vectors.append({
            "row_base": v["row_base"],
            "k": v["k"],
            "valid_mask_hex": int_to_hex(v["valid_mask"], 16),
            "eor_mask_hex": int_to_hex(v["eor_mask"], 16),
            "lanes": v["lanes"],
        })
    write_json(case_dir / "a_csv_vectors.json", {"vectors": json_vectors})

    cfg = {
        "case": args.case,
        "seed": args.seed,
        "M": args.M,
        "N": args.N,
        "K": args.K,
        "sparsity": args.sparsity,
        "pe_lanes": args.pe_lanes,
        "reorder": args.reorder,
        "data_width": 16,
        "idx_width": 16,
        "word_width": 32,
        "csv_words_per_vector": 2 + args.pe_lanes,
        "csv_vector_count": len(csv_vectors),
        "a_nnz": len(a_entries),
        "b_nnz": len(b_entries),
        "files": {
            "a_csv": "a_csv.hex",
            "a_dense": "a_dense.hex",
            "b_dense": "b_dense.hex",
            "b_csr_row_ptr": "b_csr_row_ptr.hex",
            "b_csr_entry": "b_csr_entry.hex",
            "golden_c": "golden_c.hex",
        },
    }
    write_json(case_dir / "config.json", cfg)
    write_json(case_dir / "a_row_perm.json", {"perm": row_perm})
    meta = {
        "a_original_stats": matrix_stats(A_original),
        "a_stats": matrix_stats(A),
        "b_stats": matrix_stats(B),
        "c_stats": matrix_stats(C),
        "csv_metrics_before_reorder": before_csv,
        "csv_metrics_after_reorder": after_csv,
    }
    write_json(case_dir / "meta.json", meta)

    print(f"[GEN] testcase: {args.case}")
    print(f"[GEN] output   : {case_dir}")
    print(f"[GEN] A nnz={len(a_entries)}, B nnz={len(b_entries)}, CSV vectors={len(csv_vectors)}")
    print(f"[GEN] CSV util before={before_csv['lane_utilization']:.4f}, after={after_csv['lane_utilization']:.4f}")


if __name__ == "__main__":
    main()
