#!/usr/bin/env python3
"""Generate sparse-matrix testcases for pe_framework.

Generated testcase layout:
  testcases/<case>/
    config.json
    meta.json

    a_original_dense.hex       # original A, dense row-major
    a_dense.hex                # reordered A, dense row-major
    b_dense.hex                # B, dense row-major

    a_csr_row_ptr.hex
    a_csr_entry.hex
    b_csr_row_ptr.hex
    b_csr_entry.hex

    a_csv.hex                  # CSV word stream, one 32-bit word per line
    a_csv_vec.hex              # vector-wide CSV, one full vector per line
    a_csv_vectors.json

    golden_c.hex               # C = A_original @ B, original row order
    golden_c_reordered.hex     # C = A_reordered @ B, physical reordered row order
    golden_c_float.txt

CSV vector format, scalable for PE_LANES > 16:

  MASK_WORDS = ceil(PE_LANES / 32)
  CSV_WORDS_PER_VECTOR = 1 + 2 * MASK_WORDS + PE_LANES

  word0:
      {row_base[15:0], k[15:0]}

  word1 ... word(MASK_WORDS):
      valid_mask words, low lane first
      valid_mask_words[0][0]  -> lane0
      valid_mask_words[0][31] -> lane31
      valid_mask_words[1][0]  -> lane32
      ...

  next MASK_WORDS words:
      eor_mask words, low lane first

  final PE_LANES words:
      lane_word[p] = {row_idx[15:0], a_val_fp16[15:0]} when csv_has_row_idx=1
      lane_word[p] = {16'h0,        a_val_fp16[15:0]} when csv_has_row_idx=0
"""
from __future__ import annotations

import argparse
import random
from pathlib import Path
from typing import List, Sequence

from fp16_utils import (
    dense_to_csr,
    ensure_dir,
    float_to_fp16_bits,
    int_to_hex,
    matmul_dense,
    matrix_stats,
    write_dense_fp16_matrix,
    write_hex_words,
    write_json,
)
from reorder import apply_row_permutation, estimate_csv_metrics, greedy_row_reorder


VALUE_TABLE = [
    -4.0, -3.0, -2.0, -1.5, -1.0, -0.5,
     0.5,  1.0,  1.5,  2.0,  3.0,  4.0,
]


def mask_word_count(pe_lanes: int) -> int:
    """Number of 32-bit words required to store one PE-lane mask."""
    if pe_lanes <= 0:
        raise ValueError("pe_lanes must be positive")
    return (pe_lanes + 31) // 32


def csv_words_per_vector(pe_lanes: int) -> int:
    """Scalable CSV vector length in 32-bit words."""
    mw = mask_word_count(pe_lanes)
    return 1 + 2 * mw + pe_lanes


def split_mask_to_words(mask: int, pe_lanes: int) -> List[int]:
    """Split a lane mask into 32-bit little-lane-order words."""
    mw = mask_word_count(pe_lanes)
    return [(int(mask) >> (32 * i)) & 0xFFFFFFFF for i in range(mw)]


def random_value(
    rng: random.Random,
    value_mode: str,
    value_min: float,
    value_max: float,
    value_step: float,
) -> float:
    if value_mode == "table":
        return rng.choice(VALUE_TABLE)

    if value_mode == "uniform":
        return rng.uniform(value_min, value_max)

    if value_mode == "quantized":
        if value_step <= 0:
            raise ValueError("--value_step must be positive when --value_mode quantized")
        lo = int(round(value_min / value_step))
        hi = int(round(value_max / value_step))
        if lo > hi:
            lo, hi = hi, lo
        val = rng.randint(lo, hi) * value_step
        if val == 0.0:
            val = value_step
        return float(val)

    raise ValueError(f"Unknown value_mode: {value_mode}")


