`timescale 1ns/1ps
`include "pe_defines.svh"

`ifndef PE_LANES
`define PE_LANES 4
`endif

`ifndef PE_DATA_W
`define PE_DATA_W 16
`endif

`ifndef PE_IDX_W
`define PE_IDX_W 16
`endif

`ifndef PE_RESULT_W
`define PE_RESULT_W (`PE_IDX_W + `PE_IDX_W + `PE_DATA_W)
`endif

module pe_array_testbench;

    // ============================================================
    // Compile-time parameters
    // ============================================================

    localparam int PE_LANES_P        = `PE_LANES;
    localparam int PE_DATA_W_P       = `PE_DATA_W;
    localparam int PE_IDX_W_P        = `PE_IDX_W;
    localparam int PE_RESULT_W_P     = `PE_RESULT_W;

    localparam int PE_CLK_PERIOD     = 10;

    localparam int PE_MAX_A_CSV_WORDS   = 1 << 20;
    localparam int PE_MAX_B_ROW_PTR     = 4096;
    localparam int PE_MAX_B_ENTRY_WORDS = 1 << 20;
    localparam int PE_MAX_C_ELEMS       = 512 * 512;

    localparam int PE_TIMEOUT_CYCLES    = 200000000;

    initial begin
        if (PE_LANES_P > 16) begin
            $fatal(1, "[TB] PE_LANES_P=%0d is too large. Current CSV mask format supports at most 16 lanes.", PE_LANES_P);
        end
    end

    // ============================================================
    // Clock / reset
    // ============================================================

    logic clk;
    logic rst_n;

    initial begin
        clk = 1'b0;
        forever #(PE_CLK_PERIOD/2) clk = ~clk;
    end

    initial begin
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
    end

    // ============================================================
    // Plusargs and file paths
    // ============================================================

    string case_name;
    string case_dir;
    string result_file;
    string fsdb_file;

    string a_csv_file;
    string b_row_ptr_file;
    string b_entry_file;

    int M_cfg;
    int N_cfg;
    int K_cfg;
    int pe_lanes_arg;

    bit m_arg_valid;
    bit n_arg_valid;
    bit k_arg_valid;
    bit csv_has_row_idx;

    logic tb_files_loaded;

    // ============================================================
    // Hex memories
    // ============================================================

    logic [31:0] a_csv_mem     [0:PE_MAX_A_CSV_WORDS-1];
    logic [31:0] b_row_ptr_mem [0:PE_MAX_B_ROW_PTR-1];
    logic [31:0] b_entry_mem   [0:PE_MAX_B_ENTRY_WORDS-1];

    // Dense C RAM:
    // addr = row * N_cfg + col
    // one element per address, FP16 by default
    logic [PE_DATA_W_P-1:0] c_ram [0:PE_MAX_C_ELEMS-1];

    int a_csv_word_count;
    int b_row_ptr_word_count;
    int b_entry_word_count;

    int csv_words_per_vector;
    int csv_vector_count;
    int c_elems;

    // ============================================================
    // Utility: count valid hex words in a file
    // ============================================================

    function automatic int count_hex_words(input string path);
        int fd;
        int ret;
        int cnt;
        string line;
        logic [31:0] tmp;

        begin
            cnt = 0;
            fd = $fopen(path, "r");

            if (fd == 0) begin
                $fatal(1, "[TB] Cannot open hex file: %s", path);
            end

            while (!$feof(fd)) begin
                line = "";
                ret = $fgets(line, fd);

                if (ret != 0) begin
                    if ($sscanf(line, "%h", tmp) == 1) begin
                        cnt++;
                    end
                end
            end

            $fclose(fd);
            return cnt;
        end
    endfunction

    // ============================================================
    // Dump dense C RAM
    //
    // Output format:
    //   dense row-major
    //   one FP16 hex per line
    //
    //   line 0       -> C[0][0]
    //   line 1       -> C[0][1]
    //   ...
    //   line N-1     -> C[0][N-1]
    //   line N       -> C[1][0]
    //   ...
    //
    // No sparse compression.
    // No omission of zero elements.
    // ============================================================

    task automatic dump_c_ram_dense(input string path);
        int fp;
        int idx;
        begin
            fp = $fopen(path, "w");

            if (fp == 0) begin
                $fatal(1, "[TB] Cannot open result file for write: %s", path);
            end

            for (idx = 0; idx < c_elems; idx = idx + 1) begin
                if (PE_DATA_W_P == 16) begin
                    $fwrite(fp, "%04h\n", c_ram[idx]);
                end else if (PE_DATA_W_P == 32) begin
                    $fwrite(fp, "%08h\n", c_ram[idx]);
                end else begin
                    $fwrite(fp, "%h\n", c_ram[idx]);
                end
            end

            $fclose(fp);

            $display("[TB] Dense C RAM dumped to %s", path);
            $display("[TB] Dense C format: line_idx = row * N + col");
            $display("[TB] Dense C elements: M * N = %0d", c_elems);
        end
    endtask

    // ============================================================
    // Parse plusargs and load hex files
    // ============================================================

    initial begin
        tb_files_loaded = 1'b0;

        if (!$value$plusargs("CASE=%s", case_name)) begin
            case_name = "default";
        end

        if (!$value$plusargs("CASE_DIR=%s", case_dir)) begin
            case_dir = {"testcases/", case_name};
        end

        if (!$value$plusargs("RESULT_FILE=%s", result_file)) begin
            result_file = {"test_result/res_", case_name, ".hex"};
        end

        if (!$value$plusargs("FSDB_FILE=%s", fsdb_file)) begin
            fsdb_file = "pe_array.fsdb";
        end

        m_arg_valid = $value$plusargs("M=%d", M_cfg);
        n_arg_valid = $value$plusargs("N=%d", N_cfg);
        k_arg_valid = $value$plusargs("K=%d", K_cfg);

        if (!m_arg_valid) begin
            $fatal(1, "[TB] Missing +M=<rows>. Dense C output needs exact M.");
        end

        if (!n_arg_valid) begin
            $fatal(1, "[TB] Missing +N=<cols>. Dense C output needs exact N.");
        end

        if (!$value$plusargs("CSV_HAS_ROW_IDX=%d", csv_has_row_idx)) begin
            csv_has_row_idx = 1'b0;
        end

        if ($value$plusargs("PE_LANES=%d", pe_lanes_arg)) begin
            if (pe_lanes_arg != PE_LANES_P) begin
                $fatal(1,
                    "[TB] Runtime PE_LANES=%0d does not match compile-time PE_LANES_P=%0d. Recompile with +define+PE_LANES=%0d.",
                    pe_lanes_arg,
                    PE_LANES_P,
                    pe_lanes_arg
                );
            end
        end

        a_csv_file      = {case_dir, "/a_csv.hex"};
        b_row_ptr_file  = {case_dir, "/b_csr_row_ptr.hex"};
        b_entry_file    = {case_dir, "/b_csr_entry.hex"};

        csv_words_per_vector = 2 + PE_LANES_P;

        a_csv_word_count     = count_hex_words(a_csv_file);
        b_row_ptr_word_count = count_hex_words(b_row_ptr_file);
        b_entry_word_count   = count_hex_words(b_entry_file);

        if (a_csv_word_count == 0) begin
            $fatal(1, "[TB] A CSV file is empty: %s", a_csv_file);
        end

        if ((a_csv_word_count % csv_words_per_vector) != 0) begin
            $fatal(1,
                "[TB] Invalid A CSV word count. words=%0d, words_per_vector=%0d, file=%s",
                a_csv_word_count,
                csv_words_per_vector,
                a_csv_file
            );
        end

        csv_vector_count = a_csv_word_count / csv_words_per_vector;

        if (b_row_ptr_word_count < 2) begin
            $fatal(1,
                "[TB] Invalid B row_ptr file. word_count=%0d, file=%s",
                b_row_ptr_word_count,
                b_row_ptr_file
            );
        end

        // Important:
        // K is inferred from b_csr_row_ptr.hex.
        // CSR row_ptr length must be K + 1.
        if (k_arg_valid && (K_cfg != (b_row_ptr_word_count - 1))) begin
            $display(
                "[TB][WARN] Plusarg K=%0d does not match B row_ptr file. File implies K=%0d. TB will use file-inferred K.",
                K_cfg,
                b_row_ptr_word_count - 1
            );
        end

        K_cfg = b_row_ptr_word_count - 1;

        c_elems = M_cfg * N_cfg;

        if (c_elems > PE_MAX_C_ELEMS) begin
            $fatal(1,
                "[TB] C elements %0d exceeds PE_MAX_C_ELEMS %0d.",
                c_elems,
                PE_MAX_C_ELEMS
            );
        end

        if (a_csv_word_count > PE_MAX_A_CSV_WORDS) begin
            $fatal(1,
                "[TB] A CSV words %0d exceeds PE_MAX_A_CSV_WORDS %0d.",
                a_csv_word_count,
                PE_MAX_A_CSV_WORDS
            );
        end

        if (b_row_ptr_word_count > PE_MAX_B_ROW_PTR) begin
            $fatal(1,
                "[TB] B row_ptr words %0d exceeds PE_MAX_B_ROW_PTR %0d.",
                b_row_ptr_word_count,
                PE_MAX_B_ROW_PTR
            );
        end

        if (b_entry_word_count > PE_MAX_B_ENTRY_WORDS) begin
            $fatal(1,
                "[TB] B entry words %0d exceeds PE_MAX_B_ENTRY_WORDS %0d.",
                b_entry_word_count,
                PE_MAX_B_ENTRY_WORDS
            );
        end

        $readmemh(a_csv_file,     a_csv_mem,     0, a_csv_word_count-1);
        $readmemh(b_row_ptr_file, b_row_ptr_mem, 0, b_row_ptr_word_count-1);

        if (b_entry_word_count > 0) begin
            $readmemh(b_entry_file, b_entry_mem, 0, b_entry_word_count-1);
        end

        $display("[TB] CASE              = %s", case_name);
        $display("[TB] CASE_DIR          = %s", case_dir);
        $display("[TB] RESULT_FILE       = %s", result_file);
        $display("[TB] FSDB_FILE         = %s", fsdb_file);
        $display("[TB] M=%0d N=%0d K=%0d PE_LANES=%0d", M_cfg, N_cfg, K_cfg, PE_LANES_P);
        $display("[TB] CSV_HAS_ROW_IDX   = %0d", csv_has_row_idx);
        $display("[TB] A_CSV             = %s", a_csv_file);
        $display("[TB] B_ROW_PTR         = %s", b_row_ptr_file);
        $display("[TB] B_ENTRY           = %s", b_entry_file);
        $display("[TB] A_CSV_WORD_COUNT  = %0d", a_csv_word_count);
        $display("[TB] CSV_WORDS_PER_VEC = %0d", csv_words_per_vector);
        $display("[TB] CSV_VECTOR_COUNT  = %0d", csv_vector_count);
        $display("[TB] B_ROW_PTR_WORDS   = %0d", b_row_ptr_word_count);
        $display("[TB] B_ENTRY_WORDS     = %0d", b_entry_word_count);
        $display("[TB] C_ELEMS           = %0d", c_elems);
        $display("[TB] Dense result file = %s", result_file);

        tb_files_loaded = 1'b1;
    end

    // ============================================================
    // FSDB
    // ============================================================

    initial begin
        #1;
        $fsdbDumpfile(fsdb_file);
        $fsdbDumpvars(0, pe_array_testbench);
        $fsdbDumpMDA();
    end

    // ============================================================
    // PE array interface
    // ============================================================

    logic [PE_LANES_P-1:0] qa_valid;
    logic [PE_LANES_P-1:0] qa_ready;
    logic [PE_LANES_P-1:0][PE_IDX_W_P-1:0]  qa_row_idx;
    logic [PE_LANES_P-1:0][PE_DATA_W_P-1:0] qa_val;
    logic [PE_LANES_P-1:0] qa_eor;

    logic [PE_LANES_P-1:0] qb_valid;
    logic [PE_LANES_P-1:0] qb_ready;
    logic [PE_LANES_P-1:0][PE_IDX_W_P-1:0]  qb_col_idx;
    logic [PE_LANES_P-1:0][PE_DATA_W_P-1:0] qb_val;
    logic [PE_LANES_P-1:0] qb_last;
    logic [PE_LANES_P-1:0] qb_empty;

    logic [PE_LANES_P-1:0] qb_busy;
    logic [PE_LANES_P-1:0] pe_round_done;
    logic [PE_LANES_P-1:0] pe_error;

    logic [PE_LANES_P-1:0] result_wr_en;
    logic [PE_LANES_P-1:0][PE_RESULT_W_P-1:0] result_wr_data;
    logic [PE_LANES_P-1:0] result_full;

    assign result_full = '0;

    genvar pe_g;
    generate
        for (pe_g = 0; pe_g < PE_LANES_P; pe_g = pe_g + 1) begin : GEN_PE
            PE_Core u_pe_core (
                .clk            (clk),
                .rst_n          (rst_n),

                .qa_valid       (qa_valid[pe_g]),
                .qa_ready       (qa_ready[pe_g]),
                .qa_row_idx     (qa_row_idx[pe_g]),
                .qa_val         (qa_val[pe_g]),
                .qa_eor         (qa_eor[pe_g]),

                .qb_valid       (qb_valid[pe_g]),
                .qb_ready       (qb_ready[pe_g]),
                .qb_col_idx     (qb_col_idx[pe_g]),
                .qb_val         (qb_val[pe_g]),
                .qb_last        (qb_last[pe_g]),
                .qb_empty       (qb_empty[pe_g]),

                .result_wr_en   (result_wr_en[pe_g]),
                .result_wr_data (result_wr_data[pe_g]),
                .result_full    (result_full[pe_g]),

                .pe_busy        (qb_busy[pe_g]),
                .pe_round_done  (pe_round_done[pe_g]),
                .pe_error       (pe_error[pe_g])
            );
        end
    endgenerate

    // ============================================================
    // Result unpacking
    // result_wr_data = {row_idx, col_idx, value}
    // ============================================================

    logic [PE_LANES_P-1:0][PE_IDX_W_P-1:0]  result_row;
    logic [PE_LANES_P-1:0][PE_IDX_W_P-1:0]  result_col;
    logic [PE_LANES_P-1:0][PE_DATA_W_P-1:0] result_val;
    logic [PE_LANES_P-1:0][31:0]            result_addr;

    generate
        for (pe_g = 0; pe_g < PE_LANES_P; pe_g = pe_g + 1) begin : GEN_RESULT_UNPACK
            assign result_row[pe_g] = result_wr_data[pe_g][PE_RESULT_W_P-1 -: PE_IDX_W_P];
            assign result_col[pe_g] = result_wr_data[pe_g][PE_DATA_W_P + PE_IDX_W_P - 1 -: PE_IDX_W_P];
            assign result_val[pe_g] = result_wr_data[pe_g][PE_DATA_W_P-1:0];

            assign result_addr[pe_g] = result_row[pe_g] * N_cfg + result_col[pe_g];
        end
    endgenerate

    // ============================================================
    // C RAM write
    // Dense storage:
    //   c_ram[row * N_cfg + col] = value
    // ============================================================

    integer c_init_i;
    integer c_wr_p;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (c_init_i = 0; c_init_i < PE_MAX_C_ELEMS; c_init_i = c_init_i + 1) begin
                c_ram[c_init_i] <= '0;
            end
        end else begin
            for (c_wr_p = 0; c_wr_p < PE_LANES_P; c_wr_p = c_wr_p + 1) begin
                if (result_wr_en[c_wr_p]) begin
                    if (result_row[c_wr_p] >= M_cfg || result_col[c_wr_p] >= N_cfg) begin
                        $fatal(1,
                            "[TB] Result index out of range. pe=%0d row=%0d col=%0d M=%0d N=%0d time=%0t",
                            c_wr_p,
                            result_row[c_wr_p],
                            result_col[c_wr_p],
                            M_cfg,
                            N_cfg,
                            $time
                        );
                    end

                    if (result_addr[c_wr_p] >= c_elems) begin
                        $fatal(1,
                            "[TB] C write address out of range. pe=%0d addr=%0d c_elems=%0d time=%0t",
                            c_wr_p,
                            result_addr[c_wr_p],
                            c_elems,
                            $time
                        );
                    end

                    c_ram[result_addr[c_wr_p]] <= result_val[c_wr_p];
                end
            end
        end
    end

    // ============================================================
    // Driver utilities
    // ============================================================

    task automatic clear_inputs();
        int p;
        begin
            for (p = 0; p < PE_LANES_P; p = p + 1) begin
                qa_valid[p]   = 1'b0;
                qa_row_idx[p] = '0;
                qa_val[p]     = '0;
                qa_eor[p]     = 1'b0;

                qb_valid[p]   = 1'b0;
                qb_col_idx[p] = '0;
                qb_val[p]     = '0;
                qb_last[p]    = 1'b0;
                qb_empty[p]   = 1'b0;
            end
        end
    endtask

    task automatic wait_pe_ready(input logic [PE_LANES_P-1:0] active_mask);
        int timeout;
        bit all_ready;
        int p;
        begin
            timeout = 0;
            do begin
                @(posedge clk);
                all_ready = 1'b1;

                for (p = 0; p < PE_LANES_P; p = p + 1) begin
                    if (active_mask[p] && !qa_ready[p]) begin
                        all_ready = 1'b0;
                    end
                end

                timeout++;

                if (timeout > PE_TIMEOUT_CYCLES) begin
                    $fatal(1, "[TB] Timeout waiting PE ready. active_mask=%h time=%0t", active_mask, $time);
                end
            end while (!all_ready);
        end
    endtask

    task automatic send_qa_vector(
        input logic [PE_LANES_P-1:0] active_mask,
        input logic [PE_LANES_P-1:0] eor_mask,
        input logic [PE_LANES_P-1:0][PE_IDX_W_P-1:0] row_idx_lanes,
        input logic [PE_LANES_P-1:0][PE_DATA_W_P-1:0] a_val_lanes
    );
        logic [PE_LANES_P-1:0] accepted;
        int p;
        int timeout;
        begin
            accepted = '0;
            timeout  = 0;

            @(negedge clk);

            for (p = 0; p < PE_LANES_P; p = p + 1) begin
                qa_row_idx[p] = row_idx_lanes[p];
                qa_val[p]     = a_val_lanes[p];
                qa_eor[p]     = eor_mask[p];
                qa_valid[p]   = active_mask[p];
            end

            while ((accepted & active_mask) != active_mask) begin
                @(posedge clk);

                for (p = 0; p < PE_LANES_P; p = p + 1) begin
                    if (qa_valid[p] && qa_ready[p]) begin
                        accepted[p] = 1'b1;
                    end
                end

                @(negedge clk);

                for (p = 0; p < PE_LANES_P; p = p + 1) begin
                    qa_valid[p] = active_mask[p] && !accepted[p];
                end

                timeout++;

                if (timeout > PE_TIMEOUT_CYCLES) begin
                    $fatal(1, "[TB] Timeout sending QA vector. active_mask=%h time=%0t", active_mask, $time);
                end
            end

            @(negedge clk);
            for (p = 0; p < PE_LANES_P; p = p + 1) begin
                qa_valid[p] = 1'b0;
            end
        end
    endtask

    task automatic send_b_entry_to_active_pes(
        input logic [PE_LANES_P-1:0] active_mask,
        input logic [PE_IDX_W_P-1:0] b_col,
        input logic [PE_DATA_W_P-1:0] b_data,
        input logic b_is_last,
        input logic b_is_empty
    );
        logic [PE_LANES_P-1:0] accepted;
        int p;
        int timeout;
        begin
            accepted = '0;
            timeout  = 0;

            @(negedge clk);

            for (p = 0; p < PE_LANES_P; p = p + 1) begin
                qb_col_idx[p] = b_col;
                qb_val[p]     = b_data;
                qb_last[p]    = b_is_last;
                qb_empty[p]   = b_is_empty;
                qb_valid[p]   = active_mask[p];
            end

            while ((accepted & active_mask) != active_mask) begin
                @(posedge clk);

                for (p = 0; p < PE_LANES_P; p = p + 1) begin
                    if (qb_valid[p] && qb_ready[p]) begin
                        accepted[p] = 1'b1;
                    end
                end

                @(negedge clk);

                for (p = 0; p < PE_LANES_P; p = p + 1) begin
                    qb_valid[p] = active_mask[p] && !accepted[p];
                end

                timeout++;

                if (timeout > PE_TIMEOUT_CYCLES) begin
                    $fatal(1, "[TB] Timeout sending B entry. active_mask=%h time=%0t", active_mask, $time);
                end
            end

            @(negedge clk);
            for (p = 0; p < PE_LANES_P; p = p + 1) begin
                qb_valid[p] = 1'b0;
                qb_last[p]  = 1'b0;
                qb_empty[p] = 1'b0;
            end
        end
    endtask

    task automatic send_b_row(
        input logic [PE_LANES_P-1:0] active_mask,
        input int k
    );
        int start_ptr;
        int end_ptr;
        int q;
        logic [31:0] entry;
        logic [PE_IDX_W_P-1:0] b_col;
        logic [PE_DATA_W_P-1:0] b_val;
        begin
            if (k < 0 || k >= K_cfg) begin
                $fatal(1, "[TB] Invalid B row index k=%0d, K=%0d time=%0t", k, K_cfg, $time);
            end

            start_ptr = b_row_ptr_mem[k];
            end_ptr   = b_row_ptr_mem[k+1];

            if (start_ptr > end_ptr) begin
                $fatal(1, "[TB] Invalid B row_ptr. k=%0d start=%0d end=%0d", k, start_ptr, end_ptr);
            end

            if (end_ptr > b_entry_word_count) begin
                $fatal(1, "[TB] B row range exceeds entry count. k=%0d end=%0d entry_count=%0d", k, end_ptr, b_entry_word_count);
            end

            if (start_ptr == end_ptr) begin
                send_b_entry_to_active_pes(active_mask, '0, '0, 1'b1, 1'b1);
            end else begin
                for (q = start_ptr; q < end_ptr; q = q + 1) begin
                    entry = b_entry_mem[q];
                    b_col = entry[31:16];
                    b_val = entry[15:0];

                    send_b_entry_to_active_pes(
                        active_mask,
                        b_col,
                        b_val,
                        (q == end_ptr - 1),
                        1'b0
                    );
                end
            end
        end
    endtask

    // ============================================================
    // Main simulation flow
    // ============================================================

    int vec_i;
    int base_word;

    logic [31:0] word0;
    logic [31:0] word1;

    logic [PE_IDX_W_P-1:0] row_base;
    logic [PE_IDX_W_P-1:0] k_idx;

    logic [PE_LANES_P-1:0] valid_mask;
    logic [PE_LANES_P-1:0] eor_mask;
    logic [PE_LANES_P-1:0][PE_IDX_W_P-1:0]  row_idx_lanes;
    logic [PE_LANES_P-1:0][PE_DATA_W_P-1:0] a_val_lanes;

    int lane_i;
    int drain_i;

    initial begin
        clear_inputs();

        wait (tb_files_loaded === 1'b1);
        wait (rst_n === 1'b1);
        repeat (5) @(posedge clk);

        for (vec_i = 0; vec_i < csv_vector_count; vec_i = vec_i + 1) begin
            base_word = vec_i * csv_words_per_vector;

            word0 = a_csv_mem[base_word + 0];
            word1 = a_csv_mem[base_word + 1];

            row_base   = word0[31:16];
            k_idx      = word0[15:0];

            valid_mask = word1[0 +: PE_LANES_P];
            eor_mask   = word1[16 +: PE_LANES_P];

            for (lane_i = 0; lane_i < PE_LANES_P; lane_i = lane_i + 1) begin
                a_val_lanes[lane_i] = a_csv_mem[base_word + 2 + lane_i][15:0];

                if (csv_has_row_idx) begin
                    row_idx_lanes[lane_i] = a_csv_mem[base_word + 2 + lane_i][31:16];
                end else begin
                    row_idx_lanes[lane_i] = row_base + lane_i[PE_IDX_W_P-1:0];
                end
            end

            $display("[TB] Vector %0d/%0d row_base=%0d k=%0d valid=%h eor=%h time=%0t",
                vec_i,
                csv_vector_count,
                row_base,
                k_idx,
                valid_mask,
                eor_mask,
                $time
            );

            if (valid_mask != '0) begin
                wait_pe_ready(valid_mask);
                send_qa_vector(valid_mask, eor_mask, row_idx_lanes, a_val_lanes);
                send_b_row(valid_mask, k_idx);
                wait_pe_ready(valid_mask);
            end
        end

        for (drain_i = 0; drain_i < 100; drain_i = drain_i + 1) begin
            @(posedge clk);
        end

        $display("[TB] Writing dense C RAM result to %s", result_file);
        dump_c_ram_dense(result_file);

        $display("[TB] Simulation done.");
        #100;
        $finish;
    end

    // ============================================================
    // Global timeout
    // ============================================================

    initial begin
        repeat (PE_TIMEOUT_CYCLES) @(posedge clk);
        $fatal(1, "[TB] Global timeout at time %0t", $time);
    end
    initial begin
        #1000000000;
        $finish;
    end
endmodule