# filelist.tcl: the one place that lists the sources of the system builds (fpga/sys).
#
#   source filelist.tcl
#   set files [sys_filelist <project_root> <A|P>]
#
# Absolute paths in compile order. The RTL list is the RTL_FILES list of sim/tests/sys_smoke.cfg
# (the simulated system, both tops) in the same order, minus the modules the build does not
# instantiate, plus the Verilog shell of the build for the module reference:
#   A (variants A, A2): no pim_* and no sys_p_top
#   P (variants P, PD): no gemv_acc_* / gemv_core and no sys_a_top
# fpga/sys/test/stub_check.tcl checks that the list equals the RTL_FILES of sys_smoke.cfg minus
# these exclusions; the Questa lint of the shells (fpga/sys/README.md) compiles exactly these
# lists, so each list is complete.
set SYS_RTL_FILES {
  pkg/llm_pkg.sv pkg/lut_pkg.sv l0/rshr_sat.sv l0/dotp.sv l0/sync_fifo.sv l0/ram_sdp.sv
  l0/udiv_seq.sv l0/umul_seq.sv l0/lut_lerp.sv l0/argmax_red.sv l0/rsqrt_nr.sv l1/mac_row.sv
  l1/gemv_scale.sv l1/exp_unit.sv l1/attn_score.sv l1/attn_vacc.sv l1/actq_core.sv
  l1/rms_front.sv l1/swi_front.sv l1/axil_slave.sv l1/axi_rd_eng.sv l1/axi_wr_eng.sv
  l1/pim_gb.sv l1/pim_bank.sv l1/pim_ctrl.sv l2/gemv_core.sv l2/pim_core.sv l2/attn_core.sv
  l2/kv_store.sv l2/kv_rd.sv l2/vec_core.sv l3/gemv_acc_csr.sv l3/gemv_acc_top.sv l3/pim_csr.sv
  l3/pim_top.sv l3/attn_csr.sv l3/attn_top.sv l3/vec_csr.sv l3/vec_top.sv l4/axil_xbar.sv
  l4/sys_a_top.sv l4/sys_p_top.sv
}
set SYS_RTL_EXCLUDE [dict create \
  A {l1/pim_gb.sv l1/pim_bank.sv l1/pim_ctrl.sv l2/pim_core.sv l3/pim_csr.sv l3/pim_top.sv
     l4/sys_p_top.sv} \
  P {l2/gemv_core.sv l3/gemv_acc_csr.sv l3/gemv_acc_top.sv l4/sys_a_top.sv}]
set SYS_SHELL [dict create A fpga/sys/src/sys_a_bd.v P fpga/sys/src/sys_p_bd.v]

# rtl-relative names of one build (no shell)
proc sys_rtl_list {top} {
  global SYS_RTL_FILES SYS_RTL_EXCLUDE
  if {![dict exists $SYS_RTL_EXCLUDE $top]} { error "filelist: top must be A or P, got '$top'" }
  set ex [dict get $SYS_RTL_EXCLUDE $top]
  set out {}
  foreach f $SYS_RTL_FILES {
    if {[lsearch -exact $ex $f] < 0} { lappend out $f }
  }
  return $out
}

proc sys_filelist {root top} {
  global SYS_SHELL
  set files {}
  foreach f [concat [lmap r [sys_rtl_list $top] {string cat rtl/ $r}] [list [dict get $SYS_SHELL $top]]] {
    set p [file normalize [file join $root $f]]
    if {![file exists $p]} { error "filelist: missing $p" }
    lappend files $p
  }
  return $files
}
