# create_project.tcl: Vivado project + block design of the HP bandwidth measurement build
# (rtl/l3/bw_top.sv through the shell src/bw_bd.v) on the Digilent Zybo Z7-20
# (xc7z020clg400-1). docs/spec/bwtest.md is the register map.
#
# UNVERIFIED: NOT RUN on the preparation machine (Vivado is not allowed there). Only a
# syntax / variable / control-flow check with stubbed Vivado commands was done
# (fpga/bw/test/stub_check.tcl). Lines marked "UNVERIFIED" depend on the Vivado version.
#
# Block design:
#   ps7 (M_AXI_GP0 -> ctrl interconnect -> bw_0/s_axi at 0x43C00000, 4 KiB)
#   bw_0/m00_axi -> hp0 interconnect -> ps7/S_AXI_HP0 (64 bit)
#   bw_0/m01_axi -> hp2 interconnect -> ps7/S_AXI_HP2 (64 bit)      only with P=2
#   FCLK_CLK0 (FCLK_MHZ) clocks everything, proc_sys_reset from FCLK_RESET0_N.
# The interconnects convert the AXI4 masters to the AXI3 HP ports (burst length > 16 is
# split there when MAX_BURST > 16). HP0 and HP2 are used for P = 2 because HP0/HP1 and
# HP2/HP3 share one DDR controller port each (arch.md 7.1, [미확인]).
#
# Usage:
#   vivado -mode batch -source <repo>/fpga/bw/create_project.tcl -tclargs P=1 MAX_BURST=16 OUTS=4
# Arguments (KEY=VALUE, all optional):
#   P          1 | 2  ports (engines on HP0, and HP2 for 2)                    (1)
#   MAX_BURST  1..256 engine burst limit; runtime BURST register <= this       (16)
#   OUTS       1..64  engine outstanding limit; runtime OUTS register <= this  (4)
#   FCLK_MHZ   requested FCLK_CLK0 in MHz (PS PLL picks the nearest value)      (100)
#   BOARD      auto | yes | no   use the Digilent board files                   (auto)
#   INTC       smartconnect | axi_interconnect                                 (smartconnect)
#   NAME       project name     (bw_p<P>_b<MAX_BURST>_o<OUTS>_<fclk>m)
#   DIR        project directory (<repo>/fpga/bw/build/<NAME>)
#   PART       FPGA part        (xc7z020clg400-1)

set script_dir [file normalize [file dirname [info script]]]
set proj_root  [file normalize [file join $script_dir .. ..]]
source [file join $script_dir filelist.tcl]

# Address of the CSR. Same value as fpga/bw/sw/bw_regs.h (BW_BASEADDR).
set BW_BASEADDR 0x43C00000
set BW_RANGE    0x1000
# Buffers used by the PS program (bw_regs.h BW_BUF_*): must be reachable through HP0/HP2.
set BW_BUF_LO   0x10000000
set BW_BUF_HI   0x20000000

proc bw_parse_args {arglist defaults} {
  set cfg $defaults
  foreach a $arglist {
    if {![regexp {^([A-Z_]+)=(.*)$} $a -> k v]} { error "argument '$a' is not KEY=VALUE" }
    if {![dict exists $defaults $k]} { error "unknown argument $k (known: [dict keys $defaults])" }
    dict set cfg $k $v
  }
  return $cfg
}

set defaults [dict create P 1 MAX_BURST 16 OUTS 4 FCLK_MHZ 100 BOARD auto INTC smartconnect \
                          NAME "" DIR "" PART xc7z020clg400-1]
if {![info exists argv]} { set argv {} }
set A [bw_parse_args $argv $defaults]

