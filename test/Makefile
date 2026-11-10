# Makefile

# defaults
FLOW ?= sv
SIM ?= icarus
# Use the more efficient FST waveform format with Icarus.
FST ?= -fst
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(CURDIR)/../src
SIM_OUTPUTS = $(abspath $(CURDIR)/../sim_outputs)
WAVEFORM_EXT = $(if $(strip $(FST)),fst,vcd)
export PYTHONDONTWRITEBYTECODE := 1
PROJECT_SOURCES = project.v modules/RM_IHPSG13_1P_64x16_c2.sv
SRAM_MODEL_SOURCES = $(CURDIR)/ihp_sram/RM_IHPSG13_1P_core_behavioral.v $(CURDIR)/ihp_sram/RM_IHPSG13_1P_64x16_c2.v
MODULE_DIR = $(CURDIR)/modules
MODULE_NAMES = $(patsubst tb_%.sv,%,$(notdir $(wildcard $(MODULE_DIR)/tb_*.sv)))
MODULE_SIM_TARGETS = $(addprefix sim_tb_,$(MODULE_NAMES))
MODULE_COCOTB_NAMES = $(filter $(MODULE_NAMES),$(patsubst test_%.py,%,$(notdir $(wildcard $(MODULE_DIR)/test_*.py))))
MODULE_COCOTB_TARGETS = $(addprefix cocotb_tb_,$(MODULE_COCOTB_NAMES))
SM_SUBMODULE_SOURCES = $(addprefix $(SRC_DIR)/modules/,decode.sv isr.sv osr.sv regfile.sv clockdiv.sv program_counter.sv)
SM_SIM_EXES = $(addprefix $(SIM_OUTPUTS)/modules/sv/,$(addsuffix .$(WAVEFORM_EXT).vvp,sm sm_no_smx_instr))

