# xsct_build.tcl: Vitis classic (XSCT) platform + bare-metal applications of the
# ARM baseline program (fpga/sw), optional JTAG download of the program and of the
# stories15M images into DDR, and start.
#
# NOT RUN on the preparation machine (no Vitis, no board). Only a syntax /
# variable / control-flow check with stubbed XSCT commands was done
# (test/stub_check.tcl). UNVERIFIED for any Vitis version: the commands below are
# those of Vitis classic 2019.2 to 2023.2. Vitis 2024.1 and later (Vitis Unified)
# need the manual procedure of fpga/README.md.
#
# The program uses only the PS. Any XSA of a Zynq-7000 design whose PS7 has DDR
# and UART1 enabled works (for example the XSA of progress/pqc-ntt-ip); the PL is
# not programmed unless BIT is given.
#
# Usage:
#   xsct <path>/fpga/sw/xsct_build.tcl XSA=<file.xsa> [KEY=VALUE ...]
# Arguments:
#   XSA     hardware platform (required)
#   WS      Vitis workspace                          (<dir of XSA>/vitis_ws_lmb)
#   BUILDS  optimization levels, one application each ("O2 O3")
#   FPU     -mfpu value: neon or vfpv3               (neon)
#   STACK   stack size in bytes (measured need about 2.5 KB, fpga/README.md) (0x10000)
#   HEAP    heap size in bytes (the program does not call malloc) (0x10000)
#   DDRLEN  length of the DDR region given to the linker, from 0x00100000
#           (0x0FF00000: code/data/stack stay below 0x10000000, the first image)
#   RUN     1: download and start over JTAG          (0)
#   RUNOPT  which build to start with RUN=1          (O2)
#   M2      1: also download the stories15M images with RUN=1 (1)
#   CK, TK  stories15M checkpoint and tokenizer files (data/third_party/models/...)
#   BIT     bitstream to program first (optional, not needed)

set script_dir [file normalize [file dirname [info script]]]
set proj_dir   [file normalize [file join $script_dir .. ..]]

