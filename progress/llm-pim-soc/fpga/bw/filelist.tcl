# filelist.tcl: the one place that lists the sources of the HP bandwidth build (fpga/bw).
#
#   source filelist.tcl
#   set files [bw_filelist <project_root>]
#
# Absolute paths in compile order. The RTL is the simulated one (sim/tests/bw_top.cfg uses
# the same five files); src/bw_bd.v is the Verilog shell for the module reference.
proc bw_filelist {root} {
  set files {}
  foreach f {rtl/l0/sync_fifo.sv rtl/l1/axil_slave.sv rtl/l1/axi_rd_eng.sv rtl/l1/axi_wr_eng.sv
             rtl/l3/bw_top.sv fpga/bw/src/bw_bd.v} {
    set p [file normalize [file join $root $f]]
    if {![file exists $p]} { error "filelist: missing $p" }
    lappend files $p
  }
  return $files
}
