# create_project.tcl: Vivado project + block design of the system builds (docs/spec/system.md
# 1.2 - 1.7): the L4 top rtl/l4/sys_a_top.sv (build A) or rtl/l4/sys_p_top.sv (build P) through
# the Verilog shell src/sys_<a|p>_bd.v on the Digilent Zybo Z7-20 (xc7z020clg400-1).
# Structure, argument format and checks follow fpga/bw/create_project.tcl.
#
# UNVERIFIED: NOT RUN on the preparation machine (Vivado is not allowed there). Only a
# syntax / variable / control-flow check with stubbed Vivado commands was done
# (fpga/sys/test/stub_check.tcl). Lines marked "UNVERIFIED" depend on the Vivado version.
#
# Block design (system.md 1.3, 1.4, 1.7):
#   ps7 M_AXI_GP0 -> ic_ctrl -> sys_0/s_axi        0x43C0_0000, 64 KiB (axil_xbar: slot = addr[15:12])
#   sys_0/m0<k>_axi -> ic_hp<k> -> ps7/S_AXI_HP<k>  64 bit, for every HP port k the build uses:
#       A  : HP0 gemv_acc (R/W), HP1 attn (R/W), HP3 vec (R/W)            (m02_axi unconnected)
#       A2 : A + HP2 gemv_acc slice 1 (R)
#       P  : HP0 pim (R/W), HP1 attn engine 0 (R/W), HP2 attn engine 1 (R), HP3 vec (R/W)
#       PD : P with the attention KV in DDR (KV_SRC 1), same ports
#   FCLK_CLK0 (FCLK_MHZ) clocks everything, proc_sys_reset from FCLK_RESET0_N,
#   peripheral_aresetn -> sys_0/aresetn. No interrupt (polling, system.md 1.3).
# Each interconnect converts AXI4 (ID 1 bit) to the AXI3 HP port (ID 6 bit), as in fpga/bw.
#
# Usage:
#   vivado -mode batch -source <repo>/fpga/sys/create_project.tcl -tclargs BUILD=A
# Arguments (KEY=VALUE):
#   BUILD     A | P (required); variants A2 (gemv_acc P 2 on HP0 + HP2) and PD (P with DDR KV)
#             of system.md 1.2 / 1.6 are accepted as well
#   VE_NMAX   1024 | 256  vec_top N_MAX (system.md O7; 256 is the first BRAM fallback)  (1024)
#   FCLK_MHZ  requested FCLK_CLK0 in MHz (PS PLL picks the nearest value)              (100)
#   BOARD     auto | yes | no   use the Digilent board files                             (auto)
#   INTC      smartconnect | axi_interconnect                                          (smartconnect)
#   NAME      project name     (sys_<build>[_ve<VE_NMAX> if not 1024]_<fclk>m, lower case)
#   DIR       project directory (<repo>/fpga/sys/build/<NAME>)
#   PART      FPGA part        (xc7z020clg400-1)

set script_dir [file normalize [file dirname [info script]]]
set proj_root  [file normalize [file join $script_dir .. ..]]
source [file join $script_dir filelist.tcl]

# GP0 window of the L4 top: same value as fpga/sys/sw/ipregs.h SYS_BASE (system.md 1.4).
set SYS_BASEADDR 0x43C00000
set SYS_RANGE    0x10000
# Arena of the system program (fpga/sw/src/bcfg.h ARENA_ADDR, ARENA_ADDR + ARENA_CAP): every
# buffer an IP reads or writes is inside it (system.md 1.4), so each HP DDR segment must cover it.
set SYS_ARENA_LO 0x18000000
set SYS_ARENA_HI 0x3FF00000

proc sys_parse_args {arglist defaults} {
  set cfg $defaults
  foreach a $arglist {
    if {![regexp {^([A-Z_]+)=(.*)$} $a -> k v]} { error "argument '$a' is not KEY=VALUE" }
    if {![dict exists $defaults $k]} { error "unknown argument $k (known: [dict keys $defaults])" }
    dict set cfg $k $v
  }
  return $cfg
}

