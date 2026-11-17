# Common Catapult flow for the L0 blocks (mod_red_<algo>, mod_mul_<algo>).
#
# Run through hls/l0/tcl/run_cfg.sh, which sets the environment variables
# below, creates hls/l0/run/<tag>/ and starts "catapult -shell -file" there.
#
#   HLS_BLOCK    mod_red_barrett | mod_red_mont12 | ... | mod_mul_k2red
#                (source file hls/l0/src/<HLS_BLOCK>.cpp)
#   HLS_LIB      fpga  : Xilinx Zynq-7000 speed -1, part xc7z020clg400-1
#                asic  : Nangate 45 nm open cell library (Catapult sample lib)
#   HLS_CFG      c0    : combinational (latency 0). Top is a combinational
#                        bottom-up CCORE: no clock, no register.
#                p1    : sequential CCORE, II = 1, latency 1 requested
#                p2    : sequential CCORE, II = 1, latency 2 requested
#   HLS_CLK_NS   clock period in ns (used for scheduling; c0 uses it as the
#                timing budget of the combinational path)
#   HLS_TOP      top-level module name (unique per configuration), passed to
#                the C++ source as -DHLS_TOP
#   HLS_CONST_MULTS  optional, OPT_CONST_MULTS value (default full).
#                full turns every constant multiplication into shift-add,
#                which keeps the structure of the golden model (SHIFTADD,
#                K2RED and the MONT12 quotient digit are multiplier-free).
#                With use_library the Zynq library maps constant products,
#                including the recognized shift-add folds, to DSP blocks.
#
# Downstream RTL synthesis is never run: no "flow run" of Vivado / DC /
# RTL Compiler / Oasys, CHARACTERIZE_OPERATOR stays off, and the Ultra
# datapath estimation that calls an embedded synthesis engine
# (ADVANCED_DPOPT) is disabled. All area and timing numbers are Catapult
# library-based estimates.

proc env_or_die {name} {
  if {![info exists ::env($name)] || $::env($name) eq ""} {
    puts "HLS_FLOW_ERROR: environment variable $name not set"
    exit 2
  }
  return $::env($name)
}

set BLOCK [env_or_die HLS_BLOCK]
set LIB   [env_or_die HLS_LIB]
set CFG   [env_or_die HLS_CFG]
set CLK   [env_or_die HLS_CLK_NS]
set TOP   [env_or_die HLS_TOP]
set CONST_MULTS full
if {[info exists ::env(HLS_CONST_MULTS)] && $::env(HLS_CONST_MULTS) ne ""} {
  set CONST_MULTS $::env(HLS_CONST_MULTS)
}

set TCL_DIR [file normalize [file dirname [info script]]]
set HLS_DIR [file dirname $TCL_DIR]
set SRC     $HLS_DIR/src/$BLOCK.cpp
set INC     $HLS_DIR/include

puts "HLS_FLOW_CONFIG: block=$BLOCK lib=$LIB cfg=$CFG clk_ns=$CLK top=$TOP const_mults=$CONST_MULTS"

options defaults
options set Input/CppStandard c++17
options set Input/CompilerFlags "-DHLS_TOP=$TOP"
options set Input/SearchPath $INC -append
options set Output/OutputVHDL false
options set Output/OutputVerilog true
# Unique names for every sub-block and copied static file, so that several
# configurations of one block can be compiled into one simulation library.
options set Output/SubBlockNamePrefix ${TOP}_
options set Output/PackageOutput true
options set Output/PackageStaticFiles true
options set Output/PrefixStaticFiles true

project new -name $TOP

# Concatenated netlist (concat_rtl.v) for the simulation flow.
flow package require /Concat

solution file add $SRC -type C++
go analyze

switch -- $CFG {
  c0      { solution design set $TOP -top -ccore -combinational }
  p1 - p2 { solution design set $TOP -top -ccore -sequential }
  default { puts "HLS_FLOW_ERROR: unknown HLS_CFG $CFG"; exit 2 }
}
directive set -OPT_CONST_MULTS $CONST_MULTS
go compile

switch -- $LIB {
  fpga {
    solution library add mgc_Xilinx-ZYNQ-1_beh -- -rtlsyntool Vivado -manufacturer Xilinx \
        -family ZYNQ -speed -1 -part xc7z020clg400-1
  }
  asic {
    solution library add nangate-45nm_beh -- -rtlsyntool DesignCompiler -vendor Nangate \
        -technology 045nm
  }
  default { puts "HLS_FLOW_ERROR: unknown HLS_LIB $LIB"; exit 2 }
}
go libraries

# Clock and reset: rising edge, asynchronous active-low reset named rst_n
# (same convention as the hand RTL). No synchronous reset.
directive set -CLOCKS [list clk [list -CLOCK_PERIOD $CLK -CLOCK_EDGE rising \
    -CLOCK_UNCERTAINTY 0.0 -RESET_KIND async -RESET_ASYNC_NAME rst_n \
    -RESET_ASYNC_ACTIVE low -RESET_SYNC_NAME rst -RESET_SYNC_ACTIVE high \
    -ENABLE_ACTIVE high]]
directive set -ADVANCED_DPOPT false
directive set /$TOP -CCORE_FLOW bottomup
go assembly

# Registers: reset only where Catapult needs it for correct behavior (control),
# like the hand RTL, whose data registers are not reset.
directive set -RESET_CLEARS_ALL_REGS no

# Pipeline target. A sequential CCORE is always pipelined with II = 1.
# MAX_LATENCY alone only caps the latency (at a relaxed clock the scheduler
# stays at 1 cycle even with a cap of 2), so the c-step of the output write is
# fixed after architect: write in c-step N of the main loop = latency N. If the
# scheduler cannot meet it, Catapult stops with an error instead of silently
# producing another latency. The latency Catapult actually produced is read
# back from rtl.rpt by the report script and checked again in simulation.
switch -- $CFG {
  p1 { set LAT 1 }
  p2 { set LAT 2 }
  default { set LAT 0 }
}
if {$LAT > 0} {
  directive set /$TOP/core/main -PIPELINE_INIT_INTERVAL 1
  directive set /$TOP/core -MAX_LATENCY $LAT
}
go architect
if {$LAT > 0} {
  set OUT [expr {[string match mod_mul_* $BLOCK] ? "p" : "r"}]
  directive set "/$TOP/core/core:rlp/main/$OUT:io_write($OUT:rsc.@)" CSTEPS_FROM [list [list .. == $LAT]]
}
go allocate
go extract

puts "HLS_FLOW_DONE: [solution get /SOLUTION_DIR -checkpath 0]"
