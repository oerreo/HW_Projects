# stub_check.tcl: syntax / variable / control-flow check of the Vivado and
# XSCT scripts with plain tclsh. Vivado and XSCT commands are replaced by
# stub procs that record their calls and return plausible values; any
# command that is neither Tcl nor stubbed raises "UNSTUBBED COMMAND", so a
# misspelled command name is caught as well as unset variables.
#
# This proves nothing about Vivado or XSCT behaviour (option names, IP
# properties, BD automation results). It only runs every branch of the
# argument handling and the script logic once.
#
#   cd fpga/vivado/test && tclsh stub_check.tcl
# Prints one STUB line per scenario and "STUBCHECK RESULT: PASS|FAIL".

set here      [file normalize [file dirname [info script]]]
set vivado    [file dirname $here]
set sw        [file join [file dirname $vivado] sw]
set tmp_root  [file join $here .stub_tmp]
file delete -force $tmp_root
file mkdir $tmp_root

# ---------------------------------------------------------------------------
# Stub environment, evaluated inside a fresh child interpreter per scenario.
# ---------------------------------------------------------------------------
set stub_code {
  set ::calls {}
  array set ::props {}
  if {![info exists ::board_parts]} { set ::board_parts {} }
  if {![info exists ::fail_props]} { set ::fail_props {} }
  if {![info exists ::fake_l4]} { set ::fake_l4 0 }
  if {![info exists ::hide_l4]} { set ::hide_l4 0 }
  if {![info exists ::tmp]} { error "tmp not set" }

  proc unknown {args} { error "UNSTUBBED COMMAND: [lindex $args 0]" }
  proc rec {args} { lappend ::calls $args }
  proc after {args} { rec after {*}$args }

  # glob: optionally pretend that rtl/l4 has a source file (fake_l4) or
  # that it has none (hide_l4, the state before the L4 RTL existed)
  rename glob _glob
  proc glob {args} {
    if {$::hide_l4 && [string match "*rtl/l4*" $args]} {
      return {}
    }
    set r [_glob {*}$args]
    if {$::fake_l4 && [string match "*rtl/l4*" $args]} {
      lappend r "/fake/rtl/l4/pqc_ntt_axi_top.sv"
    }
    return $r
  }

  # -------- Vivado --------
  proc version {args} { return "v0000.0 (stub)" }
  proc create_project {args} { rec create_project {*}$args }
  proc open_project {args} { rec open_project {*}$args }
  proc current_project {args} { return proj }
  proc get_board_parts {args} { rec get_board_parts {*}$args; return $::board_parts }
  proc set_property {args} {
    rec set_property {*}$args
    set a $args
    while {[string match -* [lindex $a 0]]} { set a [lrange $a 1 end] }
    if {[lindex $a 0] eq "-dict"} { error "stub: -dict not expected" }
    lassign $a prop val obj
    set p [string map {CONFIG. ""} $prop]
    if {[lsearch -exact $::fail_props $p] >= 0} {
      error "ERROR: \[BD 41-1276\] stub: unknown property $prop"
    }
    set ::props($obj|$prop) $val
    return
  }
  proc get_property {prop obj} {
    if {[info exists ::props($obj|$prop)]} { return $::props($obj|$prop) }
    switch -glob -- $prop {
      PROGRESS { return "100%" }
      STATUS { return "write_bitstream Complete!" }
      top { return "pqc_bd_wrapper" }
      CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ { return "100.000000" }
      STATS.* { return 0.125 }
      PERIOD { return 10.000 }
      offset { return 0x40000000 }
      default { error "stub get_property: no value for $prop of $obj" }
    }
  }
  proc set_param {args} { rec set_param {*}$args }
  proc add_files {args} { rec add_files {*}$args }
  proc get_files {args} { return [lindex $args end] }
  proc get_filesets {args} { return [lindex $args end] }
  proc update_compile_order {args} { rec update_compile_order {*}$args }
  proc create_bd_design {args} { rec create_bd_design {*}$args }
  proc get_ipdefs {args} {
    set pat [lindex $args end]
    if {![regexp {^xilinx\.com:ip:([a-z0-9_]+):\*$} $pat -> n]} { error "stub get_ipdefs: pattern $pat" }
    # 5.10 must win over 5.5 and 5.9 (numeric compare)
    return [list "xilinx.com:ip:$n:5.5" "xilinx.com:ip:$n:5.10" "xilinx.com:ip:$n:5.9"]
  }
  proc create_bd_cell {args} { rec create_bd_cell {*}$args; return "/[lindex $args end]" }
  proc apply_bd_automation {args} { rec apply_bd_automation {*}$args }
  proc get_bd_pins {args} { return [lindex $args end] }
  proc get_bd_intf_pins {args} {
    if {[lsearch -exact $args -of_objects] >= 0} { return "/pqc_ntt_0/s_axi" }
    return [lindex $args end]
  }
  proc connect_bd_net {args} { rec connect_bd_net {*}$args }
  proc connect_bd_intf_net {args} { rec connect_bd_intf_net {*}$args }
  proc assign_bd_address {args} { rec assign_bd_address {*}$args }
  proc get_bd_addr_spaces {args} { return [lindex $args end] }
  proc get_bd_addr_segs {args} { return "/ps7/Data/SEG_pqc_ntt_0_reg0" }
  proc validate_bd_design {args} { rec validate_bd_design }
  proc save_bd_design {args} { rec save_bd_design }
  proc generate_target {args} { rec generate_target {*}$args }
  proc make_wrapper {args} { rec make_wrapper {*}$args; return "$::tmp/pqc_bd_wrapper.v" }
  proc reset_run {args} { rec reset_run {*}$args }
  proc launch_runs {args} { rec launch_runs {*}$args }
  proc wait_on_run {args} { rec wait_on_run {*}$args }
  proc get_runs {args} { return [lindex $args end] }
  proc get_clocks {args} { return [lindex $args end] }
  proc open_run {args} { rec open_run {*}$args }
  proc close_design {args} { rec close_design }
  proc write_hw_platform {args} {
    rec write_hw_platform {*}$args
    set f [lindex $args [expr {[lsearch -exact $args -file] + 1}]]
    close [open $f w]
  }
  foreach r {report_utilization report_timing_summary report_timing report_power report_clocks
             report_drc report_methodology} {
    proc $r {args} [string map [list @R@ $r] {
      rec @R@ {*}$args
      if {[lsearch -exact $args -return_string] >= 0} {
        return "| Site Type | Used |\n| Slice LUTs* | 1234 | 0 | 53200 | 2.32 |\n| Slice Registers | 2345 | 0 |\n| DSPs | 1 | 0 |\n| Block RAM Tile | 1.5 | 0 |"
      }
      set i [lsearch -exact $args -file]
      if {$i >= 0} { close [open [lindex $args [expr {$i + 1}]] w] }
    }]
  }

  # -------- XSCT --------
  proc setws {args} { rec setws {*}$args }
  proc platform {sub args} {
    rec platform $sub {*}$args
    if {$sub eq "generate"} {
      set d [file join $::xsct_ws pqc_plat export pqc_plat hw]
      file mkdir $d
      set fp [open [file join $d ps7_init.tcl] w]
      puts $fp "proc ps7_init {} {rec ps7_init}\nproc ps7_post_config {} {rec ps7_post_config}"
      close $fp
      close [open [file join $d pqc_bd_wrapper.bit] w]
    }
  }
  proc domain {sub args} {
    rec domain $sub {*}$args
    if {$sub eq "active" && [lindex $args 0] ne "standalone_domain"} { error "stub: no domain [lindex $args 0]" }
  }
  proc bsp {args} { rec bsp {*}$args }
  proc app {sub args} {
    rec app $sub {*}$args
    set name [lindex $args [expr {[lsearch -exact $args -name] + 1}]]
    if {$sub eq "create" && [lsearch -exact $args "Empty Application(C)"] >= 0 && $::old_template} {
      error "stub: unknown template"
    }
    if {$sub eq "build"} {
      set d [file join $::xsct_ws $name Release]
      file mkdir $d
      close [open [file join $d $name.elf] w]
    }
  }
  foreach c {connect targets rst fpga loadhw configparams dow con} {
    proc $c {args} "rec $c {*}\$args"
  }
}

