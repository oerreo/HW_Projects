# xsct_build.tcl: Vitis classic (XSCT) platform + bare-metal application of the system program
# (fpga/sys/sw, docs/spec/system.md 2), optional JTAG run: program the PL (build A or P
# bitstream), init the PS, download the ELF and the stories15M images into DDR, start.
# Same argument format as fpga/bw/sw/xsct_build.tcl and fpga/sw/xsct_build.tcl (whose
# compiler options, linker-script patch and DDR image addresses are reused unchanged).
#
# UNVERIFIED: NOT RUN on the preparation machine (no Vitis, no board). Only a syntax /
# variable / control-flow check with stubbed XSCT commands was done
# (fpga/sys/test/stub_check.tcl). The commands are those of Vitis classic 2019.2 to 2023.2;
# Vitis 2024.1 and later (Vitis Unified) need the manual procedure of fpga/sys/README.md.
#
# Usage:
#   xsct <repo>/fpga/sys/sw/xsct_build.tcl XSA=<file.xsa> FCLK_HZ=<actual FCLK> [KEY=VALUE ...]
# Arguments:
#   XSA      hardware platform from fpga/sys/build.tcl (required; bitstream inside)
#   FCLK_HZ  actual PL clock in Hz (create_project.tcl / sys_build_config.txt), C symbol
#            SYS_FCLK_HZ: converts CYCLES to time                                (100000000)
#   WS       Vitis workspace                       (<dir of XSA>/vitis_ws_sys)
#   APP      application name                      (lmsys)
#   OPT      optimization level O0 O1 O2 O3 Os     (O2)
#   FPU      -mfpu value: neon or vfpv3            (neon)
#   STACK    stack size in bytes                   (0x10000)
#   HEAP     heap size in bytes (no malloc)        (0x10000)
#   DDRLEN   DDR region length for the linker from 0x00100000 (0x0FF00000: below 0x10000000)
#   LIST     run list, "mask[:opt],..." in hex as the host SX_LIST (empty: scfg.h
#            SYS_MASK_LIST = system.md 4.1 list); compiled as SYS_MASK_LIST
#   RUNS     run kinds, letters of ETPKW (E end-to-end, T per token, P probes, K kernel compare,
#            W warm start), compiled as SYS_RUN_MASK                              (ETPK)
#   STEPS    positions per run, 0 = all (SYS_STEPS)                                (0)
#   MODELS   models compiled in: 1 (260K), 2 (15M), 12 (both) (SYS_RUN_M1/M2)       (12)
#   RUN      1: program the PL, init the PS, download and start over JTAG          (0)
#   BIT      bitstream for RUN=1                   (the one inside the platform)
#   CK, TK   stories15M checkpoint and tokenizer, downloaded with RUN=1 when MODELS has 2
#            (data/third_party/models/stories15M.bin, tokenizer.bin)

set script_dir [file normalize [file dirname [info script]]]
set proj_dir   [file normalize [file join $script_dir .. .. ..]]

