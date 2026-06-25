# PE 框架工程说明与前期集成文档

## 1. 工程结构与自动化测试流程

本工程采用“测试用例生成—RTL 仿真—结果比对—可视化分析”的自动化流程组织。当前阶段的目标是先完成 PE 模块的局部验证与工程基础设施搭建，为后续 Loader、Store、Controller 等模块的系统集成提供稳定的验证环境。

推荐工程目录结构如下：

```text
pe_framework/
├── Makefile
├── requirements.txt
├── src/
│   ├── PE_Core.sv
│   ├── PE_Row_Buffer.sv
│   ├── PE_FP_Mul.sv
│   ├── PE_FP_Add.sv
│   └── inc/
│       └── pe_defines.svh
├── tb/
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
└── build_dir/
```

各目录功能如下：

| 目录               | 功能               |
| ---------------- | ---------------- |
| `src/`           | 保存 PE 相关 RTL 源码  |
| `src/inc/`       | 保存宏定义头文件         |
| `tb/`            | 保存 testbench     |
| `tools/`         | 保存 Python 工具脚本   |
| `testcases/`     | 保存生成的测试用例        |
| `test_result/`   | 保存 RTL 仿真输出结果    |
| `check_result/`  | 保存结果比对报告         |
| `visual_result/` | 保存矩阵可视化图片        |
| `build_dir/`     | 保存 VCS 编译和仿真中间文件 |

当前 Makefile 将工程验证流程拆分为若干独立目标，便于持续开发和定位问题。

### 1.1 生成测试用例

使用如下命令生成一个测试用例：

```bash
make gen CASE=small M=16 N=16 K=16 PE_LANES=4 SPARSITY=0.3 SEED=1
```

该命令只生成测试用例，不进行 RTL 编译和仿真。生成后的文件位于：

```text
testcases/small/
```

主要文件包括：

```text
config.json
a_original_dense.hex
a_dense.hex
b_dense.hex
a_csv.hex
b_csr_row_ptr.hex
b_csr_entry.hex
golden_c.hex
```

其中：

| 文件                     | 说明                           |
| ---------------------- | ---------------------------- |
| `config.json`          | 测试用例规模与配置参数                  |
| `a_original_dense.hex` | 原始 A 矩阵，dense row-major 存储   |
| `a_dense.hex`          | 重排后的 A 矩阵，dense row-major 存储 |
| `b_dense.hex`          | B 矩阵，dense row-major 存储      |
| `a_csv.hex`            | A 矩阵的 CSV-like 格式，用于 PE 输入   |
| `b_csr_row_ptr.hex`    | B 矩阵 CSR 格式的 row pointer     |
| `b_csr_entry.hex`      | B 矩阵 CSR 格式的非零元素 entry       |
| `golden_c.hex`         | Python golden model 计算得到的 C  |

`make gen` 阶段需要指定矩阵规模和 PE 数量，因为测试用例尚未存在，工具必须根据这些参数生成输入矩阵和 golden result。

### 1.2 运行已有测试用例

测试用例生成后，后续运行仿真只需要指定 `CASE`：

```bash
make test CASE=small
```

此时 Makefile 会自动读取：

```text
testcases/small/config.json
```

从中获得 `M`、`N`、`K`、`PE_LANES` 等信息，并将必要参数通过 plusargs 传递给 testbench。

需要注意的是，testbench 本身不直接读取 `config.json`。当前工程采用如下分层策略：

```text
gen_matrix.py:
    生成 config.json 和 hex 测试数据

Makefile:
    读取 config.json
    将 M/N/PE_LANES 等参数作为 plusargs 传给 testbench

testbench:
    只读取 hex 文件和 plusargs
    不解析 json
```

这样做的好处是 testbench 逻辑更清晰，不依赖 Python json 解析；同时用户也不需要在每次仿真时重复指定矩阵规模。

仿真输出结果位于：

```text
test_result/res_small.hex
```

该文件采用 dense row-major 格式存储：

```text
line 0       -> C[0][0]
line 1       -> C[0][1]
...
line N-1     -> C[0][N-1]
line N       -> C[1][0]
...
line M*N-1   -> C[M-1][N-1]
```

每一行保存一个 FP16 hex 值，零元素也会显式写出，不做稀疏压缩。

### 1.3 检查仿真结果

使用如下命令进行结果比对：

```bash
make check CASE=small
```

该命令比较：

```text
testcases/small/golden_c.hex
test_result/res_small.hex
```

比对结果输出到：

```text
check_result/small_check.json
```

