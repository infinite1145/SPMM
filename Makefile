# ============================================================
# Makefile for pe_framework infrastructure
# ============================================================

ROOT_DIR    := $(abspath .)
SRC_DIR     := $(ROOT_DIR)/src
INC_DIR     := $(SRC_DIR)/inc
TB_DIR      := $(ROOT_DIR)/tb
TOOLS_DIR   := $(ROOT_DIR)/tools
CASE_DIR    := $(ROOT_DIR)/testcases
RESULT_DIR  := $(ROOT_DIR)/test_result
CHECK_DIR   := $(ROOT_DIR)/check_result
VIS_DIR     := $(ROOT_DIR)/visual_result
BUILD_DIR   := $(ROOT_DIR)/build_dir

# Top-level integrated testbench
TOP_TB      := spmm_top_testbench
TB_FILE     := $(TB_DIR)/$(TOP_TB).sv
FILELIST    := $(BUILD_DIR)/filelist.f
SIMV        := $(BUILD_DIR)/simv

PYTHON      ?= python3
GEN_PY      := $(TOOLS_DIR)/gen_matrix.py
CHECK_PY    := $(TOOLS_DIR)/check_result.py
VIS_PY      := $(TOOLS_DIR)/visualize.py
REORDER_PY  := $(TOOLS_DIR)/reorder.py

# ============================================================
# User-facing variables
# ============================================================

CASE        ?= default

# These are only used by make gen.
M           ?= 16
N           ?= 16
K           ?= 16
SEED        ?= 1
SPARSITY    ?= 0.3

# Fixed 64PE version.
# Do not override this unless all RTL/A-vector format is changed together.
PE_LANES    := 64

REORDER     ?= greedy

# For row reorder, this should be 1 so C is written back in original row order.
CSV_HAS_ROW_IDX ?= 1

# 64PE fixed A vector format:
# word0 + valid_mask[31:0] + valid_mask[63:32]
#       + eor_mask[31:0] + eor_mask[63:32]
#       + 64 lane words
CSV_WORDS_PER_VECTOR_64 := 69
CSV_VECTOR_WIDTH_64     := 2208

# ============================================================
# Case paths
# ============================================================

CASE_PATH   := $(CASE_DIR)/$(CASE)
CASE_CONFIG := $(CASE_PATH)/config.json

RESULT_HEX  := $(RESULT_DIR)/res_$(CASE).hex
GOLDEN_HEX  := $(CASE_PATH)/golden_c.hex
CHECK_JSON  := $(CHECK_DIR)/$(CASE)_check.json

A_ORIG_HEX   := $(CASE_PATH)/a_original_dense.hex
A_REORD_HEX  := $(CASE_PATH)/a_dense.hex
B_HEX        := $(CASE_PATH)/b_dense.hex
GOLDEN_C_HEX := $(CASE_PATH)/golden_c.hex

# Vector-wide A ROM init file
A_CSV_VEC_HEX := $(CASE_PATH)/a_csv_vec.hex
B_PTR_HEX     := $(CASE_PATH)/b_csr_row_ptr.hex
B_ENT_HEX     := $(CASE_PATH)/b_csr_entry.hex

FSDB        ?= spmm_top.fsdb
FSDB_PATH   := $(ROOT_DIR)/$(FSDB)

# ============================================================
# Read generated testcase config if it exists
# For make gen, config may not exist yet, so fallback to command-line defaults.
# For make test/check/vis, config should exist and will be used automatically.
# PE_LANES is fixed to 64 in this RTL branch.
# ============================================================

CONFIG_EXISTS := $(wildcard $(CASE_CONFIG))

ifeq ($(CONFIG_EXISTS),)
RUN_M        := $(M)
RUN_N        := $(N)
RUN_K        := $(K)
RUN_PE_LANES := 64
RUN_CSV_HAS_ROW_IDX := $(CSV_HAS_ROW_IDX)
RUN_CSV_VECTOR_COUNT := 0
else
RUN_M := $(shell $(PYTHON) -c 'import json; d=json.load(open("$(CASE_CONFIG)")); print(d.get("M", d.get("m")))')
RUN_N := $(shell $(PYTHON) -c 'import json; d=json.load(open("$(CASE_CONFIG)")); print(d.get("N", d.get("n")))')
RUN_K := $(shell $(PYTHON) -c 'import json; d=json.load(open("$(CASE_CONFIG)")); print(d.get("K", d.get("k")))')
RUN_PE_LANES := 64
RUN_CSV_HAS_ROW_IDX := $(shell $(PYTHON) -c 'import json; d=json.load(open("$(CASE_CONFIG)")); print(d.get("CSV_HAS_ROW_IDX", d.get("csv_has_row_idx", $(CSV_HAS_ROW_IDX))))')
RUN_CSV_VECTOR_COUNT := $(shell $(PYTHON) -c 'import json; d=json.load(open("$(CASE_CONFIG)")); print(d.get("csv_vector_count", d.get("CSV_VECTOR_COUNT", 0)))')
endif