set defaults [dict create BUILD "" VE_NMAX 1024 FCLK_MHZ 100 BOARD auto INTC smartconnect \
                          NAME "" DIR "" PART xc7z020clg400-1]
if {![info exists argv]} { set argv {} }
set A [sys_parse_args $argv $defaults]

# ---------------------------------------------------------------------------
# Build table (system.md 1.2 build table, 1.3 HP ports, 1.7 parameters and slots).
#   top    : A or P (L4 top and shell)
#   hp     : HP ports connected (the others stay disabled on the PS7 and unconnected)
#   params : top parameters set on the module reference (all others keep the top default)
#   slot_en: SLOT_EN of the top (fixed in the RTL, recorded only)
#   dsp, bram36: [계산] values of system.md 1.5 for the comparison in S5-6 (not measured)
# ---------------------------------------------------------------------------
set common [list S_ADDR_W 16 XB_REG 1 IDW 1 MAX_BURST 16 OUTS 4]
set builds [dict create \
  A  [dict create top A hp {0 1 3} slot_en 4'b1101 dsp 60 bram36 {3~3.5} \
        params {GA_P 1 GA_NMAX 1024 GA_IDX_W 16 AT_H_PAR 1 AT_KV_SRC 1 AT_HS_MAX 64 AT_TMAX 512
                VE_N_MAX 1024 VE_IDX_W 16}] \
  A2 [dict create top A hp {0 1 2 3} slot_en 4'b1101 dsp 71 bram36 {3~4} \
        params {GA_P 2 GA_NMAX 1024 GA_IDX_W 16 AT_H_PAR 1 AT_KV_SRC 1 AT_HS_MAX 64 AT_TMAX 512
                VE_N_MAX 1024 VE_IDX_W 16}] \
  P  [dict create top P hp {0 1 2 3} slot_en 4'b1110 dsp 149 bram36 {128~129} \
        params {PI_NB 4 PI_LB 16 PI_DEPTH 4096 AT_H_PAR 2 AT_KV_SRC 0 AT_HS_MAX 8 AT_TMAX 512
                AT_NKV 4 AT_NL 5 AT_KW 12 AT_VW 8 VE_N_MAX 1024 VE_IDX_W 16}] \
  PD [dict create top P hp {0 1 2 3} slot_en 4'b1110 dsp 149 bram36 {66~68} \
        params {PI_NB 4 PI_LB 16 PI_DEPTH 4096 AT_H_PAR 2 AT_KV_SRC 1 AT_HS_MAX 8 AT_TMAX 512
                AT_NKV 4 AT_NL 5 AT_KW 12 AT_VW 8 VE_N_MAX 1024 VE_IDX_W 16}]]

set build [dict get $A BUILD]
if {$build eq ""} { error "BUILD=A or BUILD=P is required (variants: A2, PD)" }
if {![dict exists $builds $build]} { error "BUILD must be one of [dict keys $builds], got $build" }
set B [dict get $builds $build]
set top [dict get $B top]
set hp_used [dict get $B hp]

set ve_nmax [dict get $A VE_NMAX]
if {$ve_nmax ni {1024 256}} { error "VE_NMAX must be 1024 or 256, got $ve_nmax" }
set bparams [dict get $B params]
dict set bparams VE_N_MAX $ve_nmax
set bram36_calc [dict get $B bram36]
if {$ve_nmax == 256} {
  # system.md 1.5: P with vec N_MAX 256 is 126~128; the others are not tabulated
  set bram36_calc [expr {$build eq "P" ? "126~128" : "n/a"}]
}
set fclk [dict get $A FCLK_MHZ]
if {![string is double -strict $fclk] || $fclk < 10 || $fclk > 250} {
  error "FCLK_MHZ must be in \[10, 250\], got $fclk"
}
set fclk_int [expr {int(round($fclk))}]
set intc [dict get $A INTC]
if {$intc ni {smartconnect axi_interconnect}} { error "INTC must be smartconnect or axi_interconnect" }
set board_mode [dict get $A BOARD]
if {$board_mode ni {auto yes no}} { error "BOARD must be auto, yes or no" }
set fclk_tag [string map {. p} $fclk]
set name [dict get $A NAME]
if {$name eq ""} {
  set name "sys_[string tolower $build][expr {$ve_nmax == 1024 ? "" : "_ve$ve_nmax"}]_${fclk_tag}m"
}
set dir [dict get $A DIR]
if {$dir eq ""} { set dir [file join $script_dir build $name] }
set part [dict get $A PART]
set shell [expr {$top eq "A" ? "sys_a_bd" : "sys_p_bd"}]
# all parameters set on the module reference, in this order
set allparams [concat $common [list FCLK_MHZ $fclk_int] $bparams]

