# xsct_build.tcl: Vitis (classic, XSCT) platform + bare-metal application for the HP
# bandwidth program (fpga/bw/sw), optional JTAG download and run. Adapted from pqc-ntt-ip
# fpga/sw/xsct_build.tcl (sources, names, FCLK_HZ symbol).
#
# UNVERIFIED: NOT RUN on the preparation machine. Only a syntax / variable check with
# stubbed XSCT commands was done. UNVERIFIED for any Vitis version: the
# platform / app commands below are those of Vitis classic 2019.2 to
# 2023.2. Vitis 2024.1 and later replace the classic workspace flow by the
# Vitis Unified IDE (Python API); there, create the platform and an empty
# C application by hand and add fpga/bw/sw/*.c *.h with the compiler symbol
# FCLK_HZ (see fpga/bw/README.md).
#
# Usage:
#   xsct <repo>/fpga/bw/sw/xsct_build.tcl XSA=<file.xsa> FCLK_HZ=<actual FCLK> [WS=<dir>] [RUN=1]
# Arguments:
#   XSA   hardware platform from build.tcl (required)
#   WS    Vitis workspace directory           (<dir of XSA>/vitis_ws)
#   APP   application name                    (bw_test)
#   FCLK_HZ  actual PL clock in Hz (create_project.tcl prints it), C symbol FCLK_HZ (100000000)
#   RUN   1: program the PL, init the PS, download and start over JTAG (0)
#   BIT   bitstream for RUN=1                 (the one inside the platform)
#   OPT   compiler optimization flag          (-O2)

set script_dir [file normalize [file dirname [info script]]]

proc bw_parse_args {arglist defaults} {
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
set A [bw_parse_args $argv [dict create XSA "" WS "" APP bw_test RUN 0 BIT "" OPT -O2 FCLK_HZ 100000000]]
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
if {$ws eq ""} { set ws [file join [file dirname $xsa] vitis_ws] }
set ws [file normalize $ws]
set app [dict get $A APP]
set plat bw_plat
set proc_name ps7_cortexa9_0

# Sources: the board files of fpga/bw/sw only (the host model is in fpga/bw/test).
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
# UNVERIFIED: option name define-compiler-symbols (Vitis classic app config).
app config -name $app define-compiler-symbols "FCLK_HZ=${fclk_hz}u"
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
puts "INFO: program started; read the UART (115200 8N1). The run ends with 'BWTEST END'."
