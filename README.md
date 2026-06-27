# SPMM 64PE 集成验证工程说明

## 1. 当前工程状态

本工程用于验证基于 PE array 的稀疏矩阵乘法：

```text
C = A * B
```

当前主线已经不是早期的 PE 局部 testbench，而是固定 64PE 的集成 top 验证流程：

```text
Python 生成测试用例
  -> VCS 编译 PE_SpMM_Top
  -> spmm_top_testbench 启动 DUT
  -> DUT 内部 Load_A / Load_B / PE array / Store 协同计算
  -> testbench 从 C RAM debug 端口导出 dense C
  -> Python bit-level 比对
  -> Python 可视化
```

需要特别注意：

1. 当前 Makefile 固定 `PE_LANES := 64`，并强制检查测试用例格式为 64PE。
2. 当前集成仿真入口是 `tb/spmm_top_testbench.sv`，DUT 是 `src/PE_Spmm_top.sv` 中的 `PE_SpMM_Top`。
3. `tb/pe_array_testbench.sv` 是旧的 PE array 局部验证 testbench，仍保留在仓库中，但当前 Makefile 不使用它。
4. 仓库中部分已有测试用例仍是旧 4PE 格式，不能直接用于当前 Makefile 的 64PE 集成仿真。

当前已生成用例中：

| 用例 | 状态 |
| --- | --- |
| `medium_big` | 64PE 格式，可用于当前 Makefile |
| `max` | 64PE 格式，可用于当前 Makefile |
| `verymini`、`verysmall`、`small`、`medium_small`、`medium`、`big` | 旧 4PE 格式，使用当前 Makefile 前需要重新生成 |

如果要运行 `small` 这类旧用例名，请先重新生成：

```bash
make gen CASE=small M=16 N=16 K=16 SPARSITY=0.3 SEED=1
```

重新生成会覆盖对应 `testcases/<case>/` 下的数据，并生成当前 64PE 格式的 `a_csv_vec.hex`。

## 2. 工程目录

当前目录结构如下：

```text
SPMM/
├── Makefile
├── README.md
├── src/
│   ├── PE_Spmm_top.sv
│   ├── PE_Load_A.sv
│   ├── PE_LOAD_B.sv
│   ├── PE_STROE.sv
│   ├── PE_Core.sv
│   ├── PE_Row_Buffer.sv
│   ├── PE_FIFO_512.sv
│   ├── PE_FP_Mul.sv
│   ├── PE_FP_Add.sv
│   ├── inc/
│   │   └── pe_defines.svh
│   └── rams_and_roms/
│       ├── PE_A_Vector_Rom.sv
│       ├── PE_B_RowPtr_ROM_2P.sv
│       ├── PE_B_Entry_ROM.sv
│       └── PE_C_Dense_RAM_TDP.sv
├── tb/
│   ├── spmm_top_testbench.sv
│   └── pe_array_testbench.sv
├── tools/
│   ├── gen_matrix.py
│   ├── reorder.py
│   ├── check_result.py
│   ├── visualize.py
│   └── fp16_utils.py
├── testcases/
├── test_result/
├── check_result/
├── visual_result/
└── build_dir/          # 编译时生成，仓库中可能不存在
```

说明：

| 路径 | 功能 |
| --- | --- |
| `src/PE_Spmm_top.sv` | 当前集成 top，例化 ROM/RAM、Load_A、Load_B、PE array、Store |
| `src/PE_Load_A.sv` | 从 A vector ROM 读取 64PE CSV vector，产生 QA 任务和 B 行请求 |
| `src/PE_LOAD_B.sv` | 根据 B CSR row pointer 读取 B row stream，并广播到 active PE |
| `src/PE_STROE.sv` | Store 模块源码文件，内部模块名为 `PE_Store` |
| `src/PE_Core.sv` | 单个 PE 的 merge-add 核心 |
| `src/rams_and_roms/` | 仿真用 ROM/RAM 封装 |
| `tb/spmm_top_testbench.sv` | 当前 Makefile 使用的集成 testbench |
| `tb/pe_array_testbench.sv` | 旧 PE 局部 testbench，保留用于历史调试参考 |
| `tools/` | 测试用例生成、重排、结果比对、可视化脚本 |
| `testcases/` | 生成的输入矩阵、CSR、CSV vector、golden result |
| `test_result/` | RTL 仿真输出的 dense C |
| `check_result/` | Python 比对报告 |
| `visual_result/` | 矩阵热力图、非零图和差异图 |
| `build_dir/` | VCS 编译中间文件、filelist、日志和 simv |