puts "INFO: sys create_project name=$name BUILD=$build top=$shell HP=$hp_used FCLK_MHZ=$fclk INTC=$intc"

proc sys_latest_vlnv {ipname} {
  set defs [get_ipdefs -all -quiet "xilinx.com:ip:${ipname}:*"]
  if {[llength $defs] == 0} { error "IP $ipname not found in the IP catalog (get_ipdefs)" }
  set best ""
  set bestv {}
  foreach d $defs {
    set v [split [lindex [split $d :] end] .]
    if {$best eq "" || [sys_version_gt $v $bestv]} { set best $d; set bestv $v }
  }
  return $best
}
proc sys_version_gt {a b} {
  foreach x $a y $b {
    if {$x eq ""} { set x 0 }
    if {$y eq ""} { set y 0 }
    if {$x > $y} { return 1 }
    if {$x < $y} { return 0 }
  }
  return 0
}
# Set one CONFIG.* property; warn instead of failing when the name is unknown.
proc sys_set_cfg {cell prop value} {
  if {[catch {set_property CONFIG.$prop $value $cell} msg]} {
    puts "WARNING: could not set CONFIG.$prop = $value on $cell: $msg"
    return 0
  }
  return 1
}

# ---------------------------------------------------------------------------
# Project and sources
# ---------------------------------------------------------------------------
file mkdir $dir
create_project -force $name $dir -part $part

set board_part ""
if {$board_mode ne "no"} {
  # UNVERIFIED: Digilent board part name (digilentinc.com:zybo-z7-20:part0:<ver>).
  set bps [get_board_parts -quiet -latest_file_version {*zybo-z7-20*}]
  if {[llength $bps] > 0} {
    set board_part [lindex [lsort $bps] end]
    set_property board_part $board_part [current_project]
    puts "INFO: board part $board_part"
  } elseif {$board_mode eq "yes"} {
    error "BOARD=yes but no Zybo Z7-20 board files found (install the Digilent vivado-boards repository)"
  } else {
    puts "WARNING: Zybo Z7-20 board files not found, using part $part and manual PS7 settings (DDR board delays not set)"
  }
}

set_property target_language Verilog [current_project]
set srcs [sys_filelist $proj_root $top]
add_files -norecurse -fileset sources_1 $srcs
foreach f $srcs {
  if {[string match *.sv $f]} {
    set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] $f]
  }
}
add_files -norecurse -fileset constrs_1 [file join $script_dir zybo_z7_20.xdc]
update_compile_order -fileset sources_1

# ---------------------------------------------------------------------------
# Block design
# ---------------------------------------------------------------------------
set bd_name sys_bd
create_bd_design $bd_name

set ps [create_bd_cell -type ip -vlnv [sys_latest_vlnv processing_system7] ps7]
# UNVERIFIED: rule and option names of the PS7 automation (stable since 2014.x).
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
  -config [list make_external "FIXED_IO, DDR" apply_board_preset [expr {$board_part ne "" ? 1 : 0}] \
                Master Disable Slave Disable] $ps

