# build.tcl: synthesis, implementation, bitstream, XSA and reports of a project made by
# fpga/sys/create_project.tcl (system builds A, P). Same flow and argument format as
# fpga/bw/build.tcl, with the reports S5-6 needs (docs/plan.md: WNS, BRAM36 <= 140, DSP against
# the [계산] values of system.md 1.5, BRAM parity mapping of pim_bank / kv_store).
#
# UNVERIFIED: NOT RUN on the preparation machine (Vivado is not allowed there); only a
# syntax / variable check with stubbed commands was done (fpga/sys/test/stub_check.tcl).
# Lines marked "UNVERIFIED" depend on the Vivado version.
#
# Usage:
#   vivado -mode batch -source <repo>/fpga/sys/build.tcl \
#          -tclargs PROJ=<dir>/<name>.xpr [JOBS=4] [OUT=<dir>] [STEP=all]
# Arguments:
#   PROJ   project file (.xpr), required
#   JOBS   parallel runs and max threads on the user's machine (Vivado caps threads at 8)  (4)
#   OUT    report directory                       (<project dir>/reports)
#   STEP   all | synth   stop after synthesis reports with synth     (all)
# Output in OUT:
#   synth_util.rpt, synth_util_hier.rpt, synth_ram_util.rpt   post-synthesis
#   impl_util.rpt, impl_util_hier.rpt              post-route utilization (hierarchical, per IP)
#   impl_ram_util.rpt                              report_ram_utilization (if the command exists)
#   impl_ram_cells.txt                             every block RAM primitive: type, mode, widths, cell
#   impl_dsp_cells.txt                             every DSP48E1 cell
#   impl_timing_summary.rpt, impl_timing_paths.rpt
#   impl_power.rpt, impl_clocks.rpt, impl_drc.rpt, impl_methodology.rpt
#   <bd>_wrapper.bit, <bd>_wrapper.xsa (fixed platform, bitstream included)
#   summary.txt   key numbers (WNS/TNS/WHS, LUT/FF/DSP/BRAM, per IP, RAM widths, FCLK, [계산])
#   sys_build_config.txt (copied from the project directory)