`PE_STROE.sv` 的文件名保留了当前仓库中的实际拼写；引用时以文件名为准，模块名是 `PE_Store`。

## 3. 环境要求

推荐在 Linux、WSL 或服务器环境中运行 Makefile。Makefile 使用了 `mkdir -p`、`rm`、`find`、`test` 等类 Unix 命令，并默认使用 Synopsys VCS。

主要工具：

| 工具 | 用途 |
| --- | --- |
| Python 3 | 生成测试用例、比对、可视化 |
| matplotlib | `make vis_case`、`make vis_result`、`make vis_all` 需要 |
| VCS | 编译和运行 SystemVerilog 仿真 |
| Verdi / Novas | 可选，用于 `make wave` 查看 FSDB |

如果本机 Python 命令不是 `python3`，可以通过 `PYTHON` 覆盖：

```bash
make gen CASE=demo64 PYTHON=python
```

## 4. 常用流程

### 4.1 使用已有 64PE 用例

`medium_big` 和 `max` 已经是当前 64PE 格式。可以直接运行：

```bash
make test CASE=medium_big
make check CASE=medium_big
make vis_all CASE=medium_big
```

输出文件为：

```text
test_result/res_medium_big.hex
check_result/medium_big_check.json
visual_result/medium_big/
```

### 4.2 生成新用例

当前 Makefile 会固定生成 64PE 用例，不需要也不建议在命令行传 `PE_LANES`：

```bash
make gen CASE=demo64 M=64 N=64 K=64 SPARSITY=0.3 SEED=1
```

生成目录：

```text
testcases/demo64/
```

`make gen` 只生成数据，不编译、不仿真。

### 4.3 运行已有用例

```bash
make test CASE=demo64
```

该目标会：

1. 生成 `build_dir/filelist.f`；
2. 检查 `testcases/demo64/config.json` 是否为 64PE 格式；
3. 编译 `PE_SpMM_Top` 和 `spmm_top_testbench`；
4. 运行仿真；
5. 将 C RAM 导出到 `test_result/res_demo64.hex`。

当前格式检查要求：

```text
PE_LANES = 64
csv_words_per_vector = 69
csv_vector_width = 2208
```

### 4.4 比对结果

```bash
make check CASE=demo64
```

该命令比较：

```text
testcases/demo64/golden_c.hex
test_result/res_demo64.hex
```

并输出：

```text
check_result/demo64_check.json
```

当前 Makefile 默认使用 bit-level 比对：

```text
RTL 输出 FP16 hex == Python golden FP16 hex
```

### 4.5 可视化

```bash
make vis_all CASE=demo64
```

该目标包含：

```bash
make vis_case CASE=demo64
make vis_result CASE=demo64
```

输出目录：

```text
visual_result/demo64/
```

主要图片包括：

| 图片 | 用途 |
| --- | --- |
| `A_value_a_original_dense.png` | 原始 A 数值分布 |
| `A_nonzero_a_original_dense.png` | 原始 A 非零分布 |
| `A_value_a_dense.png` | 重排后 A 数值分布 |
| `A_nonzero_a_dense.png` | 重排后 A 非零分布 |
| `B_value_b_dense.png` | B 数值分布 |
| `B_nonzero_b_dense.png` | B 非零分布 |
| `C_value_golden_c.png` | Python golden C |
| `C_nonzero_golden_c.png` | golden C 非零分布 |
| `C_value_res_<case>.png` | RTL 输出 C |
| `C_nonzero_res_<case>.png` | RTL 输出 C 非零分布 |
| `C_diff_res_<case>.png` | RTL 与 golden 的绝对误差 |

### 4.6 一键流程

```bash
make gen_test CASE=demo64 M=64 N=64 K=64 SPARSITY=0.3 SEED=1
```

等价于：

```bash
make gen CASE=demo64 M=64 N=64 K=64 SPARSITY=0.3 SEED=1
make test CASE=demo64
make check CASE=demo64
make vis_all CASE=demo64
```