def gen_a_matrix(
    M: int,
    K: int,
    sparsity: float,
    rng: random.Random,
    value_mode: str,
    value_min: float,
    value_max: float,
    value_step: float,
) -> List[List[float]]:
    max_row_nnz = max(1, int(K * sparsity)) if K > 0 else 0
    A = [[0.0 for _ in range(K)] for _ in range(M)]

    for i in range(M):
        target = max(0, min(max_row_nnz, int(round(K * sparsity))))
        lo = 0 if target == 0 else max(0, target - max(1, target // 2))
        hi = max_row_nnz
        count = rng.randint(lo, hi) if hi >= lo else 0
        cols = rng.sample(range(K), count) if count else []

        for k in cols:
            A[i][k] = random_value(rng, value_mode, value_min, value_max, value_step)

    return A


def gen_b_matrix(
    K: int,
    N: int,
    sparsity: float,
    rng: random.Random,
    value_mode: str,
    value_min: float,
    value_max: float,
    value_step: float,
) -> List[List[float]]:
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
            B[k][j] = random_value(rng, value_mode, value_min, value_max, value_step)

    return B


def build_csv_vectors(
    A: Sequence[Sequence[float]],
    pe_lanes: int,
    logical_row_ids: Sequence[int],
    csv_has_row_idx: bool,
) -> List[dict]:
    """Build vector-major CSV-like vectors from row groups.

    The masks are stored internally as Python integers and are later split
    into 32-bit words by encode_csv_vectors_word_stream().
    """
    M = len(A)
    K = len(A[0]) if M else 0

    if len(logical_row_ids) != M:
        raise ValueError("logical_row_ids length must match number of A rows")

    vectors: List[dict] = []

    row_cols: List[List[int]] = []
    for row in A:
        cols = [k for k, v in enumerate(row) if float(v) != 0.0]
        row_cols.append(cols)

    for row_base in range(0, M, pe_lanes):
        physical_rows = list(range(row_base, min(row_base + pe_lanes, M)))
        union_cols = sorted(set().union(*(set(row_cols[r]) for r in physical_rows))) if physical_rows else []

        for k in union_cols:
            valid_mask = 0
            eor_mask = 0

            a_vals_bits = [0 for _ in range(pe_lanes)]
            row_idx_bits = [0 for _ in range(pe_lanes)]
            lane_info = []

            for p in range(pe_lanes):
                physical_row = row_base + p

                if physical_row >= M:
                    lane_info.append(None)
                    continue

                logical_row = int(logical_row_ids[physical_row])
                row_idx_bits[p] = logical_row & 0xFFFF

                val = float(A[physical_row][k]) if k < K else 0.0

                if val != 0.0:
                    valid_mask |= (1 << p)
                    a_vals_bits[p] = float_to_fp16_bits(val)

                    is_eor = bool(row_cols[physical_row] and k == row_cols[physical_row][-1])
                    if is_eor:
                        eor_mask |= (1 << p)

                    lane_info.append({
                        "lane": p,
                        "physical_row": physical_row,
                        "logical_row": logical_row,
                        "k": k,
                        "value": val,
                        "fp16_hex": int_to_hex(a_vals_bits[p], 16),
                        "eor": bool(is_eor),
                    })
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
                "row_idx_bits": row_idx_bits,
                "csv_has_row_idx": bool(csv_has_row_idx),
                "lanes": lane_info,
            })

    return vectors


