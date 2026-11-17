# xsct_build.tcl: Vitis (classic, XSCT) platform + bare-metal application
# for the PS test program, optional JTAG download and run.
#
# NOT RUN on the preparation machine. Only a syntax / variable check with
# stubbed XSCT commands was done. UNVERIFIED for any Vitis version: the
# platform / app commands below are those of Vitis classic 2019.2 to
# 2023.2. Vitis 2024.1 and later replace the classic workspace flow by the
# Vitis Unified IDE (Python API); there, create the platform and an empty
# C application by hand and add the files of fpga/sw/*.c *.h (see
# fpga/README.md).
#
# Usage:
#   xsct <path>/fpga/sw/xsct_build.tcl XSA=<file.xsa> [WS=<dir>] [RUN=1] [BIT=<file.bit>]
# Arguments:
#   XSA   hardware platform from build.tcl (required)
#   WS    Vitis workspace directory           (<dir of XSA>/vitis_ws)
#   APP   application name                    (pqc_ntt_test)
#   RUN   1: program the PL, init the PS, download and start over JTAG (0)
#   BIT   bitstream for RUN=1                 (the one inside the platform)
#   OPT   compiler optimization flag          (-O2)

set script_dir [file normalize [file dirname [info script]]]

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
set A [pqc_parse_args $argv [dict create XSA "" WS "" APP pqc_ntt_test RUN 0 BIT "" OPT -O2]]
set xsa [dict get $A XSA]
if {$xsa eq "" || ![file exists $xsa]} {
  error "XSA=<file.xsa> is required and must exist (got '$xsa')"
}
set xsa [file normalize $xsa]
set ws [dict get $A WS]
if {$ws eq ""} { set ws [file join [file dirname $xsa] vitis_ws] }
set ws [file normalize $ws]
set app [dict get $A APP]
set plat pqc_plat
set proc_name ps7_cortexa9_0

# Sources: the board files of fpga/sw only (not tools/, test/).
set srcs [lsort [concat [glob -nocomplain -types f [file join $script_dir *.c]] \
                        [glob -nocomplain -types f [file join $script_dir *.h]]]]
if {[llength $srcs] == 0} { error "no sources found in $script_dir" }

file mkdir $ws
setws $ws

# --- platform -----------------------------------------------------------------
# UNVERIFIED: default domain name of "platform create -os -proc" is
# standalone_domain in 2019.2 .. 2022.x, standalone_ps7_cortexa9_0 in some
# later versions; both are tried.
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
# stdin / stdout on UART1 (USB-UART of the Zybo Z7). UNVERIFIED: the BSP
# instance name ps7_uart_1.
bsp config stdin ps7_uart_1
bsp config stdout ps7_uart_1
bsp regenerate
platform generate

# --- application ------------------------------------------------------------
# UNVERIFIED: template name ("Empty Application" before 2022.1,
# "Empty Application(C)" from 2022.1).
set made 0
foreach t {{Empty Application(C)} {Empty Application}} {
  if {![catch {app create -name $app -platform $plat -domain $dom -template $t -lang c}]} {
    set made 1
    break
  }
}
if {!$made} { error "app create failed for both template names" }
set app_src [file join $ws $app src]
file mkdir $app_src
foreach f $srcs {
  file copy -force $f $app_src
}
app config -name $app build-config release
# UNVERIFIED: option strings of compiler-optimization.
set opt_names [dict create -O0 {None (-O0)} -O1 {Optimize (-O1)} -O2 {Optimize more (-O2)} \
                           -O3 {Optimize most (-O3)} -Os {Optimize for size (-Os)}]
set opt [dict get $A OPT]
if {![dict exists $opt_names $opt]} { error "OPT must be one of [dict keys $opt_names]" }
app config -name $app compiler-optimization [dict get $opt_names $opt]
app build -name $app
set elf [file join $ws $app Release $app.elf]
if {![file exists $elf]} {
  set elf [lindex [glob -nocomplain [file join $ws $app * $app.elf]] 0]
}
if {$elf eq "" || ![file exists $elf]} { error "application ELF not found after build" }
puts "INFO: ELF $elf"

if {[dict get $A RUN] != 1} {
  puts "INFO: RUN=0, not downloading. To run: RUN=1 with the board on JTAG, terminal 115200 8N1."
  return
}

# --- JTAG download and run ----------------------------------------------------
# UNVERIFIED: target filter strings ("APU*", "*A9*#0", "xc7z020*") as in
# the Vitis-generated system debugger scripts for Zynq-7000.
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
configparams force-mem-access 0
con
puts "INFO: program started; read the UART (115200 8N1). The run ends with 'PQCNTT END'."
