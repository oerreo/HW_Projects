# create_project.tcl: Vivado project + block design for pqc_ntt_axi_top on
# the Digilent Zybo Z7-20 (xc7z020clg400-1).
#
# NOT RUN on the preparation machine (Vivado is not allowed there). Only a
# syntax / variable check with stubbed Vivado commands was done
# (fpga/vivado/test/stub_check.tcl). Lines marked "UNVERIFIED" depend on the
# Vivado version; each says how to check it.
#
# Usage (from any directory):
#   vivado -mode batch -source <path>/fpga/vivado/create_project.tcl \
#          -tclargs ALGO=BARRETT CFG=l0 FCLK_MHZ=100
# Arguments (KEY=VALUE, all optional):
#   ALGO        BARRETT | MONT12 | SHIFTADD | K2RED | 0..3      (BARRETT)
#   IMPL        rtl | hls   L0 mod_mul / mod_red source            (rtl)
#   CFG         bfu pipeline preset (PRE_REG MUL_REG RED_PIPE OUT_REG)
#                 l0 = 0 0 0 0, l1 = 0 1 0 0, l2 = 0 1 1 0,
#                 l3 = 0 1 1 1, l4 = 1 1 1 1, l5 = 1 1 2 1          (l0)
#   PRE_REG MUL_REG RED_PIPE OUT_REG   override single values of CFG
#   SHARE_ADDSUB 0 | 1                                              (0)
#   ROM_OUT_REG  0 | 1                                              (1)
#   FCLK_MHZ    requested FCLK_CLK0 in MHz; the PS PLL picks the
#               nearest reachable value, printed at the end         (100)
#   BOARD       auto | yes | no   use Digilent board files          (auto)
#   INTC        smartconnect | axi_interconnect                    (smartconnect)
#   REF_TOP     shell | direct    module reference of the Verilog
#               shell pqc_ntt_axi_bd (default) or of pqc_ntt_axi_top (shell)
#   NAME        project name          (pqc_<algo>_<impl>_<cfg>_<fclk>m)
#   DIR         project directory     (<repo>/fpga/vivado/build/<NAME>)
#   PART        FPGA part             (xc7z020clg400-1)

set script_dir [file normalize [file dirname [info script]]]
set proj_root  [file normalize [file join $script_dir .. ..]]
source [file join $script_dir filelist.tcl]

# Address map of the IP. Same values as fpga/sw/pqc_ntt_regs.h
# (PQC_NTT_DEFAULT_BASEADDR, PQC_NTT_ADDR_RANGE); check_regs.py compares.
set PQC_BASEADDR 0x43C00000
set PQC_RANGE    0x1000

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
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

set defaults [dict create \
  ALGO BARRETT IMPL rtl CFG l0 \
  PRE_REG "" MUL_REG "" RED_PIPE "" OUT_REG "" \
  SHARE_ADDSUB 0 ROM_OUT_REG 1 FCLK_MHZ 100 \
  BOARD auto INTC smartconnect REF_TOP shell \
  NAME "" DIR "" PART xc7z020clg400-1]
if {![info exists argv]} { set argv {} }
set A [pqc_parse_args $argv $defaults]

set algo_names {BARRETT MONT12 SHIFTADD K2RED}
set algo_arg [string toupper [dict get $A ALGO]]
if {[string is integer -strict $algo_arg]} {
  set algo_id $algo_arg
} else {
  set algo_id [lsearch -exact $algo_names $algo_arg]
}
if {$algo_id < 0 || $algo_id > 3} {
  error "ALGO must be one of $algo_names or 0..3, got [dict get $A ALGO]"
}
set algo_name [lindex $algo_names $algo_id]

set presets [dict create \
  l0 {0 0 0 0} l1 {0 1 0 0} l2 {0 1 1 0} l3 {0 1 1 1} l4 {1 1 1 1} l5 {1 1 2 1}]