set nport [dict get $A P]
if {$nport ni {1 2}} { error "P must be 1 or 2, got $nport" }
set max_burst [dict get $A MAX_BURST]
if {![string is integer -strict $max_burst] || $max_burst < 1 || $max_burst > 256} {
  error "MAX_BURST must be in 1..256, got $max_burst"
}
set outs [dict get $A OUTS]
if {![string is integer -strict $outs] || $outs < 1 || $outs > 64} {
  error "OUTS must be in 1..64, got $outs"
}
set fclk [dict get $A FCLK_MHZ]
if {![string is double -strict $fclk] || $fclk < 10 || $fclk > 250} {
  error "FCLK_MHZ must be in \[10, 250\], got $fclk"
}
set intc [dict get $A INTC]
if {$intc ni {smartconnect axi_interconnect}} { error "INTC must be smartconnect or axi_interconnect" }
set board_mode [dict get $A BOARD]
if {$board_mode ni {auto yes no}} { error "BOARD must be auto, yes or no" }
set fclk_tag [string map {. p} $fclk]
set name [dict get $A NAME]
if {$name eq ""} { set name "bw_p${nport}_b${max_burst}_o${outs}_${fclk_tag}m" }
set dir [dict get $A DIR]
if {$dir eq ""} { set dir [file join $script_dir build $name] }
set part [dict get $A PART]

puts "INFO: bw create_project name=$name P=$nport MAX_BURST=$max_burst OUTS=$outs FCLK_MHZ=$fclk INTC=$intc"

proc bw_latest_vlnv {ipname} {
  set defs [get_ipdefs -all -quiet "xilinx.com:ip:${ipname}:*"]
  if {[llength $defs] == 0} { error "IP $ipname not found in the IP catalog (get_ipdefs)" }
  set best ""
  set bestv {}
  foreach d $defs {
    set v [split [lindex [split $d :] end] .]
    if {$best eq "" || [bw_version_gt $v $bestv]} { set best $d; set bestv $v }
  }
  return $best
}
proc bw_version_gt {a b} {
  foreach x $a y $b {
    if {$x eq ""} { set x 0 }
    if {$y eq ""} { set y 0 }
    if {$x > $y} { return 1 }
    if {$x < $y} { return 0 }
  }
  return 0
}
# Set one CONFIG.* property; warn instead of failing when the name is unknown.
proc bw_set_cfg {cell prop value} {
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
set srcs [bw_filelist $proj_root]
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
set bd_name bw_bd_sys
create_bd_design $bd_name

set ps [create_bd_cell -type ip -vlnv [bw_latest_vlnv processing_system7] ps7]
# UNVERIFIED: rule and option names of the PS7 automation (stable since 2014.x).
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
  -config [list make_external "FIXED_IO, DDR" apply_board_preset [expr {$board_part ne "" ? 1 : 0}] \
                Master Disable Slave Disable] $ps

if {$board_part eq ""} {
  # UNVERIFIED: values from the Zybo Z7 reference manual, DDR board delays not set (training
  # on). Same list as pqc-ntt-ip fpga/vivado/create_project.tcl.
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
    bw_set_cfg $ps $p $v
  }
}
# UNVERIFIED: property names PCW_USE_S_AXI_HPn, PCW_S_AXI_HPn_DATA_WIDTH.
set ps_cfg [list \
    PCW_UART1_PERIPHERAL_ENABLE 1 \
    PCW_UART1_UART1_IO          {MIO 48 .. 49} \
    PCW_UART1_BAUD_RATE         115200 \
    PCW_USE_M_AXI_GP0           1 \
    PCW_USE_S_AXI_HP0           1 \
    PCW_S_AXI_HP0_DATA_WIDTH    64 \
    PCW_EN_CLK0_PORT            1 \
    PCW_EN_RST0_PORT            1 \
    PCW_FPGA0_PERIPHERAL_FREQMHZ $fclk]
if {$nport == 2} {
  lappend ps_cfg PCW_USE_S_AXI_HP2 1 PCW_S_AXI_HP2_DATA_WIDTH 64
}
foreach {p v} $ps_cfg {
  if {![bw_set_cfg $ps $p $v] && [string match PCW_*S_AXI_HP* $p]} {
    error "cannot enable $p on the PS7 (property name differs in this Vivado version?)"
  }
}

set rst [create_bd_cell -type ip -vlnv [bw_latest_vlnv proc_sys_reset] rst_ps7]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins rst_ps7/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst_ps7/ext_reset_in]

# IP under test. UNVERIFIED: module reference of a Verilog shell whose sub-modules are
# SystemVerilog (accepted in 2020.x and later as far as known).
set bw [create_bd_cell -type module -reference bw_bd bw_0]
foreach {p v} [list P $nport MAX_BURST $max_burst OUTS $outs FCLK_MHZ [expr {int(round($fclk))}]] {
  if {![bw_set_cfg $bw $p $v]} { error "cannot set parameter $p of bw_bd" }
}
foreach ifn {s_axi m00_axi m01_axi} {
  if {[llength [get_bd_intf_pins -quiet bw_0/$ifn]] != 1} {
    error "interface bw_0/$ifn was not inferred from the port names"
  }
}

