`ifndef PE_DEFINES_SVH
`define PE_DEFINES_SVH

// -----------------------------------------------------------------------------
// PE common macro definitions.
// All macro names start with PE_ to avoid collision with other project files.
// -----------------------------------------------------------------------------

`define PE_DATA_W             16
`define PE_IDX_W              16
`define PE_ENTRY_W            (`PE_IDX_W + `PE_DATA_W)
`define PE_RESULT_W           (`PE_IDX_W + `PE_IDX_W + `PE_DATA_W)

`define PE_BUF_DEPTH          512
`define PE_RESULT_FIFO_DEPTH  128

// -----------------------------------------------------------------------------
// Fixed 64PE configuration.
//
// Current RTL branch uses fixed 64PE CSV vector format:
//   word0          = {row_base[15:0], k[15:0]}
//   word1          = valid_mask[31:0]
//   word2          = valid_mask[63:32]
//   word3          = eor_mask[31:0]
//   word4          = eor_mask[63:32]
//   word5~word68   = lane_word[0]~lane_word[63]
//
// Therefore PE_LANES must be 64.
// -----------------------------------------------------------------------------

`ifndef PE_LANES
`define PE_LANES              64
`endif

// Legacy project macro. Keep it consistent with fixed 64PE flow.
`ifndef PE_PE_LANES
`define PE_PE_LANES           64
`endif

`define PE_CSV_MASK_WORDS     2
`define PE_CSV_WORDS_PER_VEC  69
`define PE_CSV_VECTOR_W       (32 * `PE_CSV_WORDS_PER_VEC)

// Testbench memory limits. These are simulation infrastructure macros.
`ifndef PE_TB_MAX_CSV_WORDS
`define PE_TB_MAX_CSV_WORDS   1048576
`endif

`ifndef PE_TB_MAX_ROW_PTR
`define PE_TB_MAX_ROW_PTR     4096
`endif

`ifndef PE_TB_MAX_B_ENTRIES
`define PE_TB_MAX_B_ENTRIES   1048576
`endif

`ifndef PE_TB_MAX_C_ELEMS
`define PE_TB_MAX_C_ELEMS     1048576
`endif

`ifndef PE_TB_TIMEOUT_CYCLES
`define PE_TB_TIMEOUT_CYCLES  20000000
`endif

// Optional RTL switches. Keep undefined by default.
// Define PE_USE_XILINX_FP_MUL_IP or PE_USE_XILINX_FP_ADD_IP in the compile flow
// if replacing behavioral FP wrappers with Vivado Floating-Point IP instances.

`endif // PE_DEFINES_SVH