# ---------------------------------------------------------------------------
# Scenario runner
# ---------------------------------------------------------------------------
set n_run 0
set n_fail 0

# expect: ok | error:<regexp>. check: Tcl script evaluated in the child after
# a successful run, must return 1.
proc scenario {name script argv_list expect {setup {}} {check {return 1}}} {
  global stub_code tmp_root n_run n_fail
  incr n_run
  set tmp [file join $tmp_root $name]
  file mkdir $tmp
  set c [interp create]
  $c eval [list set ::tmp $tmp]
  $c eval [list set ::xsct_ws [file join $tmp ws]]
  $c eval {set ::old_template 0}
  $c eval $setup
  $c eval $stub_code
  $c eval [list set argv $argv_list]
  $c eval [list set argc [llength $argv_list]]
  set rc [catch {$c eval [list source $script]} msg]
  set ok 0
  set detail ""
  if {$expect eq "ok"} {
    if {$rc == 0 || $rc == 2} {
      if {[catch {$c eval $check} cres]} {
        set detail "check error: $cres"
      } elseif {$cres == 1} {
        set ok 1
      } else {
        set detail "check returned $cres"
      }
    } else {
      set detail "unexpected error: $msg"
    }
  } else {
    set re [string range $expect 6 end]
    if {$rc == 1 && [regexp -- $re $msg]} {
      set ok 1
      set detail "error as expected: $msg"
    } else {
      set detail "expected error /$re/, got rc=$rc msg=$msg"
    }
  }
  interp delete $c
  if {!$ok} { incr n_fail }
  puts "STUB scenario=$name result=[expr {$ok ? "PASS" : "FAIL"}] detail=[string map {\n " "} $detail]"
}

