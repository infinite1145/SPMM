#!/usr/bin/env python3
"""FP16/hex utility functions for PE framework tools.

Only uses Python standard library. The FP16 conversion uses struct format 'e'
(IEEE-754 binary16), available in modern Python 3.
"""
from __future__ import annotations

import json
import math
import struct
from pathlib import Path
from typing import Iterable, List, Sequence, Tuple


def ensure_dir(path: str | Path) -> Path:
    p = Path(path)
    p.mkdir(parents=True, exist_ok=True)
    return p


def float_to_fp16_bits(value: float) -> int:
    """Convert Python float to IEEE-754 FP16 bit pattern."""
    # Clamp infinities/NaNs are left to struct; values outside FP16 range may overflow.
    return struct.unpack(">H", struct.pack(">e", float(value)))[0]


def fp16_bits_to_float(bits: int) -> float:
    """Convert IEEE-754 FP16 bit pattern to Python float."""
    return float(struct.unpack(">e", struct.pack(">H", int(bits) & 0xFFFF))[0])


def hex_to_int(token: str) -> int:
    token = token.strip()
    if not token:
        raise ValueError("empty hex token")
    token = token.replace("_", "")
    if token.lower().startswith("0x"):
        token = token[2:]
    return int(token, 16)


def int_to_hex(value: int, width: int) -> str:
    digits = (width + 3) // 4
    mask = (1 << width) - 1
    return f"{int(value) & mask:0{digits}X}"


def read_hex_words(path: str | Path) -> List[int]:
    words: List[int] = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            # Remove comments after // or #.
            line = line.split("//", 1)[0]
            line = line.split("#", 1)[0]
            line = line.strip()
            if not line:
                continue
            for tok in line.split():
                words.append(hex_to_int(tok))
    return words


def write_hex_words(path: str | Path, words: Iterable[int], width: int = 16) -> None:
    path = Path(path)
    ensure_dir(path.parent)
    with open(path, "w", encoding="utf-8") as f:
        for w in words:
            f.write(int_to_hex(int(w), width) + "\n")


def read_dense_hex_matrix(path: str | Path, rows: int, cols: int, dtype: str = "fp16") -> List[List[float]]:
    words = read_hex_words(path)
    expected = rows * cols
    if len(words) < expected:
        raise ValueError(f"{path}: expected at least {expected} words, got {len(words)}")
    mat: List[List[float]] = []
    for r in range(rows):
        row: List[float] = []
        for c in range(cols):
            w = words[r * cols + c]
            if dtype == "fp16":
                row.append(fp16_bits_to_float(w))
            elif dtype == "int":
                row.append(float(w))
            else:
                raise ValueError(f"unsupported dtype: {dtype}")
        mat.append(row)
    return mat


def write_dense_fp16_matrix(path: str | Path, mat: Sequence[Sequence[float]]) -> None:
    words = []
    for row in mat:
        for x in row:
            words.append(float_to_fp16_bits(float(x)))
    write_hex_words(path, words, width=16)


def pack_idx_val(index: int, value: float) -> int:
    """Pack {index[15:0], fp16_value[15:0]} as one 32-bit word."""
    return ((int(index) & 0xFFFF) << 16) | float_to_fp16_bits(float(value))


def unpack_idx_val(word: int) -> Tuple[int, float]:
    idx = (int(word) >> 16) & 0xFFFF
    val = fp16_bits_to_float(int(word) & 0xFFFF)
    return idx, val


def dense_to_csr(mat: Sequence[Sequence[float]], zero_eps: float = 0.0) -> Tuple[List[int], List[int]]:
    """Return CSR row_ptr and packed {col,value} entries, sorted by col."""
    row_ptr = [0]
    entries: List[int] = []
    for row in mat:
        for col, value in enumerate(row):
            if abs(float(value)) > zero_eps:
                entries.append(pack_idx_val(col, float(value)))
        row_ptr.append(len(entries))
    return row_ptr, entries


def csr_to_dense(row_ptr: Sequence[int], entries: Sequence[int], rows: int, cols: int) -> List[List[float]]:
    mat = [[0.0 for _ in range(cols)] for _ in range(rows)]
    for r in range(rows):
        for p in range(int(row_ptr[r]), int(row_ptr[r + 1])):
            c, v = unpack_idx_val(entries[p])
            if c >= cols:
                raise ValueError(f"CSR entry column {c} out of range for cols={cols}")
            mat[r][c] = v
    return mat


def matmul_dense(A: Sequence[Sequence[float]], B: Sequence[Sequence[float]]) -> List[List[float]]:
    if not A:
        return []
    M = len(A)
    K = len(A[0]) if M else 0
    if len(B) != K:
        raise ValueError(f"shape mismatch: A is {M}x{K}, B has {len(B)} rows")
    N = len(B[0]) if B else 0
    C = [[0.0 for _ in range(N)] for _ in range(M)]
    # Sparse-aware dense loops.
    for i in range(M):
        for k in range(K):
            a = float(A[i][k])
            if a == 0.0:
                continue
            brow = B[k]
            for j in range(N):
                b = float(brow[j])
                if b != 0.0:
                    C[i][j] += a * b
    return C


def read_json(path: str | Path) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def write_json(path: str | Path, data: dict) -> None:
    path = Path(path)
    ensure_dir(path.parent)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")


def matrix_stats(mat: Sequence[Sequence[float]], zero_eps: float = 0.0) -> dict:
    rows = len(mat)
    cols = len(mat[0]) if rows else 0
    row_nnz = [sum(1 for v in row if abs(float(v)) > zero_eps) for row in mat]
    col_nnz = []
    for c in range(cols):
        col_nnz.append(sum(1 for r in range(rows) if abs(float(mat[r][c])) > zero_eps))
    nnz = sum(row_nnz)
    return {
        "rows": rows,
        "cols": cols,
        "nnz": nnz,
        "density": (nnz / (rows * cols)) if rows and cols else 0.0,
        "row_nnz_min": min(row_nnz) if row_nnz else 0,
        "row_nnz_max": max(row_nnz) if row_nnz else 0,
        "row_nnz_avg": (sum(row_nnz) / rows) if rows else 0.0,
        "col_nnz_min": min(col_nnz) if col_nnz else 0,
        "col_nnz_max": max(col_nnz) if col_nnz else 0,
        "col_nnz_avg": (sum(col_nnz) / cols) if cols else 0.0,
        "row_nnz": row_nnz,
        "col_nnz": col_nnz,
    }