proc sys_parse_args {arglist defaults} {
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
set A [sys_parse_args $argv [dict create PROJ "" JOBS 4 OUT "" STEP all]]
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
# Threads of one Vivado process (Vivado limits this to 8 for most steps). The user's machine,
# not the preparation server: no further limit here.
set_param general.maxThreads [expr {$jobs > 8 ? 8 : $jobs}]
set top [get_property top [get_filesets sources_1]]

proc sys_run_ok {run} {
  # UNVERIFIED: PROGRESS / STATUS strings ("100%", "... Complete!").
  set prog [get_property PROGRESS [get_runs $run]]
  set stat [get_property STATUS [get_runs $run]]
  puts "INFO: $run progress=$prog status=$stat"
  return [expr {$prog eq "100%" && ![string match -nocase "*error*" $stat]}]
}

# First number in the table row whose label matches pattern ("n/a" if none).
proc sys_util_value {rpt pattern} {
  foreach line [split $rpt "\n"] {
    if {[regexp "^\\|\\s*${pattern}\\s*\\|\\s*(\[0-9.\]+)" $line -> v]} {
      return $v
    }
  }
  return "n/a"
}

# report_ram_utilization exists in recent versions only. UNVERIFIED: command name and options.
proc sys_ram_report {file} {
  if {[catch {report_ram_utilization -detail -file $file} msg]} {
    if {[catch {report_ram_utilization -file $file} msg2]} {
      puts "WARNING: report_ram_utilization not available ($msg2); see the *_ram_cells.txt listing"
      return 0
    }
  }
  return 1
}

# One line per block RAM primitive. The parity question of system.md 1.6: pim_bank (144 bit)
# and kv_store (210 bit) fit 64 + 60 RAMB36 only if their 512 x 72 SDP primitives use the 8
# parity bits as data (READ_WIDTH_A / WRITE_WIDTH_B 72, RAM_MODE SDP).
# UNVERIFIED: property names RAM_MODE, READ_WIDTH_A, WRITE_WIDTH_B of RAMB36E1/RAMB18E1 cells.
proc sys_ram_cells {file} {
  set cells [get_cells -hierarchical -quiet -filter {REF_NAME =~ "RAMB*"}]
  set fp [open $file w]
  puts $fp "# ref_name ram_mode read_width_a write_width_b cell"
  set n36 0
  set n18 0
  set n72 0
  set by_ip [dict create]
  foreach c [lsort $cells] {
    set ref [get_property REF_NAME $c]
    set row [list $ref]
    foreach p {RAM_MODE READ_WIDTH_A WRITE_WIDTH_B} {
      set v "n/a"
      catch {set v [get_property $p $c]}
      lappend row $v
    }
    lappend row $c
    puts $fp [join $row " "]
    if {[string match RAMB36* $ref]} { incr n36 } elseif {[string match RAMB18* $ref]} { incr n18 }
    if {[lindex $row 2] == 72 || [lindex $row 3] == 72} { incr n72 }
    set ip other
    foreach k {u_ga u_pi u_at u_ve} {
      if {[string match "*/$k/*" $c]} { set ip $k }
    }
    if {![dict exists $by_ip $ip]} { dict set by_ip $ip {0 0} }
    lassign [dict get $by_ip $ip] a b
    if {[string match RAMB36* $ref]} { incr a } else { incr b }
    dict set by_ip $ip [list $a $b]
  }
  close $fp
  return [list $n36 $n18 $n72 $by_ip]
}

proc sys_dsp_cells {file} {
  set cells [get_cells -hierarchical -quiet -filter {REF_NAME =~ "DSP48*"}]
  set fp [open $file w]
  puts $fp "# DSP cells: [llength $cells]"
  foreach c [lsort $cells] { puts $fp $c }
  close $fp
  return [llength $cells]
}

# --- synthesis ---------------------------------------------------------------
reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {![sys_run_ok synth_1]} {
  error "synthesis failed, see [file join $proj_dir [file rootname [file tail $xpr]].runs synth_1 runme.log]"
}
open_run synth_1 -name synth_1
report_utilization -file [file join $out synth_util.rpt]
report_utilization -hierarchical -hierarchical_depth 12 -file [file join $out synth_util_hier.rpt]
sys_ram_report [file join $out synth_ram_util.rpt]
sys_ram_cells [file join $out synth_ram_cells.txt]
close_design
if {$step eq "synth"} {
  puts "INFO: STEP=synth, stopping after synthesis reports in $out"
  return
}

# --- implementation and bitstream ------------------------------------------
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {![sys_run_ok impl_1]} {
  error "implementation / bitstream failed, see the impl_1 runme.log"
}
open_run impl_1
report_utilization -file [file join $out impl_util.rpt]
report_utilization -hierarchical -hierarchical_depth 12 -file [file join $out impl_util_hier.rpt]
sys_ram_report [file join $out impl_ram_util.rpt]
set ram [sys_ram_cells [file join $out impl_ram_cells.txt]]
set ndsp_cells [sys_dsp_cells [file join $out impl_dsp_cells.txt]]
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
# UNVERIFIED: write_hw_platform exists from 2019.2 (Vitis).
write_hw_platform -fixed -include_bit -force -file $xsa

# --- summary ------------------------------------------------------------------
set cfgd [dict create]
set cfg [file join $proj_dir sys_build_config.txt]
if {[file exists $cfg]} {
  set fp [open $cfg r]
  foreach line [split [read $fp] "\n"] {
    if {[regexp {^(\S+)\s+(.*)$} $line -> k v] && $k ne "param" && $k ne "hp_ddr_segment"} {
      dict set cfgd $k $v
    }
  }
  close $fp
  file copy -force $cfg $out
}
proc cfgv {d k} { if {[dict exists $d $k]} { return [dict get $d $k] }; return "n/a" }

set util [report_utilization -return_string]
set fp [open [file join $out summary.txt] w]
puts $fp "project [file rootname [file tail $xpr]]"
puts $fp "build [cfgv $cfgd build]"
puts $fp "vivado [version -short]"
set wns "n/a"
foreach k {STATS.WNS STATS.TNS STATS.WHS STATS.THS} {
  set v "n/a"
  catch {set v [get_property $k [get_runs impl_1]]}
  if {$k eq "STATS.WNS"} { set wns $v }
  puts $fp "[string tolower [string map {STATS. ""} $k]] $v"
}
set whs "n/a"
catch {set whs [get_property STATS.WHS [get_runs impl_1]]}
if {[string is double -strict $wns] && [string is double -strict $whs]} {
  puts $fp "timing_met [expr {$wns >= 0 && $whs >= 0 ? "yes" : "no"}]"
} else {
  puts $fp "timing_met unknown"
}
puts $fp "slice_lut [sys_util_value $util {Slice LUTs\*?}]"
puts $fp "slice_reg [sys_util_value $util {Slice Registers}]"
puts $fp "dsp [sys_util_value $util {DSPs}]"
puts $fp "dsp_cells $ndsp_cells"
puts $fp "dsp_calc [cfgv $cfgd dsp_calc]"
set bram [sys_util_value $util {Block RAM Tile}]
puts $fp "bram_tile $bram"
puts $fp "ramb36 [sys_util_value $util {RAMB36/FIFO\*?}]"
puts $fp "ramb18 [sys_util_value $util {RAMB18}]"
puts $fp "bram36_calc [cfgv $cfgd bram36_calc]"
puts $fp "bram_tile_limit 140 [expr {[string is double -strict $bram] ? ($bram <= 140 ? "ok" : "over") : "n/a"}]"
lassign $ram n36 n18 n72 by_ip
puts $fp "ram_cells ramb36=$n36 ramb18=$n18 width72=$n72"
foreach k {u_ga u_pi u_at u_ve other} {
  if {[dict exists $by_ip $k]} {
    lassign [dict get $by_ip $k] a b
    puts $fp "ram_cells_ip $k ramb36=$a ramb18=$b"
  }
}
# per IP utilization. UNVERIFIED: hierarchical cell names <bd>_i/sys_0/inst/u_top/u_<ip>.
foreach k {u_ga u_pi u_at u_ve} {
  set c [get_cells -hierarchical -quiet -filter "NAME =~ \"*/u_top/$k\""]
  if {[llength $c] != 1} { continue }
  set u [report_utilization -cells $c -return_string]
  puts $fp "ip $k lut [sys_util_value $u {Slice LUTs\*?}] reg [sys_util_value $u {Slice Registers}]\
            dsp [sys_util_value $u {DSPs}] bram_tile [sys_util_value $u {Block RAM Tile}]"
}
set clk_period "n/a"
catch {set clk_period [get_property PERIOD [get_clocks clk_fpga_0]]}
puts $fp "clk_fpga_0_period_ns $clk_period"
puts $fp "fclk_mhz_actual [cfgv $cfgd fclk_mhz_actual]"
close $fp

if {[string is double -strict $wns] && $wns < 0} {
  puts "WARNING: timing NOT met (WNS = $wns ns). The bitstream is written but must not be used for measurements (G6)."
}
if {[string is double -strict $bram] && $bram > 140} {
  puts "WARNING: Block RAM tiles $bram > 140 (should not happen after a successful place)."
}
puts "INFO: reports, bitstream and XSA in $out"