if {$board_part eq ""} {
  # UNVERIFIED: values from the Zybo Z7 reference manual, DDR board delays not set (training
  # on). Same list as fpga/bw/create_project.tcl.
  foreach {p v} {
    PCW_PRESET_BANK0_VOLTAGE          {LVCMOS 3.3V}
    PCW_PRESET_BANK1_VOLTAGE          {LVCMOS 1.8V}
    PCW_CRYSTAL_PERIPHERAL_FREQMHZ    33.333333
    PCW_APU_PERIPHERAL_FREQMHZ        667
    PCW_UIPARAM_DDR_MEMORY_TYPE       {DDR 3 (Low Voltage)}
    PCW_UIPARAM_DDR_PARTNO            {MT41K256M16 RE-125}
    PCW_UIPARAM_DDR_BUS_WIDTH         {32 Bit}
    PCW_UIPARAM_DDR_TRAIN_WRITE_LEVEL 1
    PCW_UIPARAM_DDR_TRAIN_READ_GATE   1
    PCW_UIPARAM_DDR_TRAIN_DATA_EYE    1
  } {
    sys_set_cfg $ps $p $v
  }
}
# UNVERIFIED: property names PCW_USE_S_AXI_HPn, PCW_S_AXI_HPn_DATA_WIDTH.
set ps_cfg [list \
    PCW_UART1_PERIPHERAL_ENABLE 1 \
    PCW_UART1_UART1_IO          {MIO 48 .. 49} \
    PCW_UART1_BAUD_RATE         115200 \
    PCW_USE_M_AXI_GP0           1 \
    PCW_EN_CLK0_PORT            1 \
    PCW_EN_RST0_PORT            1 \
    PCW_FPGA0_PERIPHERAL_FREQMHZ $fclk]
foreach k $hp_used {
  lappend ps_cfg PCW_USE_S_AXI_HP$k 1 PCW_S_AXI_HP${k}_DATA_WIDTH 64
}
foreach {p v} $ps_cfg {
  if {![sys_set_cfg $ps $p $v] && [string match PCW_*S_AXI_HP* $p]} {
    error "cannot enable $p on the PS7 (property name differs in this Vivado version?)"
  }
}

set rst [create_bd_cell -type ip -vlnv [sys_latest_vlnv proc_sys_reset] rst_ps7]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins rst_ps7/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst_ps7/ext_reset_in]

# L4 top. UNVERIFIED: module reference of a Verilog shell whose sub-modules are SystemVerilog
# (accepted in 2020.x and later as far as known; same risk as fpga/bw).
set sys [create_bd_cell -type module -reference $shell sys_0]
foreach {p v} $allparams {
  if {![sys_set_cfg $sys $p $v]} { error "cannot set parameter $p of $shell" }
}
foreach ifn {s_axi m00_axi m01_axi m02_axi m03_axi} {
  if {[llength [get_bd_intf_pins -quiet sys_0/$ifn]] != 1} {
    error "interface sys_0/$ifn was not inferred from the port names"
  }
}

set clk [get_bd_pins ps7/FCLK_CLK0]
# one interconnect with 1 SI and 1 MI
proc sys_ic {name intc clk} {
  set ic [create_bd_cell -type ip -vlnv [sys_latest_vlnv $intc] $name]
  sys_set_cfg $ic NUM_SI 1
  sys_set_cfg $ic NUM_MI 1
  if {$intc eq "smartconnect"} {
    connect_bd_net $clk [get_bd_pins $name/aclk]
    connect_bd_net [get_bd_pins rst_ps7/interconnect_aresetn] [get_bd_pins $name/aresetn]
  } else {
    foreach p {ACLK S00_ACLK M00_ACLK} { connect_bd_net $clk [get_bd_pins $name/$p] }
    connect_bd_net [get_bd_pins rst_ps7/interconnect_aresetn] [get_bd_pins $name/ARESETN]
    foreach p {S00_ARESETN M00_ARESETN} {
      connect_bd_net [get_bd_pins rst_ps7/peripheral_aresetn] [get_bd_pins $name/$p]
    }
  }
  return $ic
}

sys_ic ic_ctrl $intc $clk
connect_bd_net $clk [get_bd_pins ps7/M_AXI_GP0_ACLK]
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins ic_ctrl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ic_ctrl/M00_AXI] [get_bd_intf_pins sys_0/s_axi]

