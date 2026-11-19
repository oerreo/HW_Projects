# stub_check.tcl: syntax / variable / control-flow check of ../xsct_build.tcl with
# plain tclsh. XSCT commands are stub procs that record their calls; any other
# unknown command raises "UNSTUBBED COMMAND". This proves nothing about XSCT
# behaviour (option names, templates, BSP names); it runs the argument handling
# and every branch of the script logic once. Same method as
# progress/pqc-ntt-ip/fpga/vivado/test/stub_check.tcl.
#
#   cd fpga/sw/test && tclsh stub_check.tcl
# Prints one STUB line per scenario and "STUBCHECK RESULT: PASS|FAIL".

set here     [file normalize [file dirname [info script]]]
set sw       [file dirname $here]
set tmp_root [file join $here build stub_tmp]
file delete -force $tmp_root
file mkdir $tmp_root

set stub_code {
  set ::calls {}
  proc unknown {args} { error "UNSTUBBED COMMAND: [lindex $args 0]" }
  proc rec {args} { lappend ::calls $args }
  proc after {args} { rec after {*}$args }
  proc setws {args} { rec setws {*}$args }
  proc platform {sub args} {
    rec platform $sub {*}$args
    if {$sub eq "generate"} {
      set d [file join $::xsct_ws lmb_plat export lmb_plat hw]
      file mkdir $d
      set fp [open [file join $d ps7_init.tcl] w]
      puts $fp "proc ps7_init {} {rec ps7_init}\nproc ps7_post_config {} {rec ps7_post_config}"
      close $fp
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
    if {$sub eq "create"} {
      if {[lsearch -exact $args "Empty Application(C)"] >= 0 && $::old_template} { error "stub: unknown template" }
      set d [file join $::xsct_ws $name src]
      file mkdir $d
      if {!$::no_lscript} {
        set fp [open [file join $d lscript.ld] w]
        puts $fp "_STACK_SIZE = DEFINED(_STACK_SIZE) ? _STACK_SIZE : 0x2000;"
        puts $fp "_HEAP_SIZE = DEFINED(_HEAP_SIZE) ? _HEAP_SIZE : 0x2000;"
        puts $fp "MEMORY\n\{\n   ps7_ddr_0 : ORIGIN = 0x100000, LENGTH = 0x3FF00000\n\}"
        close $fp
      }
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
  proc has_call {pattern} {
    foreach c $::calls { if {[string match $pattern $c]} { return 1 } }
    return 0
  }
  proc file_has {path pattern} {
    if {![file exists $path]} { return 0 }
    set fp [open $path r]
    set t [read $fp]
    close $fp
    return [string match $pattern $t]
  }
}

set n_run 0
set n_fail 0
# expect: ok | error:<regexp>; check: script run in the child after success, must return 1
proc scenario {name argv_list expect {setup {}} {check {return 1}}} {
  global stub_code tmp_root n_run n_fail sw
  incr n_run
  set tmp [file join $tmp_root $name]
  file mkdir $tmp
  close [open [file join $tmp hw.xsa] w]
  set c [interp create]
  $c eval [list set ::tmp $tmp]
  $c eval [list set ::xsct_ws [file join $tmp ws]]
  $c eval {set ::old_template 0; set ::no_lscript 0; set ::dom_name standalone_domain}
  $c eval $setup
  $c eval $stub_code
  set argv_list [string map [list @T $tmp] $argv_list]
  $c eval [list set argv $argv_list]
  $c eval [list set argc [llength $argv_list]]
  set rc [catch {$c eval [list source [file join $sw xsct_build.tcl]]} msg]
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

set W {XSA=@T/hw.xsa WS=@T/ws}
scenario build_default $W ok {} {
  set s2 $::tmp/ws/lmbase_o2/src
  expr {[file exists $s2/main.c] && [file exists $s2/kern.c] && [file exists $s2/llm.h]
        && [file exists $s2/exp_m1.h] && [file exists $s2/m1_data.c] && [file exists $s2/plat_xil.c]
        && ![file exists $s2/plat_host.c] && [file exists $::tmp/ws/lmbase_o3/src/main.c]
        && [file_has $s2/lscript.ld "*_STACK_SIZE : 0x10000;*"]
        && [file_has $s2/lscript.ld "*_HEAP_SIZE : 0x10000;*"]
        && [file_has $s2/lscript.ld "*LENGTH = 0x0FF00000*"]
        && [has_call "bsp config stdout ps7_uart_1"]
        && [has_call "app config -name lmbase_o2 compiler-optimization {Optimize more (-O2)}"]
        && [has_call "app config -name lmbase_o3 compiler-optimization {Optimize most (-O3)}"]
        && [has_call "app config -name lmbase_o2 -add compiler-misc {-mfpu=neon -mfloat-abi=hard -ffp-contract=off}"]
        && [has_call "app config -name lmbase_o3 -add define-compiler-symbols BUILD_OPT=3"]
        && [has_call "app config -name lmbase_o2 -add libraries m"]
        && [has_call "app config -name lmbase_o2 -add linker-misc *_STACK_SIZE=0x10000*"]
        && ![has_call "dow *"] && ![has_call "connect*"]}
}
scenario run_m2 "$W RUN=1 CK=@T/hw.xsa TK=@T/hw.xsa" ok {} {
  expr {[has_call "ps7_init"] && [has_call "ps7_post_config"] && [has_call "dow *lmbase_o2.elf"]
        && [has_call "dow -data *hw.xsa 0x10000000"] && [has_call "dow -data *hw.xsa 0x14000000"]
        && [has_call "con"] && ![has_call "fpga *"]}
}
scenario run_o3_no_m2 "$W RUN=1 RUNOPT=O3 M2=0 BIT=@T/hw.xsa" ok {} {
  expr {[has_call "dow *lmbase_o3.elf"] && ![has_call "dow -data *"] && [has_call "fpga -file *hw.xsa"]}
}
scenario vfpv3_one_build "$W BUILDS=O2 FPU=vfpv3" ok {} {
  expr {[has_call "app config -name lmbase_o2 -add compiler-misc {-mfpu=vfpv3 -mfloat-abi=hard -ffp-contract=off}"]
        && ![has_call "app create -name lmbase_o3 *"]}
}
scenario old_template_dom2 $W ok {set ::old_template 1; set ::dom_name standalone_ps7_cortexa9_0} {
  has_call "app create -name lmbase_o2 * {Empty Application} *"
}
scenario no_lscript $W ok {set ::no_lscript 1} {
  has_call "app config -name lmbase_o2 -add linker-misc *"
}
scenario no_xsa {} {error:XSA=<file.xsa> is required}
scenario bad_arg "$W FOO=1" {error:unknown argument FOO}
scenario bad_fpu "$W FPU=neon2" {error:FPU must be neon or vfpv3}
scenario bad_build [concat $W [list {BUILDS=O2 O9}]] {error:BUILDS entries must be}
scenario bad_stack "$W STACK=big" {error:STACK must be an integer}
scenario runopt_missing "$W BUILDS=O2 RUN=1 RUNOPT=O3" {error:RUNOPT=O3 is not in BUILDS}
scenario m2_missing "$W RUN=1 CK=@T/none.bin" {error:CK=.* not found}
scenario no_domain $W {error:cannot find the standalone domain} {set ::dom_name other}

file delete -force $tmp_root
puts "STUBCHECK runs=$n_run fail=$n_fail"
puts "STUBCHECK RESULT: [expr {$n_fail == 0 ? "PASS" : "FAIL"}]"
exit [expr {$n_fail == 0 ? 0 : 1}]
