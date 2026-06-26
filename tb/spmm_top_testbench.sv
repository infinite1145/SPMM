`timescale 1ns/1ps
`include "pe_defines.svh"

`ifndef PE_LANES
`define PE_LANES 4
`endif

`ifndef PE_A_INIT_FILE
`define PE_A_INIT_FILE ""
`endif

`ifndef PE_B_PTR_INIT_FILE
`define PE_B_PTR_INIT_FILE ""
`endif

`ifndef PE_B_ENT_INIT_FILE
`define PE_B_ENT_INIT_FILE ""
`endif

`ifndef PE_C_INIT_FILE
`define PE_C_INIT_FILE ""
`endif

module spmm_top_testbench;

    localparam int PE_LANES_P = `PE_LANES;
    localparam int DATA_W_P   = 16;
    localparam int IDX_W_P    = 16;

    localparam int A_ADDR_W_P     = 16;
    localparam int B_PTR_ADDR_W_P = 16;
    localparam int B_ENT_ADDR_W_P = 16;
    localparam int C_ADDR_W_P     = 18;

    localparam int C_DEPTH_P      = 512 * 512;
    localparam int FIFO_DEPTH_P   = 512;

    localparam int CLK_PERIOD = 10;
    localparam int TIMEOUT_CYCLES = 20_000_000;

    localparam string A_INIT_FILE_P     = `PE_A_INIT_FILE;
    localparam string B_PTR_INIT_FILE_P = `PE_B_PTR_INIT_FILE;
    localparam string B_ENT_INIT_FILE_P = `PE_B_ENT_INIT_FILE;
    localparam string C_INIT_FILE_P     = `PE_C_INIT_FILE;

    logic clk;
    logic rst_n;

    logic start;
    logic done;
    logic busy;

    logic [31:0] cycle_count;
    logic [31:0] compute_cycle_count;

    logic [IDX_W_P-1:0] cfg_m;
    logic [IDX_W_P-1:0] cfg_n;
    logic [31:0]        cfg_csv_vector_count;
    logic               cfg_csv_has_row_idx;

    logic                  dbg_c_en;
    logic [C_ADDR_W_P-1:0] dbg_c_addr;
    logic [DATA_W_P-1:0]   dbg_c_dout;

    string case_name;
    string result_file;
    string fsdb_file;

    int M_cfg;
    int N_cfg;
    int csv_vector_count_cfg;
    int csv_has_row_idx_cfg;

    int c_elems;

    // ============================================================
    // Clock / reset
    // ============================================================

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2) clk = ~clk;
    end

    initial begin
        rst_n = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
    end

    // ============================================================
    // DUT
    // ============================================================

    PE_SpMM_Top #(
        .PE_LANES       (PE_LANES_P),
        .DATA_W         (DATA_W_P),
        .IDX_W          (IDX_W_P),

        .A_ADDR_W       (A_ADDR_W_P),
        .A_DEPTH        (65536),

        .B_PTR_ADDR_W   (B_PTR_ADDR_W_P),
        .B_PTR_DEPTH    (65536),

        .B_ENT_ADDR_W   (B_ENT_ADDR_W_P),
        .B_ENT_DEPTH    (65536),

        .C_ADDR_W       (C_ADDR_W_P),
        .C_DEPTH        (C_DEPTH_P),

        .FIFO_DEPTH     (FIFO_DEPTH_P),

        .A_INIT_FILE     (A_INIT_FILE_P),
        .B_PTR_INIT_FILE (B_PTR_INIT_FILE_P),
        .B_ENT_INIT_FILE (B_ENT_INIT_FILE_P),
        .C_INIT_FILE     (C_INIT_FILE_P)
    ) u_dut (
        .clk                  (clk),
        .rst_n                (rst_n),

        .start                (start),

        .cfg_m                (cfg_m),
        .cfg_n                (cfg_n),
        .cfg_csv_vector_count (cfg_csv_vector_count),
        .cfg_csv_has_row_idx  (cfg_csv_has_row_idx),

        .done                 (done),
        .busy                 (busy),

        .cycle_count          (cycle_count),
        .compute_cycle_count  (compute_cycle_count),

        .dbg_c_en             (dbg_c_en),
        .dbg_c_addr           (dbg_c_addr),
        .dbg_c_dout           (dbg_c_dout)
    );

    // ============================================================
    // FSDB
    // ============================================================

    initial begin
        if (!$value$plusargs("FSDB_FILE=%s", fsdb_file)) begin
            fsdb_file = "spmm_top.fsdb";
        end

        #1;
        $fsdbDumpfile(fsdb_file);
        $fsdbDumpvars(0, spmm_top_testbench);
        $fsdbDumpMDA();
    end

    // ============================================================
    // Debug C RAM read
    // C RAM is synchronous read.
    // addr is sampled on posedge clk when dbg_c_en=1.
    // data is valid after that posedge.
    // ============================================================

    task automatic debug_read_c(
        input  int unsigned addr,
        output logic [DATA_W_P-1:0] data
    );
        begin
            @(negedge clk);
            dbg_c_en   = 1'b1;
            dbg_c_addr = addr[C_ADDR_W_P-1:0];

            @(posedge clk);
            #1;
            data = dbg_c_dout;

            @(negedge clk);
            dbg_c_en = 1'b0;
        end
    endtask

    task automatic dump_c_dense(input string path);
        int fp;
        int idx;
        logic [DATA_W_P-1:0] data;
        begin
            fp = $fopen(path, "w");

            if (fp == 0) begin
                $fatal(1, "[TB] Cannot open result file for write: %s", path);
            end

            for (idx = 0; idx < c_elems; idx = idx + 1) begin
                debug_read_c(idx, data);
                $fwrite(fp, "%04h\n", data);
            end

            $fclose(fp);

            $display("[TB] Dense C dumped to %s", path);
            $display("[TB] Dense C format: line_idx = row * N + col");
            $display("[TB] C elements = %0d", c_elems);
        end
    endtask

    // ============================================================
    // Main
    // ============================================================

    initial begin
        start = 1'b0;

        dbg_c_en   = 1'b0;
        dbg_c_addr = '0;

        if (!$value$plusargs("CASE=%s", case_name)) begin
            case_name = "default";
        end

        if (!$value$plusargs("RESULT_FILE=%s", result_file)) begin
            result_file = {"test_result/res_", case_name, ".hex"};
        end

        if (!$value$plusargs("M=%d", M_cfg)) begin
            $fatal(1, "[TB] Missing +M=<rows>");
        end

        if (!$value$plusargs("N=%d", N_cfg)) begin
            $fatal(1, "[TB] Missing +N=<cols>");
        end

        if (!$value$plusargs("CSV_VECTOR_COUNT=%d", csv_vector_count_cfg)) begin
            $fatal(1, "[TB] Missing +CSV_VECTOR_COUNT=<count>");
        end

        if (!$value$plusargs("CSV_HAS_ROW_IDX=%d", csv_has_row_idx_cfg)) begin
            csv_has_row_idx_cfg = 0;
        end

        c_elems = M_cfg * N_cfg;

        if (c_elems > C_DEPTH_P) begin
            $fatal(1, "[TB] C elements %0d exceeds C_DEPTH_P %0d", c_elems, C_DEPTH_P);
        end

        cfg_m                = M_cfg[IDX_W_P-1:0];
        cfg_n                = N_cfg[IDX_W_P-1:0];
        cfg_csv_vector_count = csv_vector_count_cfg;
        cfg_csv_has_row_idx  = csv_has_row_idx_cfg[0];

        $display("[TB] CASE              = %s", case_name);
        $display("[TB] M                 = %0d", M_cfg);
        $display("[TB] N                 = %0d", N_cfg);
        $display("[TB] CSV_VECTOR_COUNT  = %0d", csv_vector_count_cfg);
        $display("[TB] CSV_HAS_ROW_IDX   = %0d", csv_has_row_idx_cfg);
        $display("[TB] RESULT_FILE       = %s", result_file);
        $display("[TB] FSDB_FILE         = %s", fsdb_file);
        $display("[TB] A_INIT_FILE       = %s", A_INIT_FILE_P);
        $display("[TB] B_PTR_INIT_FILE   = %s", B_PTR_INIT_FILE_P);
        $display("[TB] B_ENT_INIT_FILE   = %s", B_ENT_INIT_FILE_P);

        wait (rst_n === 1'b1);
        repeat (10) @(posedge clk);

        @(negedge clk);
        start = 1'b1;

        wait (done === 1'b1);

        $display("[TB] DUT done.");
        $display("[TB] cycle_count         = %0d", cycle_count);
        $display("[TB] compute_cycle_count = %0d", compute_cycle_count);

        @(negedge clk);
        start = 1'b0;

        repeat (10) @(posedge clk);

        dump_c_dense(result_file);

        $display("[TB] Simulation finished.");
        #100;
        $finish;
    end

    // ============================================================
    // Timeout
    // ============================================================

    initial begin
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $fatal(1, "[TB] Global timeout at time %0t", $time);
    end

endmodule