当前建议优先使用 bit-level 比对，即 RTL 输出的 FP16 hex 必须与 golden result 完全一致。这样可以更容易定位 PE 状态机、row/col 写回、eor 控制或 FP 运算单元的问题。

### 1.4 可视化测试用例和结果

使用如下命令生成完整可视化结果：

```bash
make vis_all CASE=small
```

可视化结果保存在：

```text
visual_result/small/
```

主要包括：

```text
A_value_a_original_dense.png
A_nonzero_a_original_dense.png
A_value_a_dense.png
A_nonzero_a_dense.png
B_value_b_dense.png
B_nonzero_b_dense.png
C_value_golden_c.png
C_nonzero_golden_c.png
C_value_res_small.png
C_nonzero_res_small.png
C_diff_res_small.png
```

调试时建议优先观察以下图片：

| 图片                             | 用途                  |
| ------------------------------ | ------------------- |
| `A_value_a_original_dense.png` | 查看原始 A 的数值分布        |
| `A_value_a_dense.png`          | 查看重排后 A 的数值分布       |
| `B_value_b_dense.png`          | 查看 B 的数值分布          |
| `C_value_golden_c.png`         | 查看 golden C 的理论结果   |
| `C_value_res_small.png`        | 查看 RTL 输出结果         |
| `C_diff_res_small.png`         | 查看 RTL 与 golden 的差异 |

如果 `C_diff_res_small.png` 非零，则需要结合 FSDB 波形定位错误来源。

### 1.5 完整一键流程

可以使用如下命令完成生成、仿真、比对和可视化：

```bash
make gen_test CASE=small M=16 N=16 K=16 PE_LANES=4 SPARSITY=0.3 SEED=1
```

该命令等价于：

```bash
make gen CASE=small M=16 N=16 K=16 PE_LANES=4 SPARSITY=0.3 SEED=1
make test CASE=small
make check CASE=small
make vis_all CASE=small
```

---

## 2. Testbench 结构与验证策略

当前 testbench 的目标不是完整复现最终工程中的 Loader/Store/Controller 系统，而是建立一个可控、可观测、可自动化验证的 PE 局部测试环境。

当前 testbench 主要完成以下工作：

1. 根据 `PE_LANES` 例化多个 PE；
2. 读取 `a_csv.hex`；
3. 读取 `b_csr_row_ptr.hex` 和 `b_csr_entry.hex`；
4. 模拟 Loader 行为，将 A scalar 和 B row stream 送入 PE；
5. 接收 PE 输出；
6. 将输出写入 dense C RAM；
7. 将 dense C RAM 导出到 `test_result/res_<case>.hex`。

### 2.1 PE 的例化方式

testbench 根据编译期宏 `PE_LANES` 生成 PE array：

```systemverilog
generate
    for (pe_g = 0; pe_g < PE_LANES_P; pe_g = pe_g + 1) begin : GEN_PE
        PE_Core u_pe_core (...);
    end
endgenerate
```

每个 PE 对应一个 lane。对于一个 CSV vector：

```text
row_base
k
valid_mask
eor_mask
a_val[0 : PE_LANES-1]
```

第 `p` 个 PE 通常对应：

```text
row_idx = row_base + p
```

如果后续 CSV 格式携带原始 row index，则可以设置：

```text
CSV_HAS_ROW_IDX = 1
```

此时 row index 直接来自 CSV lane word 的高 16 bit。这样即使 A 行做了重排，C 也可以写回原始矩阵行顺序。

### 2.2 输入文件读取

testbench 不读取 json 文件，只读取以下 hex 文件：

```text
testcases/<case>/a_csv.hex
testcases/<case>/b_csr_row_ptr.hex
testcases/<case>/b_csr_entry.hex
```

其中 `a_csv.hex` 的格式为：

```text
word0 = {row_base[15:0], k[15:0]}
word1 = {eor_mask[15:0], valid_mask[15:0]}
word2 = {optional_row_idx[15:0], a_val[0][15:0]}
word3 = {optional_row_idx[15:0], a_val[1][15:0]}
...
word(2+PE_LANES-1)
```

当 `CSV_HAS_ROW_IDX=0` 时，lane word 的高 16 bit 不作为 row index 使用，PE row index 由 `row_base + lane` 得到。

B 矩阵采用 CSR 格式。testbench 根据 CSV vector 中的 `k` 读取 B 的第 k 行：

```text
start = B_row_ptr[k]
end   = B_row_ptr[k+1]
```

然后将：

```text
B_entry[start] ~ B_entry[end-1]
```