set clk [get_bd_pins ps7/FCLK_CLK0]
# one interconnect with 1 SI and 1 MI
proc bw_ic {name intc clk} {
  set ic [create_bd_cell -type ip -vlnv [bw_latest_vlnv $intc] $name]
  bw_set_cfg $ic NUM_SI 1
  bw_set_cfg $ic NUM_MI 1
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

bw_ic ic_ctrl $intc $clk
connect_bd_net $clk [get_bd_pins ps7/M_AXI_GP0_ACLK]
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins ic_ctrl/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ic_ctrl/M00_AXI] [get_bd_intf_pins bw_0/s_axi]

bw_ic ic_hp0 $intc $clk
connect_bd_net $clk [get_bd_pins ps7/S_AXI_HP0_ACLK]
connect_bd_intf_net [get_bd_intf_pins bw_0/m00_axi] [get_bd_intf_pins ic_hp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ic_hp0/M00_AXI] [get_bd_intf_pins ps7/S_AXI_HP0]
if {$nport == 2} {
  bw_ic ic_hp2 $intc $clk
  connect_bd_net $clk [get_bd_pins ps7/S_AXI_HP2_ACLK]
  connect_bd_intf_net [get_bd_intf_pins bw_0/m01_axi] [get_bd_intf_pins ic_hp2/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins ic_hp2/M00_AXI] [get_bd_intf_pins ps7/S_AXI_HP2]
}
connect_bd_net $clk [get_bd_pins bw_0/aclk]
connect_bd_net [get_bd_pins rst_ps7/peripheral_aresetn] [get_bd_pins bw_0/aresetn]

# Addresses. UNVERIFIED: segment names differ between versions; looked up by filter.
assign_bd_address
set seg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces ps7/Data] -filter {NAME =~ "*bw_0*"}]
if {[llength $seg] != 1} { set seg [get_bd_addr_segs -quiet ps7/Data/*bw_0*] }
if {[llength $seg] != 1} { error "cannot find the address segment of bw_0 in ps7/Data (found '$seg')" }
set_property range  $BW_RANGE    $seg
set_property offset $BW_BASEADDR $seg
if {[expr {[get_property offset $seg]}] != [expr {$BW_BASEADDR}]} {
  error "address of bw_0 is [get_property offset $seg], expected $BW_BASEADDR"
}
# the DDR segment seen by each master must cover the buffers of the PS program
set masters [list m00_axi]
if {$nport == 2} { lappend masters m01_axi }
foreach m $masters {
  set ddr [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces bw_0/$m] -filter {NAME =~ "*DDR*"}]
  if {[llength $ddr] < 1} { error "bw_0/$m has no DDR segment after assign_bd_address" }
  set d [lindex $ddr 0]
  set off [expr {[get_property offset $d]}]
  set rng [expr {[get_property range $d]}]
  if {$off > $BW_BUF_LO || $off + $rng < $BW_BUF_HI} {
    error "bw_0/$m DDR segment [format 0x%08X $off] + [format 0x%X $rng] does not cover the buffers"
  }
  puts "INFO: bw_0/$m DDR segment [format 0x%08X $off] range [format 0x%X $rng]"
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

set fp [open [file join $dir bw_build_config.txt] w]
puts $fp "name $name"
puts $fp "part $part"
puts $fp "board_part $board_part"
puts $fp "p $nport"
puts $fp "max_burst $max_burst"
puts $fp "outs $outs"
puts $fp "fclk_mhz_requested $fclk"
puts $fp "fclk_mhz_actual $fclk_act"
puts $fp "intc $intc"
puts $fp "baseaddr $BW_BASEADDR"
puts $fp "vivado [version -short]"
close $fp

puts "INFO: bw project ready: [file join $dir $name.xpr]"
puts "INFO: FCLK_CLK0 requested $fclk MHz, actual $fclk_act MHz (the PS program needs the actual value: FCLK_HZ)"
puts "INFO: next: vivado -mode batch -source [file join $script_dir build.tcl] -tclargs PROJ=[file join $dir $name.xpr]"