set cfg_name [dict get $A CFG]
if {![dict exists $presets $cfg_name]} {
  error "CFG must be one of [dict keys $presets], got $cfg_name"
}
lassign [dict get $presets $cfg_name] PRE_REG MUL_REG RED_PIPE OUT_REG
foreach p {PRE_REG MUL_REG RED_PIPE OUT_REG} {
  if {[dict get $A $p] ne ""} {
    set $p [dict get $A $p]
    set cfg_name custom
  }
}
set SHARE_ADDSUB [dict get $A SHARE_ADDSUB]
set ROM_OUT_REG  [dict get $A ROM_OUT_REG]
# Same ranges as rtl/l1/bfu.sv (elaboration would fail anyway).
foreach {p lo hi} [list PRE_REG 0 1 MUL_REG 0 1 RED_PIPE 0 2 OUT_REG 0 1 SHARE_ADDSUB 0 1 ROM_OUT_REG 0 1] {
  set v [set $p]
  if {![string is integer -strict $v] || $v < $lo || $v > $hi} {
    error "$p must be in $lo..$hi, got $v"
  }
}
if {$SHARE_ADDSUB == 1 && ($PRE_REG + $MUL_REG + $RED_PIPE) == 0} {
  error "SHARE_ADDSUB = 1 needs PRE_REG + MUL_REG + RED_PIPE >= 1 (arch.md, bfu pipeline)"
}
set BFU_LATENCY [expr {$PRE_REG + $MUL_REG + $RED_PIPE + $OUT_REG}]

set impl [dict get $A IMPL]
if {$impl ni {rtl hls}} { error "IMPL must be rtl or hls, got $impl" }
if {$impl eq "hls" && ($MUL_REG + $RED_PIPE) > 2} {
  error "IMPL=hls has no mod_mul build with MUL_REG + RED_PIPE = 3 (hls/l0/README.md)"
}
set fclk [dict get $A FCLK_MHZ]
if {![string is double -strict $fclk] || $fclk <= 0 || $fclk > 250} {
  error "FCLK_MHZ must be in (0, 250], got $fclk"
}
set intc [dict get $A INTC]
if {$intc ni {smartconnect axi_interconnect}} { error "INTC must be smartconnect or axi_interconnect" }
set ref_top_mode [dict get $A REF_TOP]
if {$ref_top_mode ni {shell direct}} { error "REF_TOP must be shell or direct" }
set ref_top [expr {$ref_top_mode eq "shell" ? "pqc_ntt_axi_bd" : "pqc_ntt_axi_top"}]
set board_mode [dict get $A BOARD]
if {$board_mode ni {auto yes no}} { error "BOARD must be auto, yes or no" }

set fclk_tag [string map {. p} $fclk]
set name [dict get $A NAME]
if {$name eq ""} {
  set name "pqc_[string tolower $algo_name]_${impl}_${cfg_name}_${fclk_tag}m"
}
set dir [dict get $A DIR]
if {$dir eq ""} { set dir [file join $script_dir build $name] }
set part [dict get $A PART]

puts "INFO: pqc create_project name=$name ALGO=${algo_name}(${algo_id}) IMPL=$impl CFG=$cfg_name\
      PRE_REG=$PRE_REG MUL_REG=$MUL_REG RED_PIPE=$RED_PIPE OUT_REG=$OUT_REG\
      SHARE_ADDSUB=$SHARE_ADDSUB ROM_OUT_REG=$ROM_OUT_REG BFU_LATENCY=$BFU_LATENCY FCLK_MHZ=$fclk"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Latest available VLNV of a Xilinx IP (no version pinned in this script).
proc pqc_latest_vlnv {ipname} {
  set defs [get_ipdefs -all -quiet "xilinx.com:ip:${ipname}:*"]
  if {[llength $defs] == 0} {
    error "IP $ipname not found in the IP catalog (get_ipdefs)"
  }
  # lsort -dictionary orders 5.5 after 5.10 wrongly; compare numerically.
  set best ""
  set bestv {}
  foreach d $defs {
    set v [split [lindex [split $d :] end] .]
    if {$best eq "" || [pqc_version_gt $v $bestv]} {
      set best $d
      set bestv $v
    }
  }
  return $best
}

proc pqc_version_gt {a b} {
  foreach x $a y $b {
    if {$x eq ""} { set x 0 }
    if {$y eq ""} { set y 0 }
    if {$x > $y} { return 1 }
    if {$x < $y} { return 0 }
  }
  return 0
}

# Set one CONFIG.* property; warn instead of failing when this Vivado
# version does not know the property (names differ between versions).
proc pqc_set_cfg {cell prop value} {
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
  # UNVERIFIED: board part name of the Digilent files
  # (digilentinc.com:zybo-z7-20:part0:<ver>). Check with
  #   get_board_parts *zybo*
  set bps [get_board_parts -quiet -latest_file_version {*zybo-z7-20*}]
  if {[llength $bps] > 0} {
    set board_part [lindex [lsort $bps] end]
    set_property board_part $board_part [current_project]
    puts "INFO: board part $board_part"
  } elseif {$board_mode eq "yes"} {
    error "BOARD=yes but no Zybo Z7-20 board files found (install the Digilent vivado-boards repository)"
  } else {
    puts "WARNING: Digilent Zybo Z7-20 board files not found, using part $part and the manual PS7 settings below (less tested, see fpga/README.md)"
  }
}