# Integration tests wire several modules together. Glue RTL lives in
# src/integration/ and testbenches in test/integration/. Both src/modules/ and
# src/integration/ are Icarus library directories (-y), so any module whose
# file is named <module>.sv is found without listing it.
INT_SRC_DIR = $(SRC_DIR)/integration
INT_DIR = $(CURDIR)/integration
RTL_LIB_ARGS = -y $(SRC_DIR)/modules -y $(INT_SRC_DIR) -Y .sv -I$(SRC_DIR)/modules -I$(INT_SRC_DIR)
RTL_LIB_SOURCES = $(wildcard $(SRC_DIR)/modules/*.sv) $(wildcard $(INT_SRC_DIR)/*.sv)
INT_NAMES = $(patsubst tb_%.sv,%,$(notdir $(wildcard $(INT_DIR)/tb_*.sv)))
INT_SIM_TARGETS = $(addprefix sim_int_,$(INT_NAMES))
INT_COCOTB_NAMES = $(filter $(INT_NAMES),$(patsubst test_%.py,%,$(notdir $(wildcard $(INT_DIR)/test_*.py))))
INT_COCOTB_TARGETS = $(addprefix cocotb_int_,$(INT_COCOTB_NAMES))

.DEFAULT_GOAL := all
.PHONY: all $(MODULE_SIM_TARGETS) $(MODULE_COCOTB_TARGETS) $(INT_SIM_TARGETS) $(INT_COCOTB_TARGETS)

# A module simulation runs each time it is requested, but recompiles only when
# its testbench or DUT changes.
$(MODULE_SIM_TARGETS): sim_tb_%: $(SIM_OUTPUTS)/modules/sv/%.$(WAVEFORM_EXT).vvp
	vvp $< $(FST)

$(SIM_OUTPUTS)/modules/sv/%.$(WAVEFORM_EXT).vvp: $(MODULE_DIR)/tb_%.sv $(SRC_DIR)/modules/%.sv
	mkdir -p $(@D)
	iverilog -g2012 -DSV_TEST -DTB_DUMPFILE=\"$(SIM_OUTPUTS)/modules/sv/$*.$(WAVEFORM_EXT)\" -s tb_$* -o $@ $^

# Both state-machine variants instantiate these shared submodules.
$(SM_SIM_EXES): $(SIM_OUTPUTS)/modules/sv/%.$(WAVEFORM_EXT).vvp: $(MODULE_DIR)/tb_%.sv $(SRC_DIR)/modules/%.sv $(SM_SUBMODULE_SOURCES)
	mkdir -p $(@D)
	iverilog -g2012 -DSV_TEST -DTB_DUMPFILE=\"$(SIM_OUTPUTS)/modules/sv/$*.$(WAVEFORM_EXT)\" -s tb_$* -o $@ $^

# Use the vendor functional view for SRAM tests; the RTL file is a synthesis stub.
$(SIM_OUTPUTS)/modules/sv/ihp_sram.$(WAVEFORM_EXT).vvp: $(MODULE_DIR)/tb_ihp_sram.sv $(SRAM_MODEL_SOURCES)
	mkdir -p $(@D)
	iverilog -g2012 -DSV_TEST -DFUNCTIONAL -DTB_DUMPFILE=\"$(SIM_OUTPUTS)/modules/sv/ihp_sram.$(WAVEFORM_EXT)\" -s tb_ihp_sram -o $@ $^

# An integration simulation compiles only its testbench; every module it
# instantiates is pulled from the library directories. It recompiles when the
# testbench or any file in src/modules/ or src/integration/ changes.
$(INT_SIM_TARGETS): sim_int_%: $(SIM_OUTPUTS)/integration/sv/%.$(WAVEFORM_EXT).vvp
	vvp $< $(FST)

$(SIM_OUTPUTS)/integration/sv/%.$(WAVEFORM_EXT).vvp: $(INT_DIR)/tb_%.sv $(RTL_LIB_SOURCES)
	mkdir -p $(@D)
	iverilog -g2012 -DSV_TEST -DTB_DUMPFILE=\"$(SIM_OUTPUTS)/integration/sv/$*.$(WAVEFORM_EXT)\" $(RTL_LIB_ARGS) -s tb_$* -o $@ $<

$(INT_COCOTB_TARGETS): cocotb_int_%:
	$(MAKE) --no-print-directory FLOW=cocotb INTEGRATION_NAME=$* sim
	test -f $(SIM_OUTPUTS)/integration/cocotb/$*/results.xml
	! grep -q failure $(SIM_OUTPUTS)/integration/cocotb/$*/results.xml

$(MODULE_COCOTB_TARGETS): cocotb_tb_%:
	$(MAKE) --no-print-directory FLOW=cocotb MODULE_NAME=$* sim
	test -f $(SIM_OUTPUTS)/modules/cocotb/$*/results.xml
	! grep -q failure $(SIM_OUTPUTS)/modules/cocotb/$*/results.xml

ifneq ($(MODULE_NAME),)

# A module cocotb run gets its own top level, Python test, and build directory.
SIM_BUILD = $(SIM_OUTPUTS)/modules/cocotb/$(MODULE_NAME)
VERILOG_SOURCES = $(SRC_DIR)/modules/$(MODULE_NAME).sv $(MODULE_DIR)/tb_$(MODULE_NAME).sv
TOPLEVEL = tb_$(MODULE_NAME)
COCOTB_TEST_MODULES = test_$(MODULE_NAME)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml
COMPILE_ARGS += -DTB_DUMPFILE=\"$(SIM_BUILD)/tb.$(WAVEFORM_EXT)\"
export PYTHONPATH := $(MODULE_DIR):$(PYTHONPATH)

else ifneq ($(INTEGRATION_NAME),)

# An integration cocotb run: the testbench is the top level and the modules it
# uses come from the library directories.
SIM_BUILD = $(SIM_OUTPUTS)/integration/cocotb/$(INTEGRATION_NAME)
VERILOG_SOURCES = $(INT_DIR)/tb_$(INTEGRATION_NAME).sv
TOPLEVEL = tb_$(INTEGRATION_NAME)
COCOTB_TEST_MODULES = test_$(INTEGRATION_NAME)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml
COMPILE_ARGS += $(RTL_LIB_ARGS)
COMPILE_ARGS += -DTB_DUMPFILE=\"$(SIM_BUILD)/tb.$(WAVEFORM_EXT)\"
export PYTHONPATH := $(INT_DIR):$(PYTHONPATH)

else

ifneq ($(GATES),yes)

# RTL simulation:
SIM_BUILD				= $(SIM_OUTPUTS)/rtl/cocotb
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
VERILOG_SOURCES += $(SRAM_MODEL_SOURCES)
COMPILE_ARGS += -DFUNCTIONAL

else

# Gate level simulation:
SIM_BUILD				= $(SIM_OUTPUTS)/gl/cocotb
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DSIM
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13g2/libs.ref/sg13g2_io/verilog/sg13g2_io.v
VERILOG_SOURCES += $(PDK_ROOT)/ihp-sg13g2/libs.ref/sg13g2_stdcell/verilog/sg13g2_stdcell.v

# this gets copied in by the GDS action workflow
VERILOG_SOURCES += $(CURDIR)/gate_level_netlist.v
VERILOG_SOURCES += $(SRAM_MODEL_SOURCES)

endif

# Allow sharing configuration between design and testbench via `include`:
COMPILE_ARGS 		+= -I$(SRC_DIR)

# Include the testbench sources:
VERILOG_SOURCES += $(CURDIR)/tb.v
TOPLEVEL = tb
COCOTB_TEST_MODULES = test
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

ifeq ($(FLOW),sv)
SIM_BUILD := $(patsubst %/cocotb,%/sv,$(SIM_BUILD))
endif

COMPILE_ARGS += -DTB_DUMPFILE=\"$(SIM_BUILD)/tb.$(WAVEFORM_EXT)\"

endif

ifeq ($(FLOW),sv)

# Compile the stimulus in tb.v only for the SystemVerilog flow.
SV_BUILD = $(SIM_BUILD)
SV_EXE = $(SV_BUILD)/sim.$(WAVEFORM_EXT).vvp

all: $(MODULE_SIM_TARGETS) $(INT_SIM_TARGETS) $(SV_EXE)
	vvp $(SV_EXE) $(FST)

$(SV_EXE): $(VERILOG_SOURCES)
	mkdir -p $(SV_BUILD)
	iverilog -g2012 -s $(TOPLEVEL) -o $@ -DSV_TEST $(COMPILE_ARGS) $(VERILOG_SOURCES)

else ifeq ($(FLOW),cocotb)

ifeq ($(MODULE_NAME)$(INTEGRATION_NAME),)
all: $(MODULE_COCOTB_TARGETS) $(INT_COCOTB_TARGETS) sim
else
all: sim
endif

# include cocotb's make rules to take care of the simulator setup
# Direct sim_tb_* and sim_int_* targets need only Icarus, so skip cocotb when
# those are the only requested goals.
ifeq ($(strip $(MAKECMDGOALS)),)
include $(shell cocotb-config --makefiles)/Makefile.sim
else ifneq ($(filter-out sim_tb_% sim_int_%,$(MAKECMDGOALS)),)
include $(shell cocotb-config --makefiles)/Makefile.sim
endif

else
$(error Unsupported FLOW '$(FLOW)'; use cocotb or sv)
endif
