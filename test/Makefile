# Makefile

# defaults
FLOW ?= cocotb
SIM ?= icarus
# Use the more efficient FST waveform format with Icarus.
FST ?= -fst
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(CURDIR)/../src
SIM_OUTPUTS = $(abspath $(CURDIR)/../sim_outputs)
WAVEFORM_EXT = $(if $(strip $(FST)),fst,vcd)
export PYTHONDONTWRITEBYTECODE := 1
PROJECT_SOURCES = project.v
MODULE_DIR = $(CURDIR)/modules
MODULE_NAMES = $(patsubst tb_%.sv,%,$(notdir $(wildcard $(MODULE_DIR)/tb_*.sv)))
MODULE_SIM_TARGETS = $(addprefix sim_tb_,$(MODULE_NAMES))
MODULE_COCOTB_NAMES = $(filter $(MODULE_NAMES),$(patsubst test_%.py,%,$(notdir $(wildcard $(MODULE_DIR)/test_*.py))))
MODULE_COCOTB_TARGETS = $(addprefix cocotb_tb_,$(MODULE_COCOTB_NAMES))

.DEFAULT_GOAL := all
.PHONY: all $(MODULE_SIM_TARGETS) $(MODULE_COCOTB_TARGETS)

# A module simulation runs each time it is requested, but recompiles only when
# its testbench or DUT changes.
$(MODULE_SIM_TARGETS): sim_tb_%: $(SIM_OUTPUTS)/modules/sv/%.$(WAVEFORM_EXT).vvp
	vvp $< $(FST)

$(SIM_OUTPUTS)/modules/sv/%.$(WAVEFORM_EXT).vvp: $(MODULE_DIR)/tb_%.sv $(SRC_DIR)/modules/%.sv
	mkdir -p $(@D)
	iverilog -g2012 -DSV_TEST -DTB_DUMPFILE=\"$(SIM_OUTPUTS)/modules/sv/$*.$(WAVEFORM_EXT)\" -s tb_$* -o $@ $^

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

else

ifneq ($(GATES),yes)

# RTL simulation:
SIM_BUILD				= $(SIM_OUTPUTS)/rtl/cocotb
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))

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
SV_EXE = $(SV_BUILD)/sim.vvp

all: $(MODULE_SIM_TARGETS) $(SV_EXE)
	vvp $(SV_EXE) $(FST)

$(SV_EXE): $(VERILOG_SOURCES)
	mkdir -p $(SV_BUILD)
	iverilog -g2012 -s $(TOPLEVEL) -o $@ -DSV_TEST $(COMPILE_ARGS) $(VERILOG_SOURCES)

else ifeq ($(FLOW),cocotb)

ifeq ($(MODULE_NAME),)
all: $(MODULE_SIM_TARGETS) $(MODULE_COCOTB_TARGETS) sim
else
all: sim
endif

# include cocotb's make rules to take care of the simulator setup
# Direct sim_tb_* targets need only Icarus, so skip cocotb when those are
# the only requested goals.
ifeq ($(strip $(MAKECMDGOALS)),)
include $(shell cocotb-config --makefiles)/Makefile.sim
else ifneq ($(filter-out sim_tb_%,$(MAKECMDGOALS)),)
include $(shell cocotb-config --makefiles)/Makefile.sim
endif

else
$(error Unsupported FLOW '$(FLOW)'; use cocotb or sv)
endif