set cp [file join $vivado create_project.tcl]
set bt [file join $vivado build.tcl]
set xs [file join $sw xsct_build.tcl]

# helpers used by checks (inside the child)
set has_call {
  proc has_call {pattern} {
    foreach c $::calls { if {[string match $pattern $c]} { return 1 } }
    return 0
  }
}

# create_project.tcl ---------------------------------------------------------
scenario cp_sources_only $cp [list DIR=$tmp_root/cp_sources_only/p] ok {set ::hide_l4 1} {
  set fp [open $::tmp/p/pqc_build_config.txt]; set t [read $fp]; close $fp
  expr {[string match "*sources_only*" $t] && ![info exists ::props(/pqc_ntt_0|CONFIG.ALGO)]}
}
scenario cp_board_mont12_l2 $cp [list ALGO=MONT12 CFG=l2 FCLK_MHZ=125 DIR=$tmp_root/cp_board_mont12_l2/p] ok \
  {set ::board_parts {digilentinc.com:zybo-z7-20:part0:1.0 digilentinc.com:zybo-z7-20:part0:1.1}; set ::fake_l4 1} \
  [string cat $has_call {
    expr {$::props(/pqc_ntt_0|CONFIG.ALGO) == 1 && $::props(/pqc_ntt_0|CONFIG.MUL_REG) == 1
          && $::props(/pqc_ntt_0|CONFIG.RED_PIPE) == 1 && $::props(/pqc_ntt_0|CONFIG.OUT_REG) == 0
          && $::props(/pqc_ntt_0|CONFIG.IMPL) == 0 && $::props(/pqc_ntt_0|CONFIG.FCLK_MHZ) == 125
          && $::props(/ps7/Data/SEG_pqc_ntt_0_reg0|offset) eq "0x43C00000"
          && $::props(/ps7/Data/SEG_pqc_ntt_0_reg0|range) eq "0x1000"
          && $::props(/ps7|CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ) == 125
          && $::props(proj|board_part) eq "digilentinc.com:zybo-z7-20:part0:1.1"
          && [has_call "create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.10 ps7"]
          && [has_call "create_bd_cell -type module -reference pqc_ntt_axi_bd pqc_ntt_0"]
          && [has_call "*apply_board_preset 1*"]
          && ![info exists ::props(/ps7|CONFIG.PCW_UIPARAM_DDR_PARTNO)]}
  }]
scenario cp_noboard_k2red_hls_axi $cp \
  [list ALGO=3 IMPL=hls CFG=l4 INTC=axi_interconnect REF_TOP=direct SHARE_ADDSUB=1 DIR=$tmp_root/cp_noboard_k2red_hls_axi/p] ok \
  {set ::fake_l4 1; set ::fail_props {PCW_UART1_BAUD_RATE}} \
  [string cat $has_call {
    expr {$::props(/pqc_ntt_0|CONFIG.ALGO) == 3 && $::props(/pqc_ntt_0|CONFIG.PRE_REG) == 1
          && $::props(/pqc_ntt_0|CONFIG.SHARE_ADDSUB) == 1
          && $::props(/pqc_ntt_0|CONFIG.IMPL) == 1 && $::props(/pqc_ntt_0|CONFIG.FCLK_MHZ) == 100
          && $::props(/ps7|CONFIG.PCW_UIPARAM_DDR_PARTNO) eq "MT41K256M16 RE-125"
          && [has_call "create_bd_cell -type module -reference pqc_ntt_axi_top pqc_ntt_0"]
          && [has_call "*axi_interconnect*"]
          && [has_call "*apply_board_preset 0*"]
          && [has_call "add_files -norecurse -fileset sources_1 *hls/l0/wrap/mod_mul.sv*"]
          && ![has_call "add_files -norecurse -fileset sources_1 *rtl/l0/mod_mul.sv*"]}
  }]