# ============================================================
# VCS
# ============================================================

VCS         ?= vcs

VCS_FLAGS   := -full64 \
               -sverilog \
               -timescale=1ns/1ps \
               -debug_access+all \
               -kdb \
               +v2k \
               -LDFLAGS \
               -Wl,--no-as-needed \
               +incdir+$(INC_DIR) \
               -Mdir=$(BUILD_DIR)/csrc \
               +lint=TFIPC-L \
               -o $(SIMV)

# Fixed 64PE compile-time define.
VCS_FLAGS += +define+PE_LANES=64

# ROM/RAM init files for integrated top.
VCS_FLAGS += +define+PE_A_INIT_FILE=\"$(A_CSV_VEC_HEX)\"
VCS_FLAGS += +define+PE_B_PTR_INIT_FILE=\"$(B_PTR_HEX)\"
VCS_FLAGS += +define+PE_B_ENT_INIT_FILE=\"$(B_ENT_HEX)\"
VCS_FLAGS += +define+PE_C_INIT_FILE=\"\"

ifneq ($(VERDI_HOME),)
VCS_FLAGS += -P $(VERDI_HOME)/share/PLI/VCS/LINUX64/novas.tab \
                $(VERDI_HOME)/share/PLI/VCS/LINUX64/pli.a
else ifneq ($(NOVAS_HOME),)
VCS_FLAGS += -P $(NOVAS_HOME)/share/PLI/VCS/LINUX64/novas.tab \
                $(NOVAS_HOME)/share/PLI/VCS/LINUX64/pli.a
endif

SIM_PLUSARGS := +CASE=$(CASE) \
                +CASE_DIR=$(CASE_PATH) \
                +RESULT_FILE=$(RESULT_HEX) \
                +FSDB_FILE=$(FSDB_PATH) \
                +M=$(RUN_M) \
                +N=$(RUN_N) \
                +PE_LANES=64 \
                +CSV_HAS_ROW_IDX=$(RUN_CSV_HAS_ROW_IDX) \
                +CSV_VECTOR_COUNT=$(RUN_CSV_VECTOR_COUNT)

# K is not passed by default.
# TOP/TB do not need K directly. B row range is encoded by b_csr_row_ptr.hex.

# ============================================================
# Targets
# ============================================================

.PHONY: all
all: test

.PHONY: dirs
dirs:
	@mkdir -p $(CASE_DIR) $(RESULT_DIR) $(CHECK_DIR) $(VIS_DIR) $(BUILD_DIR)

# Generate testcase only. Does not compile or run simulation.
.PHONY: gen
gen: dirs
	$(PYTHON) $(GEN_PY) \
		--out_dir $(CASE_DIR) \
		--case $(CASE) \
		--seed $(SEED) \
		--M $(M) --N $(N) --K $(K) \
		--sparsity $(SPARSITY) \
		--pe_lanes 64 \
		--reorder $(REORDER) \
		--csv_has_row_idx $(CSV_HAS_ROW_IDX)

# Re-run row reordering report for an existing testcase.
.PHONY: reorder
reorder:
	@test -f $(CASE_CONFIG) || (echo "[REORDER][ERR] Missing config: $(CASE_CONFIG)" && exit 1)
	$(PYTHON) $(REORDER_PY) --case_dir $(CASE_PATH) --pe_lanes 64

.PHONY: filelist
filelist: dirs
	@rm -f $(FILELIST)
	@find $(SRC_DIR) -name "*.sv" | sort >> $(FILELIST)
	@echo "$(TB_FILE)" >> $(FILELIST)
	@cat $(FILELIST)

.PHONY: check_case64
check_case64:
	@test -f $(CASE_CONFIG) || (echo "[CASE64][ERR] Missing config: $(CASE_CONFIG). Run make gen CASE=$(CASE) first." && exit 1)
	@$(PYTHON) -c 'import json,sys; d=json.load(open("$(CASE_CONFIG)")); pe=int(d.get("PE_LANES", d.get("pe_lanes", -1))); wpv=int(d.get("csv_words_per_vector", -1)); width=int(d.get("csv_vector_width", -1)); ok=(pe==64 and wpv==69 and width==2208); print("[CASE64] PE_LANES=%s csv_words_per_vector=%s csv_vector_width=%s" % (pe, wpv, width)); sys.exit(0 if ok else 1)' || (echo "[CASE64][ERR] This testcase is not generated for fixed 64PE format. Regenerate with: make gen CASE=$(CASE) M=$(M) N=$(N) K=$(K)" && exit 1)

