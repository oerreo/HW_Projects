# stub_check.tcl: syntax / variable / control-flow check of the system build scripts
# (fpga/sys/create_project.tcl, build.tcl, sw/xsct_build.tcl) with plain tclsh, plus static
# cross-checks of the values they share with the RTL, the program and the simulation list.
# Vivado and XSCT commands are replaced by stub procs that record their calls and return
# plausible values; any command that is neither Tcl nor stubbed raises "UNSTUBBED COMMAND".
# Same runner as fpga/bw/test/stub_check.tcl.
#
# This proves nothing about Vivado or XSCT behaviour (option names, IP properties, BD
# automation, address segments, report formats). It runs every branch of the argument handling
# and checks the values the scripts pass (parameters, HP ports, addresses, sources, symbols).
#
#   cd fpga/sys/test && tclsh stub_check.tcl      (or: make stub)
# Needs fpga/sw/gen/m1_data.c (make -C fpga/sw/test data) for the XSCT scenarios.
# Prints one STUB line per scenario / check and "STUBCHECK RESULT: PASS|FAIL".

set here      [file normalize [file dirname [info script]]]
set sysdir    [file dirname $here]
set proj      [file normalize [file join $sysdir .. ..]]
set tmp_root  [file join $here build stub_tmp]
file delete -force $tmp_root
file mkdir $tmp_root

proc slurp {f} { set fp [open $f r]; set t [read $fp]; close $fp; return $t }

# parameter name -> default of a module header ("parameter int|integer NAME = <int>")
proc module_params {file} {
  set d [dict create]
  foreach {- n v} [regexp -all -inline {parameter\s+(?:int|integer)\s+(\w+)\s*=\s*(\d+)} [slurp $file]] {
    dict set d $n $v
  }
  return $d
}
set rtl_par(A) [module_params [file join $proj rtl l4 sys_a_top.sv]]
set rtl_par(P) [module_params [file join $proj rtl l4 sys_p_top.sv]]
set sh_par(A)  [module_params [file join $sysdir src sys_a_bd.v]]
set sh_par(P)  [module_params [file join $sysdir src sys_p_bd.v]]