### 4.7 查看波形

仿真会输出 FSDB，默认文件为：

```text
spmm_top.fsdb
```

打开波形：

```bash
make wave
```

## 5. Makefile 目标

| 目标 | 功能 |
| --- | --- |
| `make gen` | 生成 64PE 测试用例 |
| `make reorder` | 对已有用例重新运行行重排分析 |
| `make compile` | 生成 filelist、检查用例格式、编译 VCS |
| `make test` / `make run` | 编译并运行当前集成 top |
| `make check` | 比对 RTL 输出和 golden |
| `make vis_case` | 可视化输入矩阵和 golden |
| `make vis_result` | 可视化 RTL 输出和 diff |
| `make vis_all` | `vis_case + vis_result` |
| `make gen_test` | 生成、仿真、比对、可视化一键流程 |
| `make wave` | 使用 Verdi 打开 FSDB |
| `make clean` | 清理 VCS/Verdi 中间文件 |
| `make clean_data` | 删除 `testcases/`、`test_result/`、`check_result/`、`visual_result/` |
| `make clean_all` | 同时执行 `clean` 和 `clean_data` |

## 6. 测试用例文件格式

`tools/gen_matrix.py` 会在 `testcases/<case>/` 下生成：

```text
config.json
meta.json

a_original_dense.hex
a_dense.hex
b_dense.hex

a_csr_row_ptr.hex
a_csr_entry.hex
b_csr_row_ptr.hex
b_csr_entry.hex

a_csv.hex
a_csv_vec.hex
a_csv_vectors.json
a_row_perm.json

golden_c.hex
golden_c_reordered.hex
golden_c_float.txt
```

说明：

| 文件 | 说明 |
| --- | --- |
| `config.json` | 用例规模、稀疏度、CSV 格式参数、文件名 |
| `meta.json` | 矩阵统计、重排前后 CSV 利用率等调试信息 |
| `a_original_dense.hex` | 原始 A，dense row-major |
| `a_dense.hex` | 行重排后的 A，dense row-major |
| `b_dense.hex` | B，dense row-major |
| `a_csr_row_ptr.hex`、`a_csr_entry.hex` | 重排后 A 的 CSR 表示，主要用于调试 |
| `b_csr_row_ptr.hex`、`b_csr_entry.hex` | B 的 CSR 表示，当前 Load_B 使用 |
| `a_csv.hex` | A CSV vector 的 32-bit word stream 表示，便于人工检查 |
| `a_csv_vec.hex` | 当前 A vector ROM 实际使用的 2208-bit 宽初始化文件 |
| `a_csv_vectors.json` | CSV vector 的 JSON 调试视图 |
| `a_row_perm.json` | 物理重排行到原始逻辑行的映射 |
| `golden_c.hex` | 原始行顺序下的 golden C，当前硬件输出应匹配它 |
| `golden_c_reordered.hex` | 重排行顺序下的 C，仅用于调试 |
| `golden_c_float.txt` | 浮点文本版本 golden C |

### 6.1 dense hex

Dense 矩阵按 row-major 存储，每行一个 FP16 hex：

```text
line 0       -> matrix[0][0]
line 1       -> matrix[0][1]
...
line cols-1  -> matrix[0][cols-1]
line cols    -> matrix[1][0]
```

RTL 输出结果也采用该格式：

```text
test_result/res_<case>.hex
```

### 6.2 B CSR

`b_csr_row_ptr.hex` 每行一个 32-bit pointer，长度为 `K + 1`。

`b_csr_entry.hex` 每行一个 32-bit entry：

```text
entry = {col_idx[15:0], value_fp16[15:0]}
```

Load_B 根据当前 A vector 的 `k` 读取：

```text
start = B_row_ptr[k]
end   = B_row_ptr[k + 1]
```

并把 `B_entry[start]` 到 `B_entry[end-1]` 广播给 active PE。

### 6.3 64PE A CSV vector

当前集成 top 使用固定 64PE vector-wide A ROM。

对 64PE：

```text
MASK_WORDS = 2
CSV_WORDS_PER_VECTOR = 1 + 2 * MASK_WORDS + 64 = 69
CSV_VECTOR_WIDTH = 69 * 32 = 2208 bits
```

