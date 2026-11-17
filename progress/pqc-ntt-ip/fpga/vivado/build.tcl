# build.tcl: synthesis, implementation, bitstream, XSA and reports of a
# project made by create_project.tcl.
#
# NOT RUN on the preparation machine (Vivado is not allowed there); only a
# syntax / variable check with stubbed commands was done. Lines marked
# "UNVERIFIED" depend on the Vivado version.
#
# Usage:
#   vivado -mode batch -source <path>/fpga/vivado/build.tcl \
#          -tclargs PROJ=<dir>/<name>.xpr [JOBS=4] [OUT=<dir>] [STEP=all]
# Arguments:
#   PROJ   project file (.xpr), required
#   JOBS   parallel runs and max threads on the user's machine     (4)
#   OUT    report directory                       (<project dir>/reports)
#   STEP   all | synth   stop after synthesis reports with synth     (all)
# Output in OUT:
#   synth_util.rpt, synth_util_hier.rpt          post-synthesis utilization
#   impl_util.rpt, impl_util_hier.rpt            post-route utilization (hierarchical)
#   impl_timing_summary.rpt, impl_timing_paths.rpt
#   impl_power.rpt, impl_clocks.rpt, impl_drc.rpt, impl_methodology.rpt
#   <bd>_wrapper.bit, <bd>_wrapper.xsa (fixed platform, bitstream included)
#   summary.txt   key numbers (WNS/TNS/WHS, LUT/FF/DSP/BRAM, FCLK) for the log
#   pqc_build_config.txt (copied from the project directory)

proc pqc_parse_args {arglist defaults} {
  set cfg $defaults
  foreach a $arglist {
    if {![regexp {^([A-Z_]+)=(.*)$} $a -> k v]} {
      error "argument '$a' is not KEY=VALUE"
    }
    if {![dict exists $defaults $k]} {
      error "unknown argument $k (known: [dict keys $defaults])"
    }
    dict set cfg $k $v
  }
  return $cfg
}

if {![info exists argv]} { set argv {} }
set A [pqc_parse_args $argv [dict create PROJ "" JOBS 4 OUT "" STEP all]]
set xpr [dict get $A PROJ]
if {$xpr eq "" || ![file exists $xpr]} {
  error "PROJ=<project.xpr> is required and must exist (got '$xpr')"
}
set xpr [file normalize $xpr]
set jobs [dict get $A JOBS]
if {![string is integer -strict $jobs] || $jobs < 1} { error "JOBS must be a positive integer" }
set step [dict get $A STEP]
if {$step ni {all synth}} { error "STEP must be all or synth" }
set proj_dir [file dirname $xpr]
set out [dict get $A OUT]
if {$out eq ""} { set out [file join $proj_dir reports] }
file mkdir $out

open_project $xpr
# Threads of one Vivado process (Vivado limits this to 8 for most steps).
set_param general.maxThreads [expr {$jobs > 8 ? 8 : $jobs}]
set top [get_property top [get_filesets sources_1]]

proc pqc_run_ok {run} {
  # UNVERIFIED: PROGRESS / STATUS strings ("100%", "... Complete!").
  set prog [get_property PROGRESS [get_runs $run]]
  set stat [get_property STATUS [get_runs $run]]
  puts "INFO: $run progress=$prog status=$stat"
  return [expr {$prog eq "100%" && ![string match -nocase "*error*" $stat]}]
}

# --- synthesis ---------------------------------------------------------------
reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {![pqc_run_ok synth_1]} {
  error "synthesis failed, see [file join $proj_dir [file rootname [file tail $xpr]].runs synth_1 runme.log]"
}
open_run synth_1 -name synth_1
report_utilization -file [file join $out synth_util.rpt]
report_utilization -hierarchical -hierarchical_depth 8 -file [file join $out synth_util_hier.rpt]
close_design
if {$step eq "synth"} {
  puts "INFO: STEP=synth, stopping after synthesis reports in $out"
  return
}

# --- implementation and bitstream ------------------------------------------
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {![pqc_run_ok impl_1]} {
  error "implementation / bitstream failed, see the impl_1 runme.log"
}
open_run impl_1
report_utilization -file [file join $out impl_util.rpt]
report_utilization -hierarchical -hierarchical_depth 8 -file [file join $out impl_util_hier.rpt]
report_timing_summary -max_paths 20 -report_unconstrained -warn_on_violation \
  -file [file join $out impl_timing_summary.rpt]
report_timing -max_paths 20 -nworst 1 -sort_by group -file [file join $out impl_timing_paths.rpt]
report_power -file [file join $out impl_power.rpt]
report_clocks -file [file join $out impl_clocks.rpt]
report_drc -file [file join $out impl_drc.rpt]
# UNVERIFIED: report_methodology exists from 2016.1.
catch {report_methodology -file [file join $out impl_methodology.rpt]}

# --- bitstream and XSA ------------------------------------------------------
set bits [glob -nocomplain [file join $proj_dir *.runs impl_1 *.bit]]
foreach b $bits { file copy -force $b $out }
set xsa [file join $out ${top}.xsa]
# UNVERIFIED: write_hw_platform exists from 2019.2 (Vitis). Older versions
# (SDK flow) use write_sysdef / the .hdf, which this flow does not support.
write_hw_platform -fixed -include_bit -force -file $xsa

# --- summary ------------------------------------------------------------------
proc pqc_util_value {rpt pattern} {
  # First number in the table row whose label matches pattern.
  foreach line [split $rpt "\n"] {
    if {[regexp "^\\|\\s*${pattern}\\s*\\|\\s*(\[0-9.\]+)" $line -> v]} {
      return $v
    }
  }
  return "n/a"
}
set util [report_utilization -return_string]
set fp [open [file join $out summary.txt] w]
puts $fp "project [file rootname [file tail $xpr]]"
puts $fp "vivado [version -short]"
foreach k {STATS.WNS STATS.TNS STATS.WHS STATS.THS} {
  set v "n/a"
  catch {set v [get_property $k [get_runs impl_1]]}
  puts $fp "[string tolower [string map {STATS. ""} $k]] $v"
}
puts $fp "slice_lut [pqc_util_value $util {Slice LUTs\*?}]"
puts $fp "slice_reg [pqc_util_value $util {Slice Registers}]"
puts $fp "dsp [pqc_util_value $util {DSPs}]"
puts $fp "bram_tile [pqc_util_value $util {Block RAM Tile}]"
set clk_period "n/a"
catch {set clk_period [get_property PERIOD [get_clocks clk_fpga_0]]}
puts $fp "clk_fpga_0_period_ns $clk_period"
close $fp
set cfg [file join $proj_dir pqc_build_config.txt]
if {[file exists $cfg]} { file copy -force $cfg $out }

set wns "n/a"
catch {set wns [get_property STATS.WNS [get_runs impl_1]]}
if {[string is double -strict $wns] && $wns < 0} {
  puts "WARNING: timing NOT met (WNS = $wns ns). The bitstream is written but must not be used for G6."
}
puts "INFO: reports, bitstream and XSA in $out"