foreach k $hp_used {
  sys_ic ic_hp$k $intc $clk
  connect_bd_net $clk [get_bd_pins ps7/S_AXI_HP${k}_ACLK]
  connect_bd_intf_net [get_bd_intf_pins sys_0/m0${k}_axi] [get_bd_intf_pins ic_hp$k/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins ic_hp$k/M00_AXI] [get_bd_intf_pins ps7/S_AXI_HP$k]
}
connect_bd_net $clk [get_bd_pins sys_0/aclk]
connect_bd_net [get_bd_pins rst_ps7/peripheral_aresetn] [get_bd_pins sys_0/aresetn]

# Addresses. UNVERIFIED: segment names differ between versions; looked up by filter.
assign_bd_address
set seg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces ps7/Data] -filter {NAME =~ "*sys_0*"}]
if {[llength $seg] != 1} { set seg [get_bd_addr_segs -quiet ps7/Data/*sys_0*] }
if {[llength $seg] != 1} { error "cannot find the address segment of sys_0 in ps7/Data (found '$seg')" }
set_property range  $SYS_RANGE    $seg
set_property offset $SYS_BASEADDR $seg
if {[expr {[get_property offset $seg]}] != [expr {$SYS_BASEADDR}]} {
  error "address of sys_0 is [get_property offset $seg], expected $SYS_BASEADDR"
}
if {[expr {[get_property range $seg]}] != [expr {$SYS_RANGE}]} {
  error "range of sys_0 is [get_property range $seg], expected $SYS_RANGE"
}
# the DDR segment seen by each connected master must cover the arena of the system program
set ddr_segs {}
foreach k $hp_used {
  set m m0${k}_axi
  set ddr [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces sys_0/$m] -filter {NAME =~ "*DDR*"}]
  if {[llength $ddr] < 1} { error "sys_0/$m has no DDR segment after assign_bd_address" }
  set d [lindex $ddr 0]
  set off [expr {[get_property offset $d]}]
  set rng [expr {[get_property range $d]}]
  if {$off > $SYS_ARENA_LO || $off + $rng < $SYS_ARENA_HI} {
    error "sys_0/$m DDR segment [format 0x%08X $off] + [format 0x%X $rng] does not cover the arena\
           [format 0x%08X $SYS_ARENA_LO]..[format 0x%08X $SYS_ARENA_HI]"
  }
  lappend ddr_segs "HP$k [format 0x%08X $off] [format 0x%X $rng]"
  puts "INFO: sys_0/$m (HP$k) DDR segment [format 0x%08X $off] range [format 0x%X $rng]"
}

validate_bd_design
save_bd_design

set bd_file [get_files -of_objects [get_filesets sources_1] ${bd_name}.bd]
generate_target all $bd_file
set wrapper [make_wrapper -files $bd_file -top]
add_files -norecurse -fileset sources_1 $wrapper
set_property top ${bd_name}_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1

# UNVERIFIED: property name PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ.
set fclk_act "unknown"
catch {set fclk_act [get_property CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ $ps]}

set fp [open [file join $dir sys_build_config.txt] w]
puts $fp "name $name"
puts $fp "build $build"
puts $fp "top sys_[string tolower $top]_top"
puts $fp "shell $shell"
puts $fp "part $part"
puts $fp "board_part $board_part"
puts $fp "hp_used $hp_used"
foreach s $ddr_segs { puts $fp "hp_ddr_segment $s" }
puts $fp "slot_en [dict get $B slot_en]"
puts $fp "baseaddr $SYS_BASEADDR"
puts $fp "range $SYS_RANGE"
foreach {p v} $allparams { puts $fp "param $p $v" }
puts $fp "fclk_mhz_requested $fclk"
puts $fp "fclk_mhz_actual $fclk_act"
puts $fp "intc $intc"
puts $fp "dsp_calc [dict get $B dsp]"
puts $fp "bram36_calc $bram36_calc"
puts $fp "vivado [version -short]"
close $fp

puts "INFO: sys project ready: [file join $dir $name.xpr]"
puts "INFO: FCLK_CLK0 requested $fclk MHz, actual $fclk_act MHz (the PS program needs the actual value: FCLK_HZ)"
puts "INFO: next: vivado -mode batch -source [file join $script_dir build.tcl] -tclargs PROJ=[file join $dir $name.xpr]"