一个 vector 的 32-bit word 布局为：

```text
word0  = {row_base[15:0], k[15:0]}
word1  = valid_mask[31:0]
word2  = valid_mask[63:32]
word3  = eor_mask[31:0]
word4  = eor_mask[63:32]
word5  = lane_word[0]
...
word68 = lane_word[63]
```

`a_csv.hex` 是上述 69 个 32-bit word 的逐行文本流。

`a_csv_vec.hex` 将每 69 个 32-bit word 打包成一行 2208-bit hex，用于 `PE_A_Vector_ROM`：

```text
packed[31:0]        = word0
packed[63:32]       = word1
...
packed[2207:2176]   = word68
```

由于 hex 文本高位在前，`a_csv_vec.hex` 中肉眼看到的顺序会是高 word 在左、低 word 在右。

### 6.4 CSV_HAS_ROW_IDX

当前默认：

```text
CSV_HAS_ROW_IDX = 1
```

此时：

```text
lane_word[p] = {original_row_idx[15:0], a_val_fp16[15:0]}
```

这样即使 A 经过行重排，Store 仍能把结果写回原始矩阵行顺序，最终输出匹配 `golden_c.hex`。

如果设为 0：

```text
lane_word[p][31:16] = 16'h0
row_idx = row_base + p
```

这通常只适合关闭行重排或调试物理行顺序。

## 7. 集成 top 数据流

当前 DUT 为：

```text
PE_SpMM_Top
├── PE_A_Vector_ROM
├── PE_B_RowPtr_ROM_2P
├── PE_B_Entry_ROM
├── PE_C_Dense_RAM_TDP
├── PE_Load_A
├── PE_Load_B
├── QA/QB interface FIFOs
├── 64 x PE_Core
└── PE_Store
```

整体流程：

1. `spmm_top_testbench` 通过 plusargs 传入 `M`、`N`、`CSV_VECTOR_COUNT`、`CSV_HAS_ROW_IDX`、结果路径和 FSDB 路径。
2. Makefile 通过 VCS define 传入 ROM 初始化文件：

```text
PE_A_INIT_FILE      = testcases/<case>/a_csv_vec.hex
PE_B_PTR_INIT_FILE  = testcases/<case>/b_csr_row_ptr.hex
PE_B_ENT_INIT_FILE  = testcases/<case>/b_csr_entry.hex
```

3. `PE_SpMM_Top` 先清零 C dense RAM。
4. `PE_Load_A` 从 A vector ROM 顺序读取 2208-bit CSV vector。
5. `PE_Load_A` 解码 valid/eor mask 和 lane words，向 active PE 发送 QA 任务。
6. `PE_Load_A` 同时向 `PE_Load_B` 发出当前 `k` 和 active mask。
7. `PE_Load_B` 读取 B CSR row，并把 B row stream 推入 QB 通道。
8. 每个 `PE_Core` 对自己的 A scalar 和共享 B row 进行 partial row merge-add。
9. final merge 时，PE 输出：

```text
result_wr_data = {row_idx, col_idx, value}
```

10. `PE_Store` 对 64 个 PE 的 result FIFO 做 round-robin 仲裁，写入：

```text
C[row_idx * N + col_idx] = value
```

11. DUT done 后，testbench 通过 C RAM debug read port 导出完整 dense C。

## 8. PE_Core 行为概览

单个 PE 每次处理一个 A scalar：

```text
A[row_idx][k] = qa_val
```

并接收对应的 B row stream：

```text
B[k, *]
```

PE 内部维护双 partial row buffer。非 final merge 写回内部 buffer，final merge 输出到 Store。

主要状态：

```systemverilog
typedef enum logic [3:0] {
    PE_S_IDLE,
    PE_S_FETCH_B,
    PE_S_DECIDE,
    PE_S_START_MUL,
    PE_S_WAIT_MUL,
    PE_S_START_ADD,
    PE_S_WAIT_ADD,
    PE_S_EMIT,
    PE_S_FINISH
} pe_state_e;
```

三类 merge 情况：