作为 B row stream 广播给所有 active PE。

### 2.3 QA 输入通道

QA 通道用于向 PE 发送 A scalar 任务：

```text
qa_valid
qa_ready
qa_row_idx
qa_val
qa_eor
```

每个 active PE 会接收一个 A scalar：

```text
A[row_idx][k] = qa_val
```

其中 `qa_eor` 表示当前 A scalar 是否为该行 A 的最后一个非零元素。如果 `qa_eor=1`，则本轮 merge 的结果应作为最终 C 行结果输出；如果 `qa_eor=0`，则本轮结果应继续写回 PE 内部 partial buffer。

### 2.4 QB 输入通道

QB 通道用于向 PE 发送 B row stream：

```text
qb_valid
qb_ready
qb_col_idx
qb_val
qb_last
qb_empty
```

对于一个 CSV vector，所有 active PE 共享同一行 B：

```text
B[k,*]
```

因此 testbench 会将同一条 B row stream 广播给所有 active PE。

如果 B 第 k 行为空，则 testbench 会发送：

```text
qb_empty = 1
qb_last  = 1
```

用于通知 PE 当前 B 行没有有效非零元素。

### 2.5 C RAM 存储策略

testbench 内部维护一个 dense C RAM：

```systemverilog
logic [PE_DATA_W_P-1:0] c_ram [0:PE_MAX_C_ELEMS-1];
```

PE 输出结果格式为：

```text
result_wr_data = {row_idx, col_idx, value}
```

testbench 解包后根据：

```text
addr = row_idx * N + col_idx
```

写入：

```text
c_ram[addr] = value
```

最终仿真结束时，testbench 将 `c_ram` 完整写出到：

```text
test_result/res_<case>.hex
```

输出格式为 dense row-major，不进行 CSR/CSC 等稀疏压缩，也不省略 0 元素。

### 2.6 当前 testbench 与完整工程的区别

当前 testbench 是 PE 局部验证环境，与完整工程相比存在以下差异：

#### 1. 没有真实 Loader 模块

当前 testbench 直接读取 hex 文件，并模拟 Loader 行为，将 CSV vector 和 B CSR row stream 喂给 PE。完整工程中应由 Loader Module 负责从 BRAM/SRAM 中读取 A/B 数据，并产生对应 valid-ready 流。

#### 2. 没有真实 Store Module

当前 PE 输出后，testbench 直接解析 `{row, col, value}` 并写入仿真数组 `c_ram`。完整工程中应由 Store Module 负责 result FIFO 仲裁、C bank 地址生成和写回。

#### 3. 没有真实 BRAM 时序

当前 testbench 中的 memory 是仿真数组，读取行为比真实 BRAM 更理想。完整工程中需要考虑 BRAM 读延迟、端口限制和 bank conflict。

#### 4. 没有真实 result FIFO 反压

当前 `result_full` 通常置为 0，即结果输出永远可写。完整工程中需要加入 FIFO full 反压逻辑，避免 Store Module 写回速度不足时丢失结果。

#### 5. 没有系统级 Controller

当前 testbench 只围绕 PE 局部功能进行验证。完整工程中还需要引入 Config Controller、Load/Store 调度、start/done 控制和性能计数器。

因此，当前 testbench 的定位是：优先验证 PE 内部 merge-add、FP16 运算和 eor 输出逻辑，在 PE 稳定后再逐步替换为真实工程模块。

---

## 3. PE 状态机与工作流程

PE 内部状态机用于完成一次 sparse row merge-add。每次 PE 接收一个 A scalar：

```text
a_val = A[i,k]
```

同时接收对应的 B row stream：

```text
B[k,*]
```

并与 PE 内部保存的旧 partial row 进行 merge-add。

状态定义如下：

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

整体状态跳转可以概括为：

```text
PE_S_IDLE
  -> PE_S_FETCH_B
  -> PE_S_DECIDE
  -> PE_S_START_MUL
  -> PE_S_WAIT_MUL
  -> PE_S_START_ADD
  -> PE_S_WAIT_ADD
  -> PE_S_EMIT
  -> PE_S_FINISH / PE_S_FETCH_B
```

其中 `START_ADD/WAIT_ADD` 只在旧 partial row 和新 partial row 出现相同列号时进入。

### 3.1 PE_S_IDLE

`PE_S_IDLE` 是空闲状态。PE 在该状态等待 QA 通道输入。

当：

```text
qa_valid && qa_ready
```

成立时，PE 锁存：