set_property target_language Verilog [current_project]
set srcs [pqc_filelist $proj_root $impl]
add_files -norecurse -fileset sources_1 $srcs
foreach f $srcs {
  if {[string match *.sv $f]} {
    set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] $f]
  }
}
add_files -norecurse -fileset constrs_1 [file join $script_dir zybo_z7_20.xdc]
update_compile_order -fileset sources_1

set have_l4 [llength [glob -nocomplain -types f [file join $proj_root rtl l4 *.sv]]]
if {!$have_l4} {
  puts "WARNING: rtl/l4 (pqc_ntt_axi_top) does not exist yet: project created with sources only,\
        block design skipped. Re-run this script when the L4 RTL is in place."
  set fp [open [file join $dir pqc_build_config.txt] w]
  puts $fp "name $name\nstatus sources_only"
  close $fp
  return
}

# ---------------------------------------------------------------------------
# Block design: PS7 + proc_sys_reset + interconnect + pqc_ntt
# ---------------------------------------------------------------------------
set bd_name pqc_bd
create_bd_design $bd_name

# Zynq PS
set ps [create_bd_cell -type ip -vlnv [pqc_latest_vlnv processing_system7] ps7]
# UNVERIFIED: rule and option names of the PS7 automation (stable since
# 2014.x in Xilinx examples). apply_board_preset 1 loads the Digilent preset
# (DDR, MIO, clocks); without board files the preset is not applied.
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
  -config [list make_external "FIXED_IO, DDR" apply_board_preset [expr {$board_part ne "" ? 1 : 0}] \
                Master Disable Slave Disable] $ps

if {$board_part eq ""} {
  # Manual PS7 settings for the Zybo Z7-20 without board files.
  # UNVERIFIED: values from the Zybo Z7 reference manual (33.333 MHz PS
  # clock, 1 GB DDR3L as two x16 MT41K256M16 RE-125 on a 32-bit bus, UART1
  # on MIO 48/49, MIO bank 501 at 1.8 V). The DDR board delays (DQS to CLK,
  # board delay) are NOT set and stay at the IP defaults; training is turned
  # on instead. If the DDR is unstable, copy the PCW_UIPARAM_DDR_* values of
  # the Digilent preset (board files, preset.xml) or install the board files.
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
    pqc_set_cfg $ps $p $v
  }
}
# Settings needed in both cases. UART1 is the USB-UART of the Zybo Z7.
foreach {p v} [list \
    PCW_UART1_PERIPHERAL_ENABLE 1 \
    PCW_UART1_UART1_IO          {MIO 48 .. 49} \
    PCW_UART1_BAUD_RATE         115200 \
    PCW_USE_M_AXI_GP0           1 \
    PCW_EN_CLK0_PORT            1 \
    PCW_EN_RST0_PORT            1 \
    PCW_FPGA0_PERIPHERAL_FREQMHZ $fclk] {
  pqc_set_cfg $ps $p $v
}

# Reset
set rst [create_bd_cell -type ip -vlnv [pqc_latest_vlnv proc_sys_reset] rst_ps7]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins rst_ps7/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst_ps7/ext_reset_in]

# IP under test (RTL module reference)
# UNVERIFIED: the referenced module must elaborate (rtl/l4 present). The
# interface name s_axi is inferred from the s_axi_* ports; checked below.
set pqc [create_bd_cell -type module -reference $ref_top pqc_ntt_0]
foreach {p v} [list ALGO $algo_id PRE_REG $PRE_REG MUL_REG $MUL_REG RED_PIPE $RED_PIPE \
                    OUT_REG $OUT_REG SHARE_ADDSUB $SHARE_ADDSUB ROM_OUT_REG $ROM_OUT_REG] {
  if {![pqc_set_cfg $pqc $p $v]} {
    error "cannot set parameter $p of $ref_top (module reference parameters must be plain integers, ASSUMPTION A22)"
  }
}
set pqc_axi [get_bd_intf_pins -quiet -of_objects $pqc -filter {MODE == Slave}]
if {[llength $pqc_axi] != 1} {
  error "expected one AXI slave interface on pqc_ntt_0, found '$pqc_axi'"
}