proc lmb_parse_args {arglist defaults} {
  set cfg $defaults
  foreach a $arglist {
    if {![regexp {^([A-Z0-9_]+)=(.*)$} $a -> k v]} {
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
set models_dir [file join $proj_dir data third_party models]
set A [lmb_parse_args $argv [dict create XSA "" WS "" BUILDS "O2 O3" FPU neon STACK 0x10000 \
    HEAP 0x10000 DDRLEN 0x0FF00000 RUN 0 RUNOPT O2 M2 1 \
    CK [file join $models_dir stories15M.bin] TK [file join $models_dir tokenizer.bin] BIT ""]]

set xsa [dict get $A XSA]
if {$xsa eq "" || ![file exists $xsa]} {
  error "XSA=<file.xsa> is required and must exist (got '$xsa')"
}
set xsa [file normalize $xsa]
set ws [dict get $A WS]
if {$ws eq ""} { set ws [file join [file dirname $xsa] vitis_ws_lmb] }
set ws [file normalize $ws]
set fpu [dict get $A FPU]
if {$fpu ni {neon vfpv3}} { error "FPU must be neon or vfpv3" }
foreach k {STACK HEAP DDRLEN} {
  if {![string is integer -strict [dict get $A $k]]} { error "$k must be an integer (got '[dict get $A $k]')" }
}
set opt_names [dict create O0 {None (-O0)} O1 {Optimize (-O1)} O2 {Optimize more (-O2)} \
                           O3 {Optimize most (-O3)} Os {Optimize for size (-Os)}]
set builds [dict get $A BUILDS]
if {[llength $builds] == 0} { error "BUILDS is empty" }
foreach o $builds {
  if {![dict exists $opt_names $o]} { error "BUILDS entries must be among [dict keys $opt_names] (got '$o')" }
}
set runopt [dict get $A RUNOPT]
if {[dict get $A RUN] == 1 && [lsearch -exact $builds $runopt] < 0} {
  error "RUNOPT=$runopt is not in BUILDS ($builds)"
}

set m2 [dict get $A M2]
if {[dict get $A RUN] == 1 && $m2 == 1} {
  foreach k {CK TK} {
    if {![file exists [dict get $A $k]]} { error "$k=[dict get $A $k] not found (M2=0 skips stories15M)" }
  }
}

# --- sources --------------------------------------------------------------------
# board program (all of src/ except the host platform file), expected values,
# embedded stories260K arrays (generated, not committed), and model/src unchanged
set srcs {}
foreach f [lsort [glob -nocomplain -types f [file join $script_dir src *.c] [file join $script_dir src *.h]]] {
  if {[file tail $f] ne "plat_host.c"} { lappend srcs $f }
}
set exps [lsort [glob -nocomplain -types f [file join $script_dir expect exp_m*.h]]]
if {[llength $exps] < 2} { error "expected-value headers missing in fpga/sw/expect (run: make -C fpga/sw/test gen)" }
set m1data [file join $script_dir gen m1_data.c]
if {![file exists $m1data]} {
  error "fpga/sw/gen/m1_data.c missing (run: make -C fpga/sw/test gen, see fpga/README.md)"
}
set msrcs [lsort [glob -nocomplain -types f [file join $proj_dir model src *.c] [file join $proj_dir model src *.h]]]
if {[llength $msrcs] == 0} { error "model/src not found under $proj_dir" }
set all_srcs [concat $srcs $exps [list $m1data] $msrcs]

file mkdir $ws
setws $ws
set plat lmb_plat
set proc_name ps7_cortexa9_0

# --- platform -------------------------------------------------------------------
# UNVERIFIED: default domain name (standalone_domain in 2019.2 .. 2022.x,
# standalone_ps7_cortexa9_0 in some later versions); both are tried.
platform create -name $plat -hw $xsa -proc $proc_name -os standalone -out $ws
platform active $plat
set dom ""
foreach d {standalone_domain standalone_ps7_cortexa9_0} {
  if {![catch {domain active $d}]} {
    set dom $d
    break
  }
}
if {$dom eq ""} { error "cannot find the standalone domain of $plat (check: domain list)" }
# UNVERIFIED: BSP instance name of the Zybo Z7 USB-UART (UART1)
bsp config stdin ps7_uart_1
bsp config stdout ps7_uart_1
bsp regenerate
platform generate

# --- applications -----------------------------------------------------------------
# Patch the generated linker script: stack/heap size and the DDR region length.
# UNVERIFIED: the lscript.ld lines of the Cortex-A9 template
#   _STACK_SIZE = DEFINED(_STACK_SIZE) ? _STACK_SIZE : 0x2000;
#   ps7_ddr_0 : ORIGIN = 0x100000, LENGTH = 0x3FF00000
# The same sizes are also passed with --defsym (works when the script uses DEFINED).
proc lmb_patch_lscript {path stack heap ddrlen} {
  if {![file exists $path]} {
    puts "WARNING: $path not found; only --defsym sets stack/heap, DDR length not limited"
    return 0
  }
  set fp [open $path r]
  set t [read $fp]
  close $fp
  set n 0
  incr n [regsub {(_STACK_SIZE\s*:\s*)0x[0-9A-Fa-f]+} $t "\\1[format 0x%X $stack]" t]
  incr n [regsub {(_HEAP_SIZE\s*:\s*)0x[0-9A-Fa-f]+} $t "\\1[format 0x%X $heap]" t]
  incr n [regsub {(ps7_ddr_0\s*:\s*ORIGIN\s*=\s*0x0*100000\s*,\s*LENGTH\s*=\s*)0x[0-9A-Fa-f]+} $t "\\1[format 0x%08X $ddrlen]" t]
  set fp [open $path w]
  puts -nonewline $fp $t
  close $fp
  if {$n != 3} { puts "WARNING: lscript.ld patched $n of 3 places; check $path by hand" }
  return $n
}

# UNVERIFIED: template name ("Empty Application" before 2022.1, "Empty Application(C)" after)
set elfs [dict create]
foreach o $builds {
  set app "lmbase_[string tolower $o]"
  set made 0
  foreach t {{Empty Application(C)} {Empty Application}} {
    if {![catch {app create -name $app -platform $plat -domain $dom -template $t -lang c}]} {
      set made 1
      break
    }
  }
  if {!$made} { error "app create failed for both template names ($app)" }
  set app_src [file join $ws $app src]
  file mkdir $app_src
  foreach f $all_srcs { file copy -force $f $app_src }
  lmb_patch_lscript [file join $app_src lscript.ld] [dict get $A STACK] [dict get $A HEAP] [dict get $A DDRLEN]
  app config -name $app build-config release
  app config -name $app compiler-optimization [dict get $opt_names $o]
  # -ffp-contract=off: same float evaluation as the PC golden (Cortex-A9 VFPv3 has
  # no fused multiply-add anyway). No -ffast-math. NEON only reaches integer loops:
  # GCC does not vectorize float reductions without -ffast-math.
  app config -name $app -add compiler-misc "-mfpu=$fpu -mfloat-abi=hard -ffp-contract=off"
  app config -name $app -add define-compiler-symbols "BUILD_OPT=[string range $o 1 end]"
  app config -name $app -add libraries m
  app config -name $app -add linker-misc "-Wl,--defsym=_STACK_SIZE=[dict get $A STACK] -Wl,--defsym=_HEAP_SIZE=[dict get $A HEAP]"
  app build -name $app
  set elf [file join $ws $app Release $app.elf]
  if {![file exists $elf]} {
    set elf [lindex [glob -nocomplain [file join $ws $app * $app.elf]] 0]
  }
  if {$elf eq "" || ![file exists $elf]} { error "ELF of $app not found after build" }
  dict set elfs $o $elf
  puts "INFO: ELF $o $elf"
}

if {[dict get $A RUN] != 1} {
  puts "INFO: RUN=0, not downloading. To run: RUN=1 with the board in JTAG boot mode, terminal 115200 8N1."
  return
}

# --- JTAG download and run -----------------------------------------------------------
# UNVERIFIED: target filter strings as in the Vitis-generated debugger scripts.
set ps7_init [lindex [glob -nocomplain [file join $ws $plat * ps7_init.tcl] \
                                       [file join $ws $plat * * ps7_init.tcl] \
                                       [file join $ws $plat * * * ps7_init.tcl]] 0]
if {$ps7_init eq ""} { error "ps7_init.tcl not found under the platform" }

connect
targets -set -nocase -filter {name =~ "APU*"}
rst -system
after 2000
set bit [dict get $A BIT]
if {$bit ne ""} {
  if {![file exists $bit]} { error "BIT=$bit not found" }
  targets -set -nocase -filter {name =~ "xc7z020*"}
  fpga -file $bit
  targets -set -nocase -filter {name =~ "APU*"}
}
loadhw -hw $xsa -mem-ranges [list {0x40000000 0xbfffffff}] -regs
configparams force-mem-access 1
source $ps7_init
ps7_init
ps7_post_config
targets -set -nocase -filter {name =~ "*A9*#0"}
dow [dict get $elfs $runopt]
if {$m2 == 1} {
  # addresses: DDR_CK_ADDR / DDR_TK_ADDR of src/bcfg.h
  puts "INFO: downloading stories15M images (about 61 MB over JTAG, this takes a while)"
  dow -data [dict get $A CK] 0x10000000
  dow -data [dict get $A TK] 0x14000000
}
configparams force-mem-access 0
con
puts "INFO: program started; read the UART (115200 8N1). The log ends with 'LMBASE END'."