```text
qa_row_idx
qa_val
qa_eor
```

其中：

```text
qa_row_idx
```

表示当前 PE 负责输出的 C 行号；

```text
qa_val
```

表示当前 A scalar；

```text
qa_eor
```

表示该 A scalar 是否为当前 A 行的最后一个非零元素。

PE 内部通常会将 `qa_eor` 保存为：

```text
is_final_merge
```

如果 `is_final_merge=0`，本轮输出写回 PE 内部 partial buffer；如果 `is_final_merge=1`，本轮输出进入 result 输出通道。

### 3.2 PE_S_FETCH_B

`PE_S_FETCH_B` 用于获取当前 B row stream 的一个元素，并准备旧 partial row buffer 的当前元素。

两路待合并数据为：

```text
旧 partial row:
    {buf_col, buf_val}

当前新 partial row:
    {b_col, a_val * b_val}
```

其中 B 元素来自 QB 通道：

```text
qb_col_idx
qb_val
qb_last
qb_empty
```

如果 `qb_empty=1`，说明当前 B 行为空，此时没有新的 partial row，只需要根据旧 buffer 是否为空决定是否继续输出旧 partial row。

### 3.3 PE_S_DECIDE

`PE_S_DECIDE` 是状态机的核心控制状态，用于比较旧 partial row 和当前 B row 的列号。

设当前旧 buffer 元素为：

```text
(buf_col, buf_val)
```

当前 B 元素为：

```text
(b_col, b_val)
```

比较结果有三种主要情况。

#### 情况一：`buf_col < b_col`

说明该列只存在于旧 partial row 中，当前 `a_val * B[k,*]` 没有产生同列结果，因此直接输出旧元素：

```text
emit_col = buf_col
emit_val = buf_val
```

该情况不需要乘法，也不需要加法。

状态路径为：

```text
PE_S_DECIDE -> PE_S_EMIT
```

#### 情况二：`buf_col > b_col`

说明该列只存在于当前新 partial row 中，需要计算：

```text
emit_col = b_col
emit_val = a_val * b_val
```

状态路径为：

```text
PE_S_DECIDE
-> PE_S_START_MUL
-> PE_S_WAIT_MUL
-> PE_S_EMIT
```

#### 情况三：`buf_col == b_col`

说明旧 partial row 和当前新 partial row 在同一列产生结果，需要执行 MAC：

```text
emit_col = buf_col
emit_val = buf_val + a_val * b_val
```

状态路径为：

```text
PE_S_DECIDE
-> PE_S_START_MUL
-> PE_S_WAIT_MUL
-> PE_S_START_ADD
-> PE_S_WAIT_ADD
-> PE_S_EMIT
```

这一路径是真正完成部分和累加的路径。

### 3.4 PE_S_START_MUL 与 PE_S_WAIT_MUL

`PE_S_START_MUL` 用于向 FP16 乘法单元发起计算：

```text
a_val * b_val
```

当前乘法单元接口设计为接近 Vivado Floating-Point IP 的 valid-ready 风格，便于后续替换为 Vivado IP。

当乘法输入被接受后，状态进入 `PE_S_WAIT_MUL`。

`PE_S_WAIT_MUL` 等待乘法器输出有效结果：

```text
mul_res = a_val * b_val
```

如果当前 merge 情况只需要乘法，则乘法结果就是最终 emit value；如果当前是同列累加，则还需要进入加法状态。

### 3.5 PE_S_START_ADD 与 PE_S_WAIT_ADD

`PE_S_START_ADD` 用于向 FP16 加法单元发起计算：

```text
buf_val + mul_res
```

当加法输入被接受后，状态进入 `PE_S_WAIT_ADD`。

`PE_S_WAIT_ADD` 等待加法器输出有效结果：

```text
add_res = buf_val + mul_res
```

该路径只在 `buf_col == b_col` 时出现。

### 3.6 PE_S_EMIT

`PE_S_EMIT` 负责输出一个 merge 后的元素：

```text
{emit_col, emit_val}
```

输出去向由 `is_final_merge` 决定。

如果：

```text
is_final_merge = 0
```

说明当前 A 行尚未结束，本轮输出只是中间 partial row，需要写入 PE 内部另一个 buffer：

```text
write_buffer[cCntr] = {emit_col, emit_val}
```

如果：

```text
is_final_merge = 1
```

说明当前 A 行已经全部处理完成，本轮输出是最终 C 行的一部分，需要输出到 result 通道：

```text
result_wr_data = {row_idx, emit_col, emit_val}
```