# ---------------------------------------------------------------------------
# Stub environment, evaluated inside a fresh child interpreter per scenario.
# ---------------------------------------------------------------------------
set stub_code {
  set ::calls {}
  array set ::props {}
  if {![info exists ::board_parts]} { set ::board_parts {} }
  if {![info exists ::fail_props]} { set ::fail_props {} }
  if {![info exists ::no_intf]} { set ::no_intf {} }
  if {![info exists ::ddr_off]} { set ::ddr_off 0x00000000 }
  if {![info exists ::ddr_range]} { set ::ddr_range 0x40000000 }
  if {![info exists ::stub_wns]} { set ::stub_wns 0.125 }
  if {![info exists ::tmp]} { error "tmp not set" }

  proc unknown {args} { error "UNSTUBBED COMMAND: [lindex $args 0]" }
  proc rec {args} { lappend ::calls $args }
  proc after {args} { rec after {*}$args }

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
      top { return "sys_bd_wrapper" }
      CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ { return "100.000000" }
      STATS.WNS { return $::stub_wns }
      STATS.* { return 0.125 }
      PERIOD { return 10.000 }
      REF_NAME { return [expr {[string match *ram36* $obj] ? "RAMB36E1" : [string match *ram18* $obj] ? "RAMB18E1" : "DSP48E1"}] }
      RAM_MODE { return SDP }
      READ_WIDTH_A { return [expr {[string match *ram36* $obj] ? 72 : 36}] }
      WRITE_WIDTH_B { return [expr {[string match *ram36* $obj] ? 72 : 36}] }
      offset { return [expr {[string match *DDR* $obj] ? $::ddr_off : 0x40000000}] }
      range { return [expr {[string match *DDR* $obj] ? $::ddr_range : 0x1000}] }
      default { error "stub get_property: no value for $prop of $obj" }
    }
  }
  proc set_param {args} { rec set_param {*}$args }
  proc add_files {args} { rec add_files {*}$args; lappend ::added {*}[lindex $args end] }
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
    set p [lindex $args end]
    if {[lsearch -exact $::no_intf $p] >= 0} { return {} }
    return $p
  }
  proc connect_bd_net {args} { rec connect_bd_net {*}$args }
  proc connect_bd_intf_net {args} { rec connect_bd_intf_net {*}$args }
  proc assign_bd_address {args} { rec assign_bd_address {*}$args }
  proc get_bd_addr_spaces {args} { return [lindex $args end] }
  proc get_bd_addr_segs {args} {
    set i [lsearch -exact $args -of_objects]
    if {$i >= 0 && [string match *m0?_axi* [lindex $args [expr {$i + 1}]]]} {
      return "[lindex $args [expr {$i + 1}]]/SEG_ps7_HP_DDR_LOWOCM"
    }
    return "/ps7/Data/SEG_sys_0_reg0"
  }
  proc validate_bd_design {args} { rec validate_bd_design }
  proc save_bd_design {args} { rec save_bd_design }
  proc generate_target {args} { rec generate_target {*}$args }
  proc make_wrapper {args} { rec make_wrapper {*}$args; return "$::tmp/sys_bd_wrapper.v" }
  proc reset_run {args} { rec reset_run {*}$args }
  proc launch_runs {args} { rec launch_runs {*}$args }
  proc wait_on_run {args} { rec wait_on_run {*}$args }
  proc get_runs {args} { return [lindex $args end] }
  proc get_clocks {args} { return [lindex $args end] }
  proc get_cells {args} {
    set f [lindex $args end]
    set base sys_bd_i/sys_0/inst/u_top
    if {[string match *RAMB* $f]} {
      return [list $base/u_pi/u_core/g_bank\[0\].u_bank/ram36_0 $base/u_at/u_kv/ram36_1 \
                   $base/u_ve/u_core/ram18_0 sys_bd_i/ic_hp0/ram18_fifo]
    }
    if {[string match *DSP48* $f]} { return [list $base/u_pi/dsp_0 $base/u_ve/dsp_1] }
    if {[regexp {u_top/(u_[a-z]+)} $f -> ip]} {
      return [expr {$ip in {u_pi u_at u_ve} ? "$base/$ip" : {}}]
    }
    return {}
  }
  proc open_run {args} { rec open_run {*}$args }
  proc close_design {args} { rec close_design }
  proc write_hw_platform {args} {
    rec write_hw_platform {*}$args
    set f [lindex $args [expr {[lsearch -exact $args -file] + 1}]]
    close [open $f w]
  }
  foreach r {report_utilization report_timing_summary report_timing report_power report_clocks
             report_drc report_methodology report_ram_utilization} {
    proc $r {args} [string map [list @R@ $r] {
      rec @R@ {*}$args
      if {[lsearch -exact $args -return_string] >= 0} {
        return "| Site Type | Used |\n| Slice LUTs* | 1234 | 0 | 53200 | 2.32 |\n| Slice Registers | 2345 | 0 |\n| DSPs | 149 | 0 |\n| Block RAM Tile | 128 | 0 |\n|   RAMB36/FIFO* | 124 | 0 |\n|   RAMB18 | 8 | 0 |"
      }
      set i [lsearch -exact $args -file]
      if {$i >= 0} { close [open [lindex $args [expr {$i + 1}]] w] }
    }]
  }
  if {[info exists ::no_ramrpt]} { rename report_ram_utilization {} }

  # -------- XSCT --------
  proc setws {args} { rec setws {*}$args }
  proc platform {sub args} {
    rec platform $sub {*}$args
    if {$sub eq "generate"} {
      set d [file join $::xsct_ws sys_plat export sys_plat hw]
      file mkdir $d
      set fp [open [file join $d ps7_init.tcl] w]
      puts $fp "proc ps7_init {} {rec ps7_init}\nproc ps7_post_config {} {rec ps7_post_config}"
      close $fp
      close [open [file join $d sys_bd_wrapper.bit] w]
    }
  }
  proc domain {sub args} {
    rec domain $sub {*}$args
    if {$sub eq "active" && [lindex $args 0] ne $::dom_name} { error "stub: no domain [lindex $args 0]" }
  }
  proc bsp {args} { rec bsp {*}$args }
  proc app {sub args} {
    rec app $sub {*}$args
    set name [lindex $args [expr {[lsearch -exact $args -name] + 1}]]
    if {$sub eq "create" && [lsearch -exact $args "Empty Application(C)"] >= 0 && $::old_template} {
      error "stub: unknown template"
    }
    if {$sub eq "create"} {
      set d [file join $::xsct_ws $name src]
      file mkdir $d
      set fp [open [file join $d lscript.ld] w]
      puts $fp "_STACK_SIZE = DEFINED(_STACK_SIZE) ? _STACK_SIZE : 0x2000;"
      puts $fp "_HEAP_SIZE = DEFINED(_HEAP_SIZE) ? _HEAP_SIZE : 0x2000;"
      puts $fp "   ps7_ddr_0 : ORIGIN = 0x100000, LENGTH = 0x3FF00000"
      close $fp
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

proc report {name ok detail} {
  global n_run n_fail
  incr n_run
  if {!$ok} { incr n_fail }
  puts "STUB scenario=$name result=[expr {$ok ? "PASS" : "FAIL"}] detail=[string map {\n " "} $detail]"
}

# expect: ok | error:<regexp>. check: Tcl script evaluated in the child after
# a successful run, must return 1.
proc scenario {name script argv_list expect {setup {}} {check {return 1}}} {
  global stub_code tmp_root
  set tmp [file join $tmp_root $name]
  file mkdir $tmp
  set c [interp create]
  $c eval [list set ::tmp $tmp]
  $c eval [list set ::xsct_ws [file join $tmp ws]]
  $c eval {set ::old_template 0; set ::dom_name standalone_domain; set ::added {}}
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
  report $name $ok $detail
}

set cp [file join $sysdir create_project.tcl]
set bt [file join $sysdir build.tcl]
set xs [file join $sysdir sw xsct_build.tcl]

# helpers available in the child for checks
set helpers {
  proc has_call {pattern} {
    foreach c $::calls { if {[string match $pattern $c]} { return 1 } }
    return 0
  }
  proc cfgfile {} {
    set fp [open [glob $::tmp/p/sys_build_config.txt] r]; set t [read $fp]; close $fp; return $t
  }
  # module parameters set on sys_0 (CONFIG.<name>)
  proc sys_params {} {
    set d [dict create]
    foreach k [array names ::props /sys_0|CONFIG.*] {
      dict set d [string range $k [string length /sys_0|CONFIG.] end] $::props($k)
    }
    return $d
  }
  proc hp_on {} {
    set l {}
    foreach k {0 1 2 3} {
      if {[info exists ::props(/ps7|CONFIG.PCW_USE_S_AXI_HP$k)] && $::props(/ps7|CONFIG.PCW_USE_S_AXI_HP$k) == 1
          && $::props(/ps7|CONFIG.PCW_S_AXI_HP${k}_DATA_WIDTH) == 64} { lappend l $k }
    }
    return $l
  }
  # HP k fully wired: sys_0/m0k_axi -> ic_hpk -> ps7/S_AXI_HPk, clocked
  proc hp_wired {k} {
    expr {[has_call "connect_bd_intf_net sys_0/m0${k}_axi ic_hp$k/S00_AXI"]
          && [has_call "connect_bd_intf_net ic_hp$k/M00_AXI ps7/S_AXI_HP$k"]
          && [has_call "connect_bd_net ps7/FCLK_CLK0 ps7/S_AXI_HP${k}_ACLK"]}
  }
  proc hp_wired_list {} {
    set l {}
    foreach k {0 1 2 3} { if {[hp_wired $k]} { lappend l $k } }
    set n 0
    foreach c $::calls { if {[string match "connect_bd_intf_net sys_0/m0*" $c]} { incr n } }
    if {$n != [llength $l]} { return "extra" }
    return $l
  }
  proc base_ok {} {
    expr {$::props(/ps7/Data/SEG_sys_0_reg0|offset) eq "0x43C00000"
          && $::props(/ps7/Data/SEG_sys_0_reg0|range) eq "0x10000"
          && [has_call "connect_bd_intf_net ps7/M_AXI_GP0 ic_ctrl/S00_AXI"]
          && [has_call "connect_bd_intf_net ic_ctrl/M00_AXI sys_0/s_axi"]
          && [has_call "connect_bd_net rst_ps7/peripheral_aresetn sys_0/aresetn"]
          && [has_call "connect_bd_net ps7/FCLK_CLK0 sys_0/aclk"]
          && $::props(/ps7|CONFIG.PCW_UART1_PERIPHERAL_ENABLE) == 1
          && [has_call "validate_bd_design"]}
  }
  # rtl/-relative names of the added sources (shell last)
  proc added_rel {} {
    set l {}
    foreach f $::added {
      if {[regexp {/(rtl/.*|fpga/sys/src/.*)$} $f -> r]} { lappend l $r }
    }
    return $l
  }
}

# Independent expectations from docs/spec/system.md 1.2 (build table), 1.3 (HP ports), 1.7.
set exp_A  {GA_P 1 AT_H_PAR 1 AT_KV_SRC 1 AT_HS_MAX 64 AT_TMAX 512 VE_N_MAX 1024 VE_IDX_W 16
            S_ADDR_W 16 XB_REG 1 IDW 1 MAX_BURST 16 OUTS 4 FCLK_MHZ 100}
set exp_P  {PI_NB 4 PI_LB 16 PI_DEPTH 4096 AT_H_PAR 2 AT_KV_SRC 0 AT_HS_MAX 8 AT_TMAX 512 AT_NKV 4
            AT_NL 5 AT_KW 12 AT_VW 8 VE_N_MAX 1024 VE_IDX_W 16 S_ADDR_W 16 XB_REG 1 IDW 1
            MAX_BURST 16 OUTS 4 FCLK_MHZ 100}

# check script: params match expected dict, every param is a parameter of the shell, and (for
# the base builds) equals the default of the RTL top
proc param_check {exp shpar rtlpar {rtl_default 1}} {
  return [string map [list @EXP@ [list $exp] @SH@ [list $shpar] @RTL@ [list $rtlpar] @RD@ $rtl_default] {
    set got [sys_params]
    set bad {}
    foreach {k v} @EXP@ { if {![dict exists $got $k] || [dict get $got $k] != $v} { lappend bad "$k=[expr {[dict exists $got $k] ? [dict get $got $k] : "unset"}]!=$v" } }
    dict for {k v} $got {
      if {![dict exists @SH@ $k]} { lappend bad "$k not a shell parameter" }
      if {@RD@ && $k ne "FCLK_MHZ" && [dict get @RTL@ $k] != $v} { lappend bad "$k=$v != RTL default [dict get @RTL@ $k]" }
    }
    if {[llength $bad]} { error "params: $bad" }
  }]
}

# create_project.tcl ---------------------------------------------------------
source [file join $sysdir filelist.tcl]
proc rtl_files {build} {
  return [concat [lmap r [sys_rtl_list $build] {string cat rtl/ $r}] \
                 [list fpga/sys/src/sys_[string tolower $build]_bd.v]]
}
set files_A [rtl_files A]
set files_P [rtl_files P]

scenario cp_a_board $cp [list BUILD=A DIR=$tmp_root/cp_a_board/p] ok \
  {set ::board_parts {digilentinc.com:zybo-z7-20:part0:1.0 digilentinc.com:zybo-z7-20:part0:1.1}} \
  [string cat $helpers [param_check $exp_A $sh_par(A) $rtl_par(A)] [string map [list @F@ [list $files_A]] {
    set t [cfgfile]
    expr {[hp_on] eq {0 1 3} && [hp_wired_list] eq {0 1 3} && [base_ok]
          && $::props(proj|board_part) eq "digilentinc.com:zybo-z7-20:part0:1.1"
          && [has_call "create_bd_cell -type module -reference sys_a_bd sys_0"]
          && ![has_call "*ic_hp2*"] && [has_call "*smartconnect*"] && [has_call "*apply_board_preset 1*"]
          && [added_rel] eq @F@
          && [string match "*build A\n*" $t] && [string match "*hp_used 0 1 3\n*" $t]
          && [string match "*param GA_P 1\n*" $t] && [string match "*slot_en 4'b1101\n*" $t]
          && [string match "*dsp_calc 60\n*" $t] && [string match "*name sys_a_100m\n*" $t]
          && [regexp {hp_ddr_segment HP3 0x00000000 0x40000000} $t]}
  }]]
scenario cp_p_noboard_axiic $cp [list BUILD=P FCLK_MHZ=125 INTC=axi_interconnect BOARD=no DIR=$tmp_root/cp_p_noboard_axiic/p] ok \
  {} [string cat $helpers [param_check [string map {"FCLK_MHZ 100" "FCLK_MHZ 125"} $exp_P] $sh_par(P) $rtl_par(P)] [string map [list @F@ [list $files_P]] {
    set t [cfgfile]
    expr {[hp_on] eq {0 1 2 3} && [hp_wired_list] eq {0 1 2 3} && [base_ok]
          && $::props(/ps7|CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ) == 125
          && $::props(/ps7|CONFIG.PCW_UIPARAM_DDR_PARTNO) eq "MT41K256M16 RE-125"
          && [has_call "create_bd_cell -type module -reference sys_p_bd sys_0"]
          && [has_call "*axi_interconnect*"] && [has_call "*apply_board_preset 0*"]
          && [added_rel] eq @F@
          && [string match "*bram36_calc 128~129\n*" $t] && [string match "*name sys_p_125m\n*" $t]}
  }]]
scenario cp_a2 $cp [list BUILD=A2 DIR=$tmp_root/cp_a2/p] ok {} \
  [string cat $helpers [param_check [string map {"GA_P 1" "GA_P 2"} $exp_A] $sh_par(A) $rtl_par(A) 0] {
    expr {[hp_on] eq {0 1 2 3} && [hp_wired_list] eq {0 1 2 3}
          && [has_call "create_bd_cell -type module -reference sys_a_bd sys_0"]
          && [string match "*dsp_calc 71\n*" [cfgfile]]}
  }]
scenario cp_pd $cp [list BUILD=PD DIR=$tmp_root/cp_pd/p] ok {} \
  [string cat $helpers [param_check [string map {"AT_KV_SRC 0" "AT_KV_SRC 1"} $exp_P] $sh_par(P) $rtl_par(P) 0] {
    expr {[hp_on] eq {0 1 2 3} && [hp_wired_list] eq {0 1 2 3}
          && [string match "*bram36_calc 66~68\n*" [cfgfile]]}
  }]
scenario cp_p_ve256 $cp [list BUILD=P VE_NMAX=256 DIR=$tmp_root/cp_p_ve256/p] ok {} \
  [string cat $helpers [param_check [string map {"VE_N_MAX 1024" "VE_N_MAX 256"} $exp_P] $sh_par(P) $rtl_par(P) 0] {
    set t [cfgfile]
    expr {[string match "*bram36_calc 126~128\n*" $t] && [string match "*name sys_p_ve256_100m\n*" $t]}
  }]
scenario cp_default_dir $cp [list BUILD=A FCLK_MHZ=83.33] ok {} [string cat $helpers {
  expr {[has_call "create_project -force sys_a_83p33m */fpga/sys/build/sys_a_83p33m -part xc7z020clg400-1"]
        && [dict get [sys_params] FCLK_MHZ] == 83}
}]
file delete -force [file join $sysdir build sys_a_83p33m]
catch {file delete [file join $sysdir build]}
scenario cp_no_build $cp [list DIR=$tmp_root/x] {error:BUILD=A or BUILD=P is required}
scenario cp_bad_build $cp [list BUILD=Q DIR=$tmp_root/x] {error:BUILD must be one of A A2 P PD}
scenario cp_bad_ve $cp [list BUILD=P VE_NMAX=512 DIR=$tmp_root/x] {error:VE_NMAX must be 1024 or 256}
scenario cp_bad_fclk $cp [list BUILD=A FCLK_MHZ=abc DIR=$tmp_root/x] {error:FCLK_MHZ must be}
scenario cp_bad_intc $cp [list BUILD=A INTC=xbar DIR=$tmp_root/x] {error:INTC must be}
scenario cp_bad_arg $cp [list BUILD=A FOO=1] {error:unknown argument FOO}
scenario cp_not_kv $cp [list BUILD] {error:is not KEY=VALUE}
scenario cp_board_yes_missing $cp [list BUILD=P BOARD=yes DIR=$tmp_root/x] {error:BOARD=yes but no Zybo}
scenario cp_hp_prop_unknown $cp [list BUILD=P DIR=$tmp_root/x] {error:cannot enable PCW_USE_S_AXI_HP2} \
  {set ::fail_props {PCW_USE_S_AXI_HP2}}
scenario cp_param_unknown $cp [list BUILD=P DIR=$tmp_root/x] {error:cannot set parameter AT_KV_SRC of sys_p_bd} \
  {set ::fail_props {AT_KV_SRC}}
scenario cp_intf_missing $cp [list BUILD=A DIR=$tmp_root/x] {error:interface sys_0/m02_axi was not inferred} \
  {set ::no_intf {sys_0/m02_axi}}
scenario cp_ddr_small $cp [list BUILD=A DIR=$tmp_root/x] {error:does not cover the arena} {set ::ddr_range 0x20000000}
scenario cp_ddr_offset $cp [list BUILD=P DIR=$tmp_root/x] {error:does not cover the arena} {set ::ddr_off 0x20000000}

# build.tcl ------------------------------------------------------------------
foreach s {bt_all bt_synth bt_wns_neg bt_no_ramrpt} {
  file mkdir [file join $tmp_root $s p]
  close [open [file join $tmp_root $s p sys.xpr] w]
  set fp [open [file join $tmp_root $s p sys_build_config.txt] w]
  puts $fp "name sys_p_100m\nbuild P\nparam AT_H_PAR 2\nhp_ddr_segment HP0 0x00000000 0x40000000\ndsp_calc 149\nbram36_calc 128~129\nfclk_mhz_actual 100.000000"
  close $fp
}
set summary_rd {set fp [open $::tmp/p/reports/summary.txt]; set t [read $fp]; close $fp}
scenario bt_all $bt [list PROJ=$tmp_root/bt_all/p/sys.xpr JOBS=12] ok {} [string cat $helpers $summary_rd {
  set fp [open $::tmp/p/reports/impl_ram_cells.txt]; set r [read $fp]; close $fp
  expr {[string match "*build P\n*" $t] && [string match "*slice_lut 1234\n*" $t] && [string match "*wns 0.125\n*" $t]
        && [string match "*timing_met yes\n*" $t] && [string match "*dsp 149\n*" $t] && [string match "*dsp_calc 149\n*" $t]
        && [string match "*bram_tile 128\n*" $t] && [string match "*ramb36 124\n*" $t] && [string match "*ramb18 8\n*" $t]
        && [string match "*bram36_calc 128~129\n*" $t] && [string match "*bram_tile_limit 140 ok\n*" $t]
        && [string match "*ram_cells ramb36=2 ramb18=2 width72=2\n*" $t]
        && [string match "*ram_cells_ip u_pi ramb36=1 ramb18=0\n*" $t] && [string match "*ram_cells_ip other ramb36=0 ramb18=1\n*" $t]
        && [regexp {ip u_pi lut 1234 reg 2345\s+dsp 149 bram_tile 128} $t] && ![string match "*ip u_ga *" $t]
        && [string match "*fclk_mhz_actual 100.000000\n*" $t]
        && [string match "*RAMB36E1 SDP 72 72 sys_bd_i/sys_0/inst/u_top/u_at/u_kv/ram36_1*" $r]
        && [file exists $::tmp/p/reports/sys_bd_wrapper.xsa] && [file exists $::tmp/p/reports/sys_build_config.txt]
        && [has_call "set_param general.maxThreads 8"] && [has_call "report_ram_utilization -detail -file *impl_ram_util.rpt"]
        && [has_call "report_utilization -hierarchical -hierarchical_depth 12 -file *impl_util_hier.rpt"]
        && [file exists $::tmp/p/reports/impl_timing_summary.rpt] && [file exists $::tmp/p/reports/impl_dsp_cells.txt]}
}]
scenario bt_synth $bt [list PROJ=$tmp_root/bt_synth/p/sys.xpr STEP=synth] ok {} [string cat $helpers {
  expr {![has_call "launch_runs impl_1*"] && [file exists $::tmp/p/reports/synth_util_hier.rpt]
        && [file exists $::tmp/p/reports/synth_ram_cells.txt] && [has_call "set_param general.maxThreads 4"]}
}]
scenario bt_wns_neg $bt [list PROJ=$tmp_root/bt_wns_neg/p/sys.xpr] ok {set ::stub_wns -0.512} [string cat $helpers $summary_rd {
  expr {[string match "*wns -0.512\n*" $t] && [string match "*timing_met no\n*" $t]}
}]
scenario bt_no_ramrpt $bt [list PROJ=$tmp_root/bt_no_ramrpt/p/sys.xpr] ok {set ::no_ramrpt 1} [string cat $helpers $summary_rd {
  expr {[string match "*ram_cells ramb36=2*" $t] && ![file exists $::tmp/p/reports/impl_ram_util.rpt]}
}]
scenario bt_no_proj $bt {} {error:PROJ=<project.xpr> is required}
scenario bt_bad_step $bt [list PROJ=$tmp_root/bt_all/p/sys.xpr STEP=route] {error:STEP must be all or synth}
scenario bt_bad_jobs $bt [list PROJ=$tmp_root/bt_all/p/sys.xpr JOBS=0] {error:JOBS must be a positive integer}

# xsct_build.tcl -------------------------------------------------------------
foreach s {xs_build xs_list xs_run xs_run_m1 xs_newdom} {
  file mkdir [file join $tmp_root $s]
  close [open [file join $tmp_root $s hw.xsa] w]
}
foreach f {ck.bin tk.bin} { close [open [file join $tmp_root xs_run $f] w] }
set m2args [list CK=$tmp_root/xs_run/ck.bin TK=$tmp_root/xs_run/tk.bin]
# expected application sources (basenames)
set exp_src {}
foreach f [glob -types f [file join $sysdir sw *.c] [file join $sysdir sw *.h] [file join $proj fpga sw src *.h] \
                [file join $proj fpga sw expect exp_m*.h] [file join $proj model src *.c] [file join $proj model src *.h]] {
  lappend exp_src [file tail $f]
}
lappend exp_src out.c lmhash.c exp.c plat_xil.c prof.c m1_data.c
set exp_src [lsort -unique $exp_src]

scenario xs_build $xs [list XSA=$tmp_root/xs_build/hw.xsa WS=$tmp_root/xs_build/ws FCLK_HZ=99999999] ok {} \
  [string cat $helpers [string map [list @S@ [list $exp_src]] {
    set got [lsort [lmap f [glob -types f $::tmp/ws/lmsys/src/*] {file tail $f}]]
    set want [lsort [concat @S@ lscript.ld]]
    set fp [open $::tmp/ws/lmsys/src/lscript.ld]; set ld [read $fp]; close $fp
    expr {$got eq $want
          && [has_call "bsp config stdout ps7_uart_1"] && ![has_call "dow *"] && ![has_call "fpga *"]
          && [has_call "app config -name lmsys -add define-compiler-symbols SYS_FCLK_HZ=99999999u"]
          && [has_call "app config -name lmsys -add define-compiler-symbols SYS_RUN_MASK=15u"]
          && [has_call "app config -name lmsys -add define-compiler-symbols SYS_STEPS=0"]
          && [has_call "app config -name lmsys -add define-compiler-symbols SYS_RUN_M1=1"]
          && [has_call "app config -name lmsys -add define-compiler-symbols SYS_RUN_M2=1"]
          && [has_call "app config -name lmsys -add define-compiler-symbols BUILD_OPT=2"]
          && [has_call "app config -name lmsys -add compiler-misc {-mfpu=neon -mfloat-abi=hard -ffp-contract=off}"]
          && [has_call "app config -name lmsys compiler-optimization {Optimize more (-O2)}"]
          && [has_call "app config -name lmsys -add libraries m"]
          && [string match "*_STACK_SIZE : 0x10000;*" $ld] && [string match "*LENGTH = 0x0FF00000*" $ld]}
  }]]
scenario xs_list $xs [list XSA=$tmp_root/xs_list/hw.xsa WS=$tmp_root/xs_list/ws LIST=0,ff:0c,3,F8 RUNS=EK STEPS=24 MODELS=1 OPT=O3 FPU=vfpv3] ok {} [string cat $helpers {
  expr {[has_call "app config -name lmsys -add compiler-misc {-mfpu=vfpv3 -mfloat-abi=hard -ffp-contract=off -DSYS_MASK_LIST=0xD00,0xCFF,0xD03,0xDF8}"]
        && [has_call "app config -name lmsys -add define-compiler-symbols SYS_RUN_MASK=9u"]
        && [has_call "app config -name lmsys -add define-compiler-symbols SYS_STEPS=24"]
        && [has_call "app config -name lmsys -add define-compiler-symbols SYS_RUN_M2=0"]
        && [has_call "app config -name lmsys -add define-compiler-symbols BUILD_OPT=3"]}
}]
scenario xs_run $xs [concat [list XSA=$tmp_root/xs_run/hw.xsa WS=$tmp_root/xs_run/ws RUN=1] $m2args] ok {} [string cat $helpers {
  set i_fpga [lsearch -glob $::calls "fpga -file *sys_bd_wrapper.bit"]
  set i_init [lsearch -exact $::calls "ps7_init"]
  set i_dow [lsearch -glob $::calls "dow *lmsys.elf"]
  set i_ck [lsearch -glob $::calls "dow -data *ck.bin 0x10000000"]
  set i_tk [lsearch -glob $::calls "dow -data *tk.bin 0x14000000"]
  set i_con [lsearch -exact $::calls "con"]
  expr {$i_fpga >= 0 && $i_fpga < $i_init && $i_init < $i_dow && $i_dow < $i_ck && $i_ck < $i_tk && $i_tk < $i_con
        && [has_call "ps7_post_config"]
        && [has_call "app config -name lmsys -add define-compiler-symbols SYS_FCLK_HZ=100000000u"]}
}]
scenario xs_run_m1 $xs [list XSA=$tmp_root/xs_run_m1/hw.xsa WS=$tmp_root/xs_run_m1/ws RUN=1 MODELS=1 CK=/nonexistent] ok \
  {set ::old_template 1} [string cat $helpers {
  expr {![has_call "dow -data *"] && [has_call "dow *lmsys.elf"] && [has_call "fpga -file *"]
        && [has_call "app create -name lmsys * -template {Empty Application} *"]}
}]
scenario xs_newdom $xs [list XSA=$tmp_root/xs_newdom/hw.xsa WS=$tmp_root/xs_newdom/ws APP=other] ok \
  {set ::dom_name standalone_ps7_cortexa9_0} [string cat $helpers {
  expr {[has_call "app create -name other -platform sys_plat -domain standalone_ps7_cortexa9_0 *"]}
}]
scenario xs_bad_fclk $xs [list XSA=$tmp_root/xs_build/hw.xsa FCLK_HZ=100M] {error:FCLK_HZ must be an integer}
scenario xs_no_xsa $xs {} {error:XSA=<file.xsa> is required}
scenario xs_bad_runs $xs [list XSA=$tmp_root/xs_build/hw.xsa RUNS=EX] {error:RUNS must be letters of ETPKW}
scenario xs_bad_list $xs [list XSA=$tmp_root/xs_build/hw.xsa LIST=0,1ff] {error:LIST entry '1ff' is not}
scenario xs_bad_models $xs [list XSA=$tmp_root/xs_build/hw.xsa MODELS=3] {error:MODELS must be 1, 2 or 12}
scenario xs_bad_steps $xs [list XSA=$tmp_root/xs_build/hw.xsa STEPS=513] {error:STEPS must be an integer in 0..512}
scenario xs_bad_opt $xs [list XSA=$tmp_root/xs_build/hw.xsa OPT=-O2] {error:OPT must be one of}
scenario xs_run_no_ck $xs [list XSA=$tmp_root/xs_build/hw.xsa RUN=1 CK=/nonexistent] {error:CK=/nonexistent not found}

# ---------------------------------------------------------------------------
# Static cross-checks (no stubs)
# ---------------------------------------------------------------------------
# 1. GP0 base and arena: create_project.tcl == ipregs.h SYS_BASE / bcfg.h ARENA_ADDR, ARENA_CAP
set cpt [slurp $cp]
regexp {set SYS_BASEADDR (0x[0-9A-Fa-f]+)} $cpt -> cp_base
regexp {set SYS_RANGE\s+(0x[0-9A-Fa-f]+)} $cpt -> cp_range
regexp {set SYS_ARENA_LO (0x[0-9A-Fa-f]+)} $cpt -> cp_alo
regexp {set SYS_ARENA_HI (0x[0-9A-Fa-f]+)} $cpt -> cp_ahi
set ipr [slurp [file join $sysdir sw ipregs.h]]
regexp {#define SYS_BASE (0x[0-9A-Fa-f]+)u} $ipr -> c_base
regexp {#define SYS_SLOT_SZ (0x[0-9A-Fa-f]+)u} $ipr -> c_slot
set bcf [slurp [file join $proj fpga sw src bcfg.h]]
regexp {#define ARENA_ADDR (0x[0-9A-Fa-f]+)u} $bcf -> c_aaddr
regexp {#define ARENA_CAP (0x[0-9A-Fa-f]+)u} $bcf -> c_acap
set ok [expr {$cp_base == $c_base && $cp_range == 16 * $c_slot && $cp_alo == $c_aaddr && $cp_ahi == $c_aaddr + $c_acap}]
report x_addr $ok "create_project base $cp_base range $cp_range arena $cp_alo..$cp_ahi; ipregs.h $c_base slot $c_slot; bcfg.h arena $c_aaddr + $c_acap"

# 2. filelist == sim/tests/sys_smoke.cfg RTL_FILES (order kept), exclusions only as documented
regexp {RTL_FILES="([^"]*)"} [slurp [file join $proj sim tests sys_smoke.cfg]] -> smoke
set ok [expr {[string trim $SYS_RTL_FILES] eq "" ? 0 : [join $SYS_RTL_FILES " "] eq [join $smoke " "]}]
foreach b {A P} {
  set l [sys_rtl_list $b]
  set ex [dict get $SYS_RTL_EXCLUDE $b]
  if {[llength $l] + [llength $ex] != [llength $smoke]} { set ok 0 }
}
if {[lsearch -exact [sys_rtl_list A] l4/sys_a_top.sv] < 0 || [lsearch -exact [sys_rtl_list P] l4/sys_p_top.sv] < 0} { set ok 0 }
report x_filelist $ok "sys_smoke.cfg [llength $smoke] files; A [llength [sys_rtl_list A]], P [llength [sys_rtl_list P]]"

# 3. shells: parameter names and defaults == RTL top; every top port connected once in the shell
set ok 1
set det {}
foreach b {A P} {
  set lb [string tolower $b]
  if {$sh_par($b) ne $rtl_par($b)} { set ok 0; lappend det "$b params differ" }
  set sv [slurp [file join $proj rtl l4 sys_${lb}_top.sv]]
  set ports [lsort [lmap {- p} [regexp -all -inline {(?:input|output)\s+logic\s*(?:\[[^\]]+\])?\s*(\w+)} $sv] {set p}]]
  set sh [slurp [file join $sysdir src sys_${lb}_bd.v]]
  set conn [lsort [lmap {- p} [regexp -all -inline {\n\s+\.(\w+)\((?:aclk|aresetn|s_axi_\w+|m0[0-3]_axi_\w+)\)} $sh] {set p}]]
  if {$ports ne $conn} { set ok 0; lappend det "$b ports [llength $ports] connected [llength $conn]" }
  lappend det "$b [dict size $sh_par($b)] params [llength $ports] ports"
}
report x_shell $ok [join $det "; "]

# 4. build table HP ports == the HP port each top drives (comment table of the RTL and system.md
#    1.3): every port of a build carries traffic; HP2 is unused only by build A
set ok [expr {[regexp {A\s+\[dict create top A hp \{0 1 3\}} $cpt] && [regexp {A2 \[dict create top A hp \{0 1 2 3\}} $cpt]
              && [regexp {P\s+\[dict create top P hp \{0 1 2 3\}} $cpt] && [regexp {PD \[dict create top P hp \{0 1 2 3\}} $cpt]}]
report x_hp_table $ok "A {0 1 3}, A2/P/PD {0 1 2 3}"

if {![info exists ::env(STUB_KEEP)]} { file delete -force $tmp_root }
puts "STUBCHECK runs=$n_run fail=$n_fail"
puts "STUBCHECK RESULT: [expr {$n_fail == 0 ? "PASS" : "FAIL"}]"
exit [expr {$n_fail == 0 ? 0 : 1}]