| 情况 | 行为 |
| --- | --- |
| `buf_col < b_col` | 旧 partial row 独有，直接 emit old |
| `buf_col > b_col` | 新 B entry 独有，计算 `a_val * b_val` |
| `buf_col == b_col` | 同列累加，计算 `buf_val + a_val * b_val` |

当 `qa_eor=0` 时，emit 结果写入另一个 partial buffer。

当 `qa_eor=1` 时，emit 结果输出给 Store，表示该 A 行最终 C row 的一部分。

空 B 行约定：

```text
qb_valid = 1
qb_empty = 1
qb_last  = 1
```

此时 PE 不产生新的 partial row，只处理旧 partial row 的剩余内容。

## 9. 行重排与 golden 对齐

默认生成器使用：

```text
REORDER = greedy
CSV_HAS_ROW_IDX = 1
```

行重排会改变 A 的物理行顺序，用于提高 CSV lane 利用率：

```text
a_original_dense.hex  -> 原始 A
a_dense.hex           -> 重排后 A
a_row_perm.json       -> physical row -> original row
```

`golden_c.hex` 始终是原始行顺序下的结果：

```text
golden_c.hex = A_original * B
```

由于 lane word 携带 `original_row_idx`，硬件 Store 会把结果写回原始行号，所以当前 RTL 输出应与 `golden_c.hex` 做比对。

`golden_c_reordered.hex` 只是调试辅助，用于观察物理重排行顺序下的结果。

## 10. 旧 pe_array_testbench 说明

`tb/pe_array_testbench.sv` 是早期 PE 局部验证环境。它直接读取：

```text
a_csv.hex
b_csr_row_ptr.hex
b_csr_entry.hex
```

并在 testbench 内部模拟 Loader/Store 行为。

该 testbench 的 CSV mask 旧格式最多支持 16 lanes：

```text
word0 = {row_base[15:0], k[15:0]}
word1 = {eor_mask[15:0], valid_mask[15:0]}
word2 ... = lane words
```

当前 `tools/gen_matrix.py` 和集成 top 已使用可扩展 mask word 格式；64PE 时为 69 words/vector。因此不要把 `pe_array_testbench.sv` 当作当前 Makefile 的主仿真入口。

如果要继续使用旧 testbench，需要单独维护对应的 compile target 和输入格式。

## 11. 常见问题

### make test CASE=small 报 64PE 格式错误

原因是仓库中的 `small` 可能仍是旧 4PE 数据。重新生成即可：

```bash
make gen CASE=small M=16 N=16 K=16 SPARSITY=0.3 SEED=1
make test CASE=small
```

### 修改 PE_LANES 后无法运行

当前分支是固定 64PE 版本。修改 PE 数量不仅要改 Makefile，还要同步修改：

```text
PE_Load_A 的 vector decode
PE_SpMM_Top 的 A_VEC_W
测试用例 csv_words_per_vector / csv_vector_width
ROM 初始化文件宽度
testbench 的 64PE guard
```

建议在当前版本中保持 64PE。

### C_diff 图非零

优先检查：

1. 测试用例是否为 64PE 格式；
2. `CSV_HAS_ROW_IDX` 是否为 1；
3. `golden_c.hex` 和 `res_<case>.hex` 长度是否一致；
4. Store 写回地址是否为 `row_idx * N + col_idx`；
5. PE final merge 时 `qa_eor` 是否正确触发 result 输出；
6. FSDB 中 QA/QB 握手、B row stream、PE partial buffer 切换是否符合预期。

### 可视化脚本提示缺少 matplotlib

安装 matplotlib 后重新运行：

```bash
python3 -m pip install matplotlib
```

或在 Makefile 中指定可用的 Python：

```bash
make vis_all CASE=medium_big PYTHON=python
```

## 12. 当前验证重点

当前工程的验证重点是：

1. 64PE vector-wide A 输入格式是否正确解码；
2. Load_A、Load_B、PE、Store 之间的 valid-ready 协议是否正确；
3. B CSR row stream 是否按 `k` 正确读取和广播；
4. PE partial row buffer 是否正确 merge 和切换；
5. `qa_eor` 是否正确区分 partial merge 和 final merge；
6. Store 是否在 result FIFO 仲裁后正确写入 dense C RAM；
7. RTL 输出是否 bit-level 匹配 Python `golden_c.hex`。