scenario cp_custom_pipe $cp [list ALGO=shiftadd CFG=l0 RED_PIPE=2 DIR=$tmp_root/cp_custom_pipe/p] ok \
  {set ::fake_l4 1} {expr {$::props(/pqc_ntt_0|CONFIG.RED_PIPE) == 2 && $::props(/pqc_ntt_0|CONFIG.ALGO) == 2}}
scenario cp_bad_algo $cp [list ALGO=FOO DIR=$tmp_root/x] {error:ALGO must be one of}
scenario cp_bad_arg $cp [list FOO=1] {error:unknown argument FOO}
scenario cp_share_needs_latency $cp [list SHARE_ADDSUB=1 CFG=l0 DIR=$tmp_root/x] {error:SHARE_ADDSUB = 1 needs}
scenario cp_hls_latency3 $cp [list IMPL=hls CFG=l5 DIR=$tmp_root/x] {error:IMPL=hls has no mod_mul build}
scenario cp_board_yes_missing $cp [list BOARD=yes DIR=$tmp_root/x] {error:BOARD=yes but no Zybo}
scenario cp_bad_range $cp [list RED_PIPE=3 DIR=$tmp_root/x] {error:RED_PIPE must be in 0..2}
scenario cp_bad_fclk $cp [list FCLK_MHZ=abc DIR=$tmp_root/x] {error:FCLK_MHZ must be}

# build.tcl ------------------------------------------------------------------
foreach s {bt_all bt_synth} { file mkdir [file join $tmp_root $s p]; close [open [file join $tmp_root $s p pqc.xpr] w] }
scenario bt_all $bt [list PROJ=$tmp_root/bt_all/p/pqc.xpr JOBS=12] ok {} [string cat $has_call {
  set fp [open $::tmp/p/reports/summary.txt]; set t [read $fp]; close $fp
  expr {[string match "*slice_lut 1234*" $t] && [string match "*bram_tile 1.5*" $t]
        && [string match "*wns 0.125*" $t] && [file exists $::tmp/p/reports/pqc_bd_wrapper.xsa]
        && [has_call "set_param general.maxThreads 8"]
        && [file exists $::tmp/p/reports/impl_timing_summary.rpt]}
}]
scenario bt_synth $bt [list PROJ=$tmp_root/bt_synth/p/pqc.xpr STEP=synth] ok {} [string cat $has_call {
  expr {![has_call "launch_runs impl_1*"] && [file exists $::tmp/p/reports/synth_util_hier.rpt]}
}]
scenario bt_no_proj $bt {} {error:PROJ=<project.xpr> is required}
scenario bt_bad_step $bt [list PROJ=$cp STEP=route] {error:STEP must be all or synth}

# xsct_build.tcl -------------------------------------------------------------
foreach s {xs_build xs_run xs_old_template} { file mkdir [file join $tmp_root $s]; close [open [file join $tmp_root $s hw.xsa] w] }
scenario xs_build $xs [list XSA=$tmp_root/xs_build/hw.xsa WS=$tmp_root/xs_build/ws] ok {} [string cat $has_call {
  expr {[file exists $::tmp/ws/pqc_ntt_test/src/main.c] && [file exists $::tmp/ws/pqc_ntt_test/src/pqc_ntt_regs.h]
        && ![file exists $::tmp/ws/pqc_ntt_test/src/reg_model.c]
        && [has_call "bsp config stdout ps7_uart_1"] && ![has_call "dow *"]
        && [has_call "app config -name pqc_ntt_test compiler-optimization {Optimize more (-O2)}"]}
}]
scenario xs_run $xs [list XSA=$tmp_root/xs_run/hw.xsa WS=$tmp_root/xs_run/ws RUN=1 OPT=-Os] ok {} [string cat $has_call {
  expr {[has_call "fpga -file *pqc_bd_wrapper.bit"] && [has_call "ps7_init"] && [has_call "dow *pqc_ntt_test.elf"]
        && [has_call "con"]}
}]
scenario xs_old_template $xs [list XSA=$tmp_root/xs_old_template/hw.xsa WS=$tmp_root/xs_old_template/ws] ok \
  {set ::old_template 1} [string cat $has_call {has_call "app create * {Empty Application} *"}]
scenario xs_no_xsa $xs {} {error:XSA=<file.xsa> is required}
scenario xs_bad_opt $xs [list XSA=$tmp_root/xs_build/hw.xsa WS=$tmp_root/xs_bad/ws OPT=-O9] {error:OPT must be one of}

file delete -force $tmp_root
puts "STUBCHECK runs=$n_run fail=$n_fail"
puts "STUBCHECK RESULT: [expr {$n_fail == 0 ? "PASS" : "FAIL"}]"
exit [expr {$n_fail == 0 ? 0 : 1}]