# Interconnect. Clock: FCLK_CLK0 everywhere (single domain, l4_axi.md).
set clk [get_bd_pins ps7/FCLK_CLK0]
if {$intc eq "smartconnect"} {
  set ic [create_bd_cell -type ip -vlnv [pqc_latest_vlnv smartconnect] axi_ic]
  pqc_set_cfg $ic NUM_SI 1
  pqc_set_cfg $ic NUM_MI 1
  connect_bd_net $clk [get_bd_pins axi_ic/aclk]
  connect_bd_net [get_bd_pins rst_ps7/interconnect_aresetn] [get_bd_pins axi_ic/aresetn]
} else {
  set ic [create_bd_cell -type ip -vlnv [pqc_latest_vlnv axi_interconnect] axi_ic]
  pqc_set_cfg $ic NUM_SI 1
  pqc_set_cfg $ic NUM_MI 1
  foreach p {ACLK S00_ACLK M00_ACLK} {
    connect_bd_net $clk [get_bd_pins axi_ic/$p]
  }
  connect_bd_net [get_bd_pins rst_ps7/interconnect_aresetn] [get_bd_pins axi_ic/ARESETN]
  foreach p {S00_ARESETN M00_ARESETN} {
    connect_bd_net [get_bd_pins rst_ps7/peripheral_aresetn] [get_bd_pins axi_ic/$p]
  }
}
connect_bd_net $clk [get_bd_pins ps7/M_AXI_GP0_ACLK]
connect_bd_net $clk [get_bd_pins pqc_ntt_0/aclk]
connect_bd_net [get_bd_pins rst_ps7/peripheral_aresetn] [get_bd_pins pqc_ntt_0/aresetn]
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins axi_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic/M00_AXI] $pqc_axi

# Address: fixed base so that the software default (pqc_ntt_regs.h) works.
# UNVERIFIED: segment naming differs between versions; the segment is
# looked up by filter and the result is read back.
assign_bd_address
set seg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_spaces ps7/Data] -filter {NAME =~ "*pqc_ntt_0*"}]
if {[llength $seg] != 1} {
  set seg [get_bd_addr_segs -quiet ps7/Data/*pqc_ntt_0*]
}
if {[llength $seg] != 1} {
  error "cannot find the address segment of pqc_ntt_0 in ps7/Data (found '$seg')"
}
set_property range  $PQC_RANGE    $seg
set_property offset $PQC_BASEADDR $seg
set got_off [get_property offset $seg]
if {[expr {$got_off}] != [expr {$PQC_BASEADDR}]} {
  error "address of pqc_ntt_0 is $got_off, expected $PQC_BASEADDR"
}

validate_bd_design
save_bd_design

# HDL wrapper as top
set bd_file [get_files -of_objects [get_filesets sources_1] ${bd_name}.bd]
generate_target all $bd_file
set wrapper [make_wrapper -files $bd_file -top]
add_files -norecurse -fileset sources_1 $wrapper
set_property top ${bd_name}_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1

# Actual FCLK chosen by the PS PLL.
# UNVERIFIED: property name PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ.
set fclk_act "unknown"
catch {set fclk_act [get_property CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ $ps]}

set fp [open [file join $dir pqc_build_config.txt] w]
puts $fp "name $name"
puts $fp "status block_design"
puts $fp "part $part"
puts $fp "board_part $board_part"
puts $fp "algo $algo_name"
puts $fp "algo_id $algo_id"
puts $fp "impl $impl"
puts $fp "cfg $cfg_name"
puts $fp "pre_reg $PRE_REG"
puts $fp "mul_reg $MUL_REG"
puts $fp "red_pipe $RED_PIPE"
puts $fp "out_reg $OUT_REG"
puts $fp "share_addsub $SHARE_ADDSUB"
puts $fp "rom_out_reg $ROM_OUT_REG"
puts $fp "bfu_latency $BFU_LATENCY"
puts $fp "fclk_mhz_requested $fclk"
puts $fp "fclk_mhz_actual $fclk_act"
puts $fp "intc $intc"
puts $fp "ref_top $ref_top"
puts $fp "baseaddr $PQC_BASEADDR"
puts $fp "vivado [version -short]"
close $fp

puts "INFO: pqc project ready: [file join $dir $name.xpr]"
puts "INFO: FCLK_CLK0 requested $fclk MHz, actual $fclk_act MHz"
puts "INFO: next: vivado -mode batch -source [file join $script_dir build.tcl] -tclargs PROJ=[file join $dir $name.xpr]"