proc sys_parse_args {arglist defaults} {
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
set A [sys_parse_args $argv [dict create XSA "" FCLK_HZ 100000000 WS "" APP lmsys OPT O2 FPU neon \
    STACK 0x10000 HEAP 0x10000 DDRLEN 0x0FF00000 LIST "" RUNS ETPK STEPS 0 MODELS 12 RUN 0 BIT "" \
    CK [file join $models_dir stories15M.bin] TK [file join $models_dir tokenizer.bin]]]

set fclk_hz [dict get $A FCLK_HZ]
if {![string is integer -strict $fclk_hz] || $fclk_hz < 1000000 || $fclk_hz > 300000000} {
  error "FCLK_HZ must be an integer in 1e6..3e8, got $fclk_hz"
}
set xsa [dict get $A XSA]
if {$xsa eq "" || ![file exists $xsa]} {
  error "XSA=<file.xsa> is required and must exist (got '$xsa')"
}
set xsa [file normalize $xsa]
set ws [dict get $A WS]
if {$ws eq ""} { set ws [file join [file dirname $xsa] vitis_ws_sys] }
set ws [file normalize $ws]
set app [dict get $A APP]
set fpu [dict get $A FPU]
if {$fpu ni {neon vfpv3}} { error "FPU must be neon or vfpv3" }
foreach k {STACK HEAP DDRLEN} {
  if {![string is integer -strict [dict get $A $k]]} { error "$k must be an integer (got '[dict get $A $k]')" }
}
set opt_names [dict create O0 {None (-O0)} O1 {Optimize (-O1)} O2 {Optimize more (-O2)} \
                           O3 {Optimize most (-O3)} Os {Optimize for size (-Os)}]
set opt [dict get $A OPT]
if {![dict exists $opt_names $opt]} { error "OPT must be one of [dict keys $opt_names] (got '$opt')" }

# run kinds -> SYS_RUN_MASK (bit order of sbench.c run_kinds: E T P K W)
set runs [dict get $A RUNS]
if {$runs eq "" || ![regexp {^[ETPKW]+$} $runs]} { error "RUNS must be letters of ETPKW (got '$runs')" }
set run_mask 0
foreach ch [split $runs ""] { set run_mask [expr {$run_mask | (1 << [string first $ch ETPKW])}] }
set steps [dict get $A STEPS]
if {![string is integer -strict $steps] || $steps < 0 || $steps > 512} {
  error "STEPS must be an integer in 0..512 (got '$steps')"
}
set models [dict get $A MODELS]
if {$models ni {1 2 12}} { error "MODELS must be 1, 2 or 12 (got '$models')" }
set m1 [expr {[string first 1 $models] >= 0}]
set m2 [expr {[string first 2 $models] >= 0}]

# run list "mask[:opt],..." -> SYS_MASK_LIST entries mask | opt << 8 (scfg.h MO); opt default
# OPT_DEFAULT = DEFER_AT | WRGB_SKIP | FUSE_AM = 0x0d, as sbench.c parses the host SX_LIST
set list_def ""
set list [string trim [dict get $A LIST]]
if {$list ne ""} {
  set ents {}
  foreach e [split $list ,] {
    if {![regexp {^([0-9a-fA-F]{1,2})(?::([0-9a-fA-F]{1,2}))?$} [string trim $e] -> m o]} {
      error "LIST entry '$e' is not mask\[:opt\] in hex"
    }
    if {$o eq ""} { set o 0d }
    scan $m %x mv
    scan $o %x ov
    lappend ents [format 0x%X [expr {($ov << 8) | $mv}]]
  }
  if {[llength $ents] > 64} { error "LIST has [llength $ents] entries, SYS_MAX_RUNS is 64" }
  set list_def [join $ents ,]
}

if {[dict get $A RUN] == 1 && $m2} {
  foreach k {CK TK} {
    if {![file exists [dict get $A $k]]} { error "$k=[dict get $A $k] not found (MODELS=1 skips stories15M)" }
  }
}

# --- sources --------------------------------------------------------------------
# system program (fpga/sys/sw), baseline files it reuses (fpga/sw/src: out, lmhash, exp,
# plat_xil, prof and the headers; not main.c, bench.c, fq_prof.c, plat_host.c), expected-value
# headers, embedded stories260K arrays (generated, not committed), model/src unchanged.
# The same set as the host build fpga/sys/test/Makefile (BSRC, SSRC, CORE) with the board files.
set srcs [lsort [glob -nocomplain -types f [file join $script_dir *.c] [file join $script_dir *.h]]]
if {[llength $srcs] == 0} { error "no sources found in $script_dir" }
set bsw [file join $proj_dir fpga sw]
foreach f {out.c lmhash.c exp.c plat_xil.c prof.c} {
  set p [file join $bsw src $f]
  if {![file exists $p]} { error "baseline source $p missing" }
  lappend srcs $p
}
set srcs [concat $srcs [lsort [glob -nocomplain -types f [file join $bsw src *.h]]]]
set exps [lsort [glob -nocomplain -types f [file join $bsw expect exp_m*.h]]]
if {[llength $exps] < 2} { error "expected-value headers missing in fpga/sw/expect" }
set m1data [file join $bsw gen m1_data.c]
if {![file exists $m1data]} {
  error "fpga/sw/gen/m1_data.c missing (run: make -C fpga/sw/test data, see fpga/README.md)"
}
set msrcs [lsort [glob -nocomplain -types f [file join $proj_dir model src *.c] [file join $proj_dir model src *.h]]]
if {[llength $msrcs] == 0} { error "model/src not found under $proj_dir" }
set all_srcs [concat $srcs $exps [list $m1data] $msrcs]

file mkdir $ws
setws $ws
set plat sys_plat
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

# --- application ------------------------------------------------------------------
# Patch the generated linker script (same patterns as fpga/sw/xsct_build.tcl).
# UNVERIFIED: the lscript.ld lines of the Cortex-A9 template.
proc sys_patch_lscript {path stack heap ddrlen} {
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
sys_patch_lscript [file join $app_src lscript.ld] [dict get $A STACK] [dict get $A HEAP] [dict get $A DDRLEN]
app config -name $app build-config release
app config -name $app compiler-optimization [dict get $opt_names $opt]
# -ffp-contract=off and no -ffast-math: same float evaluation as the PC golden (fpga/README.md)
set misc "-mfpu=$fpu -mfloat-abi=hard -ffp-contract=off"
# UNVERIFIED: a comma-separated value in compiler-misc reaches gcc as one -D argument
if {$list_def ne ""} { append misc " -DSYS_MASK_LIST=$list_def" }
app config -name $app -add compiler-misc $misc
# UNVERIFIED: option name define-compiler-symbols (Vitis classic app config)
foreach sym [list "BUILD_OPT=[string range $opt 1 end]" "SYS_FCLK_HZ=${fclk_hz}u" \
                  "SYS_RUN_MASK=${run_mask}u" "SYS_STEPS=$steps" "SYS_RUN_M1=$m1" "SYS_RUN_M2=$m2"] {
  app config -name $app -add define-compiler-symbols $sym
}
app config -name $app -add libraries m
app config -name $app -add linker-misc "-Wl,--defsym=_STACK_SIZE=[dict get $A STACK] -Wl,--defsym=_HEAP_SIZE=[dict get $A HEAP]"
app build -name $app
set elf [file join $ws $app Release $app.elf]
if {![file exists $elf]} {
  set elf [lindex [glob -nocomplain [file join $ws $app * $app.elf]] 0]
}
if {$elf eq "" || ![file exists $elf]} { error "ELF of $app not found after build" }
puts "INFO: ELF $elf (FCLK_HZ=$fclk_hz RUNS=$runs STEPS=$steps MODELS=$models LIST=[expr {$list_def eq "" ? "default" : $list_def}])"

if {[dict get $A RUN] != 1} {
  puts "INFO: RUN=0, not downloading. To run: RUN=1 with the board in JTAG boot mode, terminal 115200 8N1."
  return
}

# --- JTAG download and run -----------------------------------------------------------
# UNVERIFIED: target filter strings as in the Vitis-generated debugger scripts for Zynq-7000.
set ps7_init [lindex [glob -nocomplain [file join $ws $plat * ps7_init.tcl] \
                                       [file join $ws $plat * * ps7_init.tcl] \
                                       [file join $ws $plat * * * ps7_init.tcl]] 0]
if {$ps7_init eq ""} { error "ps7_init.tcl not found under the platform" }
set bit [dict get $A BIT]
if {$bit eq ""} {
  set bit [lindex [glob -nocomplain [file join [file dirname $ps7_init] *.bit]] 0]
}
if {$bit eq "" || ![file exists $bit]} { error "bitstream not found; pass BIT=<file.bit>" }

connect
targets -set -nocase -filter {name =~ "APU*"}
rst -system
after 2000
targets -set -nocase -filter {name =~ "xc7z020*"}
fpga -file $bit
targets -set -nocase -filter {name =~ "APU*"}
loadhw -hw $xsa -mem-ranges [list {0x40000000 0xbfffffff}] -regs
configparams force-mem-access 1
source $ps7_init
ps7_init
ps7_post_config
targets -set -nocase -filter {name =~ "*A9*#0"}
dow $elf
if {$m2} {
  # addresses: DDR_CK_ADDR / DDR_TK_ADDR of fpga/sw/src/bcfg.h (below the arena 0x18000000)
  puts "INFO: downloading stories15M images (about 61 MB over JTAG, this takes a while)"
  dow -data [dict get $A CK] 0x10000000
  dow -data [dict get $A TK] 0x14000000
}
configparams force-mem-access 0
con
puts "INFO: program started; read the UART (115200 8N1). The log ends with 'LMSYS END'."