def encode_csv_vectors_word_stream(
    vectors: Sequence[dict],
    pe_lanes: int,
    csv_has_row_idx: bool,
) -> List[int]:
    """Encode CSV vectors as a 32-bit word stream.

    New scalable format:

      word0 = {row_base[15:0], k[15:0]}

      next MASK_WORDS words:
          valid_mask[31:0], valid_mask[63:32], ...

      next MASK_WORDS words:
          eor_mask[31:0], eor_mask[63:32], ...

      next PE_LANES words:
          lane_word[p] = {row_idx[15:0], a_val[p][15:0]} when csv_has_row_idx=1
                         {16'h0,        a_val[p][15:0]} when csv_has_row_idx=0
    """
    words: List[int] = []
    mw = mask_word_count(pe_lanes)

    for vec in vectors:
        row_base = int(vec["row_base"])
        k = int(vec["k"])
        valid_mask = int(vec["valid_mask"])
        eor_mask = int(vec["eor_mask"])

        valid_words = split_mask_to_words(valid_mask, pe_lanes)
        eor_words = split_mask_to_words(eor_mask, pe_lanes)

        if len(valid_words) != mw or len(eor_words) != mw:
            raise RuntimeError("mask word split produced unexpected length")

        words.append(((row_base & 0xFFFF) << 16) | (k & 0xFFFF))

        for w in valid_words:
            words.append(w & 0xFFFFFFFF)

        for w in eor_words:
            words.append(w & 0xFFFFFFFF)

        vals = list(vec["a_vals_bits"])
        rows = list(vec["row_idx_bits"])

        for p in range(pe_lanes):
            high = rows[p] if csv_has_row_idx else 0
            low = vals[p] & 0xFFFF
            words.append(((high & 0xFFFF) << 16) | low)

    return words


def pack_csv_words_to_vector_words(csv_words: Sequence[int], pe_lanes: int) -> List[int]:
    """Pack 32-bit CSV word stream into vector-wide words.

    For one vector:
      packed[31:0]      = word0
      packed[63:32]     = word1
      packed[95:64]     = word2
      ...
      packed[32*i+31:32*i] = word_i

    In the hex file, this appears as:
      word_last ... word2 word1 word0
    because hex text writes high bits first.
    """
    words_per_vector = csv_words_per_vector(pe_lanes)

    if len(csv_words) % words_per_vector != 0:
        raise ValueError(
            f"CSV word count {len(csv_words)} is not divisible by "
            f"words_per_vector={words_per_vector}"
        )

    vector_words: List[int] = []

    for base in range(0, len(csv_words), words_per_vector):
        packed = 0

        for i in range(words_per_vector):
            word = int(csv_words[base + i]) & 0xFFFFFFFF
            packed |= word << (32 * i)

        vector_words.append(packed)

    return vector_words