后续由 Store Module 或 testbench 写入：

```text
C[row_idx][emit_col]
```

### 3.7 PE_S_FINISH

`PE_S_FINISH` 表示当前 A scalar 对应的 B row 已经处理完，并且旧 partial row 的剩余元素也已经处理完成。

如果当前不是 final merge，则需要更新 PE 内部 partial buffer 状态：

```text
bufCntr <= cCntr
bufSel  <= ~bufSel
```

也就是将刚刚写入的 buffer 作为下一轮 merge 的旧 partial row。

如果当前是 final merge，则说明当前 C 行已经输出完成，需要清空 PE 内部 partial row 状态，准备处理下一行。

最终状态返回：

```text
PE_S_IDLE
```

---

## 4. 完成一次 MAC 的周期估计

这里的 MAC 指的是：

```text
buf_val + a_val * b_val
```

也就是当旧 partial row 和当前新 partial row 列号相等时，PE 需要完成一次乘法和一次加法。

对应状态路径为：

```text
PE_S_DECIDE
-> PE_S_START_MUL
-> PE_S_WAIT_MUL
-> PE_S_START_ADD
-> PE_S_WAIT_ADD
-> PE_S_EMIT
```

设：

```text
Lmul = FP16 乘法器从输入握手成功到输出 valid 的等待周期
Ladd = FP16 加法器从输入握手成功到输出 valid 的等待周期
```

那么从 `PE_S_DECIDE` 判断出需要 MAC 到 `PE_S_EMIT` 输出结果，周期数近似为：

```text
T_mac = Lmul + Ladd + 4
```

其中：

```text
1 cycle: PE_S_DECIDE
1 cycle: PE_S_START_MUL
Lmul cycles: PE_S_WAIT_MUL
1 cycle: PE_S_START_ADD
Ladd cycles: PE_S_WAIT_ADD
1 cycle: PE_S_EMIT
```

如果从 `PE_S_START_MUL` 开始计，不包括 `PE_S_DECIDE`，则：

```text
T_mac_from_start_mul = Lmul + Ladd + 3
```

不同 merge 情况下的周期估计如下：

| 情况                 | 计算内容                            | 状态路径                                                               | 周期估计              |
| ------------------ | ------------------------------- | ------------------------------------------------------------------ | ----------------- |
| `buf_col < b_col`  | 直接输出旧 partial row 元素            | `DECIDE -> EMIT`                                                   | 约 2 周期            |
| `buf_col > b_col`  | 只做乘法 `a_val * b_val`            | `DECIDE -> START_MUL -> WAIT_MUL -> EMIT`                          | `Lmul + 3`        |
| `buf_col == b_col` | 做 MAC `buf_val + a_val * b_val` | `DECIDE -> START_MUL -> WAIT_MUL -> START_ADD -> WAIT_ADD -> EMIT` | `Lmul + Ladd + 4` |
| 当前 merge 结束        | 更新 buffer 或清空状态                 | `FINISH`                                                           | 约 1 周期            |

当前 PE 是一个控制清晰的串行 merge-add PE。它的优点是结构简单、易于验证、易于定位问题；缺点是每个输出元素需要经过多个状态周期，吞吐率尚未达到 fully-pipelined。

后续若需要提高吞吐，可以考虑：

1. 将乘法、加法、emit 解耦成流水线；
2. 允许 PE 在等待 FP 运算结果时预取下一个 B entry；
3. 对 result 输出增加 FIFO 缓冲；
4. 将 partial buffer merge 逻辑改为更高吞吐的流水结构；
5. 对多个 PE 的 Store 结果进行多 bank 写回优化。

---

## 5. 当前阶段结论

当前工程已经完成了 PE 模块的基础验证环境，包括测试用例生成、自动化仿真、结果比对和可视化分析。testbench 能够模拟 Loader 行为，将 CSV-like A 数据和 CSR B 数据送入 PE，并将 PE 输出写入 dense C RAM。

当前验证重点是：

1. PE 对 QA/QB 输入握手是否正确；
2. PE 内部 partial row buffer 是否正确切换；
3. `buf_col < b_col`、`buf_col > b_col`、`buf_col == b_col` 三类 merge 情况是否正确；
4. `eor` 到来后结果是否输出到 result 通道；
5. C RAM 是否按 `row * N + col` 正确 dense 写回；
6. RTL 输出是否与 Python golden result 一致。

在 PE 局部验证稳定后，后续工程集成可以逐步将 testbench 中模拟的 Loader/Store 行为替换为真实 RTL 模块。