.PHONY: compile
compile: filelist check_case64
	@test -f $(A_CSV_VEC_HEX) || (echo "[COMPILE][ERR] Missing vector CSV: $(A_CSV_VEC_HEX). Regenerate testcase with updated gen_matrix.py." && exit 1)
	@test -f $(B_PTR_HEX) || (echo "[COMPILE][ERR] Missing B row_ptr: $(B_PTR_HEX)" && exit 1)
	@test -f $(B_ENT_HEX) || (echo "[COMPILE][ERR] Missing B entry: $(B_ENT_HEX)" && exit 1)
	$(VCS) $(VCS_FLAGS) -f $(FILELIST) -top $(TOP_TB) -l $(BUILD_DIR)/compile.log

# Run existing testcase only. Does not generate testcase.
.PHONY: test run
test run: compile
	@test -f $(CASE_CONFIG) || (echo "[SIM][ERR] Missing config: $(CASE_CONFIG). Run make gen CASE=$(CASE) first." && exit 1)
	@mkdir -p $(RESULT_DIR)
	@rm -f $(RESULT_HEX) $(FSDB_PATH)
	cd $(ROOT_DIR) && $(SIMV) $(SIM_PLUSARGS) -l $(BUILD_DIR)/sim_$(CASE).log
	@echo "[SIM] result: $(RESULT_HEX)"
	@echo "[SIM] fsdb  : $(FSDB_PATH)"

.PHONY: check
check:
	@test -f $(CASE_CONFIG) || (echo "[CHECK][ERR] Missing config: $(CASE_CONFIG)" && exit 1)
	@test -f $(GOLDEN_HEX)  || (echo "[CHECK][ERR] Missing golden: $(GOLDEN_HEX)" && exit 1)
	@test -f $(RESULT_HEX)  || (echo "[CHECK][ERR] Missing result: $(RESULT_HEX)" && exit 1)
	@mkdir -p $(CHECK_DIR)
	$(PYTHON) $(CHECK_PY) \
		--golden $(GOLDEN_HEX) \
		--result $(RESULT_HEX) \
		--out $(CHECK_JSON) \
		--mode bit

.PHONY: vis_case
vis_case:
	@test -f $(CASE_CONFIG)  || (echo "[VIS][ERR] Missing config: $(CASE_CONFIG)" && exit 1)
	@test -f $(A_ORIG_HEX)   || (echo "[VIS][ERR] Missing original A: $(A_ORIG_HEX)" && exit 1)
	@test -f $(A_REORD_HEX)  || (echo "[VIS][ERR] Missing reordered A: $(A_REORD_HEX)" && exit 1)
	@test -f $(B_HEX)        || (echo "[VIS][ERR] Missing B: $(B_HEX)" && exit 1)
	@test -f $(GOLDEN_C_HEX) || (echo "[VIS][ERR] Missing golden C: $(GOLDEN_C_HEX)" && exit 1)
	@mkdir -p $(VIS_DIR)/$(CASE)

	$(PYTHON) $(VIS_PY) \
		--case $(CASE) \
		--input $(A_ORIG_HEX) \
		--config $(CASE_CONFIG) \
		--matrix A \
		--mode value \
		--out_dir $(VIS_DIR) \
		--title "$(CASE): original A value"

	$(PYTHON) $(VIS_PY) \
		--case $(CASE) \
		--input $(A_ORIG_HEX) \
		--config $(CASE_CONFIG) \
		--matrix A \
		--mode nonzero \
		--out_dir $(VIS_DIR) \
		--title "$(CASE): original A nonzero"

	$(PYTHON) $(VIS_PY) \
		--case $(CASE) \
		--input $(A_REORD_HEX) \
		--config $(CASE_CONFIG) \
		--matrix A \
		--mode value \
		--out_dir $(VIS_DIR) \
		--title "$(CASE): reordered A value"

	$(PYTHON) $(VIS_PY) \
		--case $(CASE) \
		--input $(A_REORD_HEX) \
		--config $(CASE_CONFIG) \
		--matrix A \
		--mode nonzero \
		--out_dir $(VIS_DIR) \
		--title "$(CASE): reordered A nonzero"

	$(PYTHON) $(VIS_PY) \
		--case $(CASE) \
		--input $(B_HEX) \
		--config $(CASE_CONFIG) \
		--matrix B \
		--mode value \
		--out_dir $(VIS_DIR) \
		--title "$(CASE): B value"

	$(PYTHON) $(VIS_PY) \
		--case $(CASE) \
		--input $(B_HEX) \
		--config $(CASE_CONFIG) \
		--matrix B \
		--mode nonzero \
		--out_dir $(VIS_DIR) \
		--title "$(CASE): B nonzero"

	$(PYTHON) $(VIS_PY) \
		--case $(CASE) \
		--input $(GOLDEN_C_HEX) \
		--config $(CASE_CONFIG) \
		--matrix C \
		--mode value \
		--out_dir $(VIS_DIR) \
		--title "$(CASE): golden C value"

	$(PYTHON) $(VIS_PY) \
		--case $(CASE) \
		--input $(GOLDEN_C_HEX) \
		--config $(CASE_CONFIG) \
		--matrix C \
		--mode nonzero \
		--out_dir $(VIS_DIR) \
		--title "$(CASE): golden C nonzero"