def verify_csv_pack(csv_words: Sequence[int], csv_vec_words: Sequence[int], pe_lanes: int) -> None:
    """Check that a_csv_vec.hex is exactly the packed form of a_csv.hex."""
    words_per_vector = csv_words_per_vector(pe_lanes)

    if len(csv_words) != len(csv_vec_words) * words_per_vector:
        raise RuntimeError(
            f"CSV pack count mismatch: len(csv_words)={len(csv_words)}, "
            f"len(csv_vec_words)={len(csv_vec_words)}, "
            f"words_per_vector={words_per_vector}"
        )

    for i, packed in enumerate(csv_vec_words):
        for j in range(words_per_vector):
            unpacked = (int(packed) >> (32 * j)) & 0xFFFFFFFF
            expected = int(csv_words[i * words_per_vector + j]) & 0xFFFFFFFF

            if unpacked != expected:
                raise RuntimeError(
                    f"CSV pack mismatch at vector={i}, word={j}: "
                    f"unpacked={unpacked:08X}, expected={expected:08X}"
                )


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

    parser.add_argument(
        "--csv_has_row_idx",
        type=int,
        default=1,
        help="If 1, lane word[31:16] stores original logical row index. Recommended for row reorder.",
    )

    parser.add_argument(
        "--value_mode",
        choices=["table", "uniform", "quantized"],
        default="table",
        help="Value generation mode. table is easiest for early RTL debug.",
    )
    parser.add_argument("--value_min", type=float, default=-4.0)
    parser.add_argument("--value_max", type=float, default=4.0)
    parser.add_argument("--value_step", type=float, default=0.5)

    args = parser.parse_args()

    if args.pe_lanes <= 0:
        raise ValueError("--pe_lanes must be positive")

    if args.M > 65535 or args.N > 65535 or args.K > 65535:
        raise ValueError("Current 16-bit row/col index format requires M/N/K <= 65535")

    csv_has_row_idx = bool(args.csv_has_row_idx)

    rng = random.Random(args.seed)
    case_dir = ensure_dir(args.out_dir / args.case)

    A_original = gen_a_matrix(
        args.M,
        args.K,
        args.sparsity,
        rng,
        args.value_mode,
        args.value_min,
        args.value_max,
        args.value_step,
    )

    B = gen_b_matrix(
        args.K,
        args.N,
        args.sparsity,
        rng,
        args.value_mode,
        args.value_min,
        args.value_max,
        args.value_step,
    )

    before_csv = estimate_csv_metrics(A_original, args.pe_lanes)

    row_perm = list(range(args.M))
    A_reordered = A_original

    if args.reorder == "greedy":
        row_perm = greedy_row_reorder(A_original)
        A_reordered = apply_row_permutation(A_original, row_perm)

    after_csv = estimate_csv_metrics(A_reordered, args.pe_lanes)

    # Golden C in normal original row order.
    # This should match hardware output when CSV_HAS_ROW_IDX=1.
    C_original_order = matmul_dense(A_original, B)

    # Useful for debugging physical reordered row order.
    C_reordered_order = matmul_dense(A_reordered, B)

    # Dense matrices.
    write_dense_fp16_matrix(case_dir / "a_original_dense.hex", A_original)
    write_dense_fp16_matrix(case_dir / "a_dense.hex", A_reordered)
    write_dense_fp16_matrix(case_dir / "b_dense.hex", B)

    write_dense_fp16_matrix(case_dir / "golden_c.hex", C_original_order)
    write_dense_fp16_matrix(case_dir / "golden_c_reordered.hex", C_reordered_order)
    write_float_text(case_dir / "golden_c_float.txt", C_original_order)

    # CSR files.
    a_row_ptr, a_entries = dense_to_csr(A_reordered)
    b_row_ptr, b_entries = dense_to_csr(B)

    write_hex_words(case_dir / "a_csr_row_ptr.hex", a_row_ptr, width=32)
    write_hex_words(case_dir / "a_csr_entry.hex", a_entries, width=32)
    write_hex_words(case_dir / "b_csr_row_ptr.hex", b_row_ptr, width=32)
    write_hex_words(case_dir / "b_csr_entry.hex", b_entries, width=32)

    # CSV-like files.
    # logical_row_ids maps physical reordered row -> original row.
    logical_row_ids = row_perm if args.reorder == "greedy" else list(range(args.M))

    csv_vectors = build_csv_vectors(
        A=A_reordered,
        pe_lanes=args.pe_lanes,
        logical_row_ids=logical_row_ids,
        csv_has_row_idx=csv_has_row_idx,
    )

    csv_words = encode_csv_vectors_word_stream(
        vectors=csv_vectors,
        pe_lanes=args.pe_lanes,
        csv_has_row_idx=csv_has_row_idx,
    )

    csv_vec_words = pack_csv_words_to_vector_words(
        csv_words=csv_words,
        pe_lanes=args.pe_lanes,
    )

    verify_csv_pack(csv_words, csv_vec_words, args.pe_lanes)

    mw = mask_word_count(args.pe_lanes)
    csv_words_per_vec = csv_words_per_vector(args.pe_lanes)
    csv_vector_width = 32 * csv_words_per_vec
    csv_mask_width = 32 * mw

    # CSV word stream: one 32-bit word per line.
    write_hex_words(case_dir / "a_csv.hex", csv_words, width=32)

    # Vector-wide CSV: one full vector per line.
    write_hex_words(case_dir / "a_csv_vec.hex", csv_vec_words, width=csv_vector_width)

    # JSON version for human inspection/debug.
    json_vectors = []
    for v in csv_vectors:
        valid_words = split_mask_to_words(int(v["valid_mask"]), args.pe_lanes)
        eor_words = split_mask_to_words(int(v["eor_mask"]), args.pe_lanes)

        lane_words = []
        for p in range(args.pe_lanes):
            high = int(v["row_idx_bits"][p]) if csv_has_row_idx else 0
            low = int(v["a_vals_bits"][p]) & 0xFFFF
            lane_words.append(int_to_hex(((high & 0xFFFF) << 16) | low, 32))

        json_vectors.append({
            "row_base": int(v["row_base"]),
            "k": int(v["k"]),

            "valid_mask_hex": int_to_hex(int(v["valid_mask"]), csv_mask_width),
            "eor_mask_hex": int_to_hex(int(v["eor_mask"]), csv_mask_width),

            "valid_mask_words_hex": [int_to_hex(w, 32) for w in valid_words],
            "eor_mask_words_hex": [int_to_hex(w, 32) for w in eor_words],

            "lane_words_hex": lane_words,
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
        "PE_LANES": args.pe_lanes,
        "reorder": args.reorder,
        "data_width": 16,
        "idx_width": 16,
        "word_width": 32,

        "csv_has_row_idx": int(csv_has_row_idx),
        "CSV_HAS_ROW_IDX": int(csv_has_row_idx),

        "csv_mask_words": mw,
        "csv_mask_width": csv_mask_width,
        "csv_words_per_vector": csv_words_per_vec,
        "csv_vector_width": csv_vector_width,
        "csv_vector_count": len(csv_vectors),

        "a_nnz": len(a_entries),
        "b_nnz": len(b_entries),

        "value_mode": args.value_mode,
        "value_min": args.value_min,
        "value_max": args.value_max,
        "value_step": args.value_step,

        "files": {
            "a_csv": "a_csv.hex",
            "a_csv_vec": "a_csv_vec.hex",
            "a_dense": "a_dense.hex",
            "a_original_dense": "a_original_dense.hex",
            "b_dense": "b_dense.hex",
            "b_csr_row_ptr": "b_csr_row_ptr.hex",
            "b_csr_entry": "b_csr_entry.hex",
            "golden_c": "golden_c.hex",
            "golden_c_reordered": "golden_c_reordered.hex",
        },
    }

    write_json(case_dir / "config.json", cfg)
    write_json(case_dir / "a_row_perm.json", {"perm": row_perm})

    meta = {
        "a_original_stats": matrix_stats(A_original),
        "a_reordered_stats": matrix_stats(A_reordered),
        "b_stats": matrix_stats(B),
        "c_original_order_stats": matrix_stats(C_original_order),
        "c_reordered_order_stats": matrix_stats(C_reordered_order),
        "csv_metrics_before_reorder": before_csv,
        "csv_metrics_after_reorder": after_csv,
        "csv_vector_count": len(csv_vectors),
        "csv_mask_words": mw,
        "csv_mask_width": csv_mask_width,
        "csv_words_per_vector": csv_words_per_vec,
        "csv_vector_width": csv_vector_width,
    }

    write_json(case_dir / "meta.json", meta)

    print(f"[GEN] testcase: {args.case}")
    print(f"[GEN] output   : {case_dir}")
    print(f"[GEN] A nnz={len(a_entries)}, B nnz={len(b_entries)}, CSV vectors={len(csv_vectors)}")
    print(f"[GEN] PE_LANES={args.pe_lanes}")
    print(f"[GEN] CSV mask words={mw}, mask width={csv_mask_width} bits")
    print(f"[GEN] CSV words/vector={csv_words_per_vec}, vector width={csv_vector_width} bits")
    print(f"[GEN] CSV util before={before_csv['lane_utilization']:.4f}, after={after_csv['lane_utilization']:.4f}")
    print(f"[GEN] CSV_HAS_ROW_IDX={int(csv_has_row_idx)}")
    print(f"[GEN] wrote CSV word stream : {case_dir / 'a_csv.hex'}")
    print(f"[GEN] wrote vector CSV      : {case_dir / 'a_csv_vec.hex'}")


if __name__ == "__main__":
    main()