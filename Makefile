# Shortcuts for the open-source flow (GHDL, Yosys, Python).
#
#   make test               run all testbenches + Python checks (the one to remember)
#   make sim  TB=<name>     run one testbench, e.g. TB=tb_sha256_double
#   make wave TB=<name>     same, and save build/<name>.ghw for a waveform viewer
#   make synth              synthesis check + rough resource estimate (Yosys)
#   make docs               regenerate the figures in docs/img
#   make clean              delete build/
#
# All output goes to build/ (ignored by git).

GHDL   ?= $(shell command -v ghdl 2>/dev/null || echo $(HOME)/.local/opt/ghdl/bin/ghdl)
YOSYS  ?= yosys
PYTHON ?= python3
STD    := --std=08
BUILD  := build
GFLAGS := $(STD) --workdir=$(BUILD)

# Design files, in compile order
RTL := rtl/sha256_core.vhd \
       rtl/sha256_single.vhd \
       rtl/sha256_double.vhd \
       rtl/uart_rx.vhd \
       rtl/uart_tx.vhd \
       rtl/sha256_uart_top.vhd

TB_SRC := tb/tb_sha256_single.vhd \
          tb/tb_sha256_double.vhd \
          tb/tb_sha256_uart_top.vhd

TBS        := $(basename $(notdir $(TB_SRC)))
SYNTH_TOPS := sha256_core sha256_single sha256_double sha256_uart_top

.PHONY: test sim wave synth docs analyze pycheck clean

# ---- simulation -------------------------------------------------------------

test: analyze
	@fail=0; for tb in $(TBS); do \
	  $(MAKE) --no-print-directory sim TB=$$tb || fail=1; \
	done; \
	$(MAKE) --no-print-directory pycheck || fail=1; \
	if [ $$fail -eq 0 ]; then echo "== ALL CHECKS PASSED"; else echo "== SOME CHECKS FAILED"; exit 1; fi

$(BUILD):
	@mkdir -p $(BUILD)

# Compile all VHDL
analyze: | $(BUILD)
	@$(GHDL) -a $(GFLAGS) $(RTL) $(TB_SRC)

# Elaborate + run one testbench; it passes only if it prints "RESULT <tb>: PASS"
sim: analyze
	@echo "== $(TB)"
	@$(GHDL) -e $(GFLAGS) -Wl,-w -o $(BUILD)/$(TB) $(TB)
	@cd $(BUILD) && ./$(TB) --stop-time=100ms > $(TB).log 2>&1; rc=$$?; \
	  sed -E 's/^.*\(report (note|error|failure)\): //' $(TB).log; \
	  [ $$rc -eq 0 ] && grep -q "^.*RESULT $(TB): PASS" $(TB).log

wave: analyze
	@$(GHDL) -e $(GFLAGS) -Wl,-w -o $(BUILD)/$(TB) $(TB)
	@cd $(BUILD) && ./$(TB) --stop-time=100ms --wave=$(TB).ghw > /dev/null
	@echo "Waveform: $(BUILD)/$(TB).ghw (open with Surfer or GTKWave)"

# Expected values vs hashlib, and the host script against its software model
pycheck:
	@echo "== python cross-check"
	@$(PYTHON) scripts/check_vectors.py
	@echo "== host script against software model"
	@$(PYTHON) host/sha256_uart.py --fake selftest --count 3

# ---- synthesis check (no timing) ---------------------------------------------

synth: | $(BUILD)
	@for top in $(SYNTH_TOPS); do \
	  $(GHDL) --synth $(STD) --out=verilog $(RTL) -e $$top > $(BUILD)/$$top.v 2> $(BUILD)/$$top.ghdl.log || { cat $(BUILD)/$$top.ghdl.log; exit 1; }; \
	  $(YOSYS) -q -p "read_verilog $(BUILD)/$$top.v; synth_xilinx -top $$top -family xc7 -flatten; tee -o $(BUILD)/$$top.stat stat" > /dev/null || exit 1; \
	  echo "== $$top (Yosys synth_xilinx estimate)"; \
	  grep -E "^ +[0-9]+ +(LUT[1-6]|FDRE|FDSE|CARRY4|MUXF[78]|IBUF|OBUF)" $(BUILD)/$$top.stat; \
	done

# ---- figures -------------------------------------------------------------------

# Simulate with only the listed signals recorded, then draw a time window as SVG.
# $(1)=testbench $(2)=stop time $(3)=name $(4)=from ns $(5)=to ns $(6)=title $(7)=signals
define render_wave
	@printf '%s\n' $(foreach s,$(7),$(firstword $(subst :, ,$(s)))) > $(BUILD)/$(3).opt
	@cd $(BUILD) && ./$(1) --stop-time=$(2) --read-wave-opt=$(3).opt --wave=$(3).ghw > /dev/null 2>&1 || true
	@$(PYTHON) scripts/wave_svg.py $(BUILD)/$(3).ghw docs/img/$(3).svg --from $(4) --to $(5) --title $(6) $(7)
endef

S := /tb_sha256_single
D := /tb_sha256_double
U := /tb_sha256_uart_top

docs: analyze
	@mkdir -p docs/img
	@for tb in $(TBS); do $(GHDL) -e $(GFLAGS) -Wl,-w -o $(BUILD)/$$tb $$tb; done
	$(call render_wave,tb_sha256_single,1500ns,wave_single,40,1340,"sha256_single: hashing 'abc' (start to done = 118 cycles at 10 ns)",\
	  $(S)/start $(S)/dut/state:wrapper.state $(S)/dut/core_start:core.start $(S)/dut/sha256_inst/state:core.state \
	  $(S)/dut/sha256_inst/round_counter:core.round_counter $(S)/dut/sha256_inst/a:core.a $(S)/dut/core_done:core.done \
	  $(S)/done $(S)/hash_out)
	$(call render_wave,tb_sha256_double,4000ns,wave_double,40,3680,"sha256_double: three core passes for one 80-byte header (352 cycles at 10 ns)",\
	  $(D)/start $(D)/dut/state:wrapper.state $(D)/dut/core_rst:core.rst $(D)/dut/core_start:core.start \
	  $(D)/dut/core_use_custom_init:core.use_custom_init $(D)/dut/sha256_inst/state:core.state $(D)/dut/core_done:core.done \
	  $(D)/first_hash $(D)/done $(D)/hash_out)
	$(call render_wave,tb_sha256_uart_top,3500us,wave_uart,0,3450000,"sha256_uart_top: 'S' 0x03 'abc' in then 'K' + 32-byte digest out (115200 baud at 50 MHz)",\
	  $(U)/rx_line:uart_rx $(U)/dut/state:top.state $(U)/dut/single_start:single.start $(U)/dut/single_done:single.done \
	  $(U)/tx_line:uart_tx $(U)/led:led[3:0])

clean:
	rm -rf $(BUILD)