.PHONY: vis_result
vis_result:
	@test -f $(CASE_CONFIG)  || (echo "[VIS][ERR] Missing config: $(CASE_CONFIG)" && exit 1)
	@test -f $(RESULT_HEX)   || (echo "[VIS][ERR] Missing result: $(RESULT_HEX)" && exit 1)
	@test -f $(GOLDEN_C_HEX) || (echo "[VIS][ERR] Missing golden C: $(GOLDEN_C_HEX)" && exit 1)
	@mkdir -p $(VIS_DIR)/$(CASE)

	$(PYTHON) $(VIS_PY) \
		--case $(CASE) \
		--input $(RESULT_HEX) \
		--config $(CASE_CONFIG) \
		--matrix C \
		--mode value \
		--out_dir $(VIS_DIR) \
		--title "$(CASE): RTL result C value"

	$(PYTHON) $(VIS_PY) \
		--case $(CASE) \
		--input $(RESULT_HEX) \
		--config $(CASE_CONFIG) \
		--matrix C \
		--mode nonzero \
		--out_dir $(VIS_DIR) \
		--title "$(CASE): RTL result C nonzero"

	$(PYTHON) $(VIS_PY) \
		--case $(CASE) \
		--golden $(GOLDEN_C_HEX) \
		--result $(RESULT_HEX) \
		--config $(CASE_CONFIG) \
		--matrix C \
		--mode diff \
		--out_dir $(VIS_DIR) \
		--title "$(CASE): abs diff (result vs golden)"

.PHONY: vis_all
vis_all: vis_case vis_result

# Use recursive make so gen_test can read the newly-generated config.
.PHONY: gen_test
gen_test:
	$(MAKE) gen CASE=$(CASE) M=$(M) N=$(N) K=$(K) SEED=$(SEED) SPARSITY=$(SPARSITY) REORDER=$(REORDER) CSV_HAS_ROW_IDX=$(CSV_HAS_ROW_IDX)
	$(MAKE) test CASE=$(CASE)
	$(MAKE) check CASE=$(CASE)
	$(MAKE) vis_all CASE=$(CASE)

.PHONY: wave
wave: filelist
	verdi -sv +incdir+$(INC_DIR) -f $(FILELIST) -top $(TOP_TB) -ssf $(FSDB_PATH) &

.PHONY: clean
clean:
	rm -rf $(BUILD_DIR)
	rm -f $(FSDB_PATH)
	rm -rf novas.* verdiLog *.key *.log ucli.key vc_hdrs.h

.PHONY: clean_data
clean_data:
	rm -rf $(CASE_DIR) $(RESULT_DIR) $(CHECK_DIR) $(VIS_DIR)

.PHONY: clean_all
clean_all: clean clean_data

.PHONY: help
help:
	@echo "Targets:"
	@echo "  make gen CASE=xxx M=16 N=16 K=16"
	@echo "      Generate fixed-64PE testcase only"
	@echo "  make test CASE=xxx"
	@echo "      Compile and run integrated SpMM TOP, dimensions read from config.json"
	@echo "  make check CASE=xxx"
	@echo "      Compare result with golden"
	@echo "  make vis_case CASE=xxx"
	@echo "      Visualize original A / reordered A / B / golden C"
	@echo "  make vis_result CASE=xxx"
	@echo "      Visualize RTL result and diff"
	@echo "  make vis_all CASE=xxx"
	@echo "      vis_case + vis_result"
	@echo "  make gen_test CASE=xxx M=16 N=16 K=16"
	@echo "      gen -> test -> check -> vis_all"
	@echo "  make wave"
	@echo "      Open FSDB with Verdi"