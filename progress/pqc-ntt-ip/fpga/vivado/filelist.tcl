# filelist.tcl: the one place that lists the RTL sources of the FPGA build.
#
#   source filelist.tcl
#   set files [pqc_filelist <project_root> <impl>]     ;# impl: rtl | hls
#
# Returns absolute paths in a safe compile order (packages first). The
# levels that do not exist yet (rtl/l3 while ntt_core is being written,
# rtl/l4 for pqc_ntt_axi_top) are globbed; an empty level only prints a
# WARNING so that the project can still be created and filled in later.
#
# impl = hls (provisional, see fpga/README.md): the hand RTL L0 mod_mul and
# mod_red are replaced by the Catapult adapters of hls/l0/wrap and the
# generated FPGA netlists hls/l0/out/*_fpga_*/concat_rtl.v, the same swap
# the simulation configs make. How an HLS bfu enters ntt_core is decided in
# P4 (l4_axi.md "open items"); this only covers the L0 swap.

proc pqc_glob {dir pattern} {
  return [lsort [glob -nocomplain -types f -directory $dir $pattern]]
}

proc pqc_filelist {root impl} {
  set rtl [file join $root rtl]
  set files {}
  # 1. packages (order matters: mlkem_pkg, generated ROM tables, L2 pkg)
  foreach f [list \
      [file join $rtl pkg mlkem_pkg.sv] \
      [file join $rtl l2 rom zeta_rom_pkg.sv] \
      [file join $rtl l2 ntt_l2_pkg.sv]] {
    if {![file exists $f]} {
      error "filelist: missing package $f"
    }
    lappend files $f
  }
  # 2. L0
  set hls_swap {mod_mul.sv mod_red.sv}
  foreach f [pqc_glob [file join $rtl l0] *.sv] {
    if {$impl eq "hls" && [lsearch -exact $hls_swap [file tail $f]] >= 0} {
      continue
    }
    lappend files $f
  }
  if {$impl eq "hls"} {
    set wrap [file join $root hls l0 wrap]
    foreach f [list [file join $wrap hls_l0_lib_fpga.sv] \
                    [file join $wrap mod_red.sv] [file join $wrap mod_mul.sv]] {
      if {![file exists $f]} {
        error "filelist: missing HLS adapter $f"
      }
      lappend files $f
    }
    set nets [lsort [glob -nocomplain -types f [file join $root hls l0 out *_fpga_* concat_rtl.v]]]
    if {[llength $nets] == 0} {
      error "filelist: no FPGA Catapult netlists under hls/l0/out"
    }
    set files [concat $files $nets]
  } elseif {$impl ne "rtl"} {
    error "filelist: impl must be rtl or hls, got '$impl'"
  }
  # 3. L1, L2 (packages already listed)
  set files [concat $files [pqc_glob [file join $rtl l1] *.sv]]
  foreach f [pqc_glob [file join $rtl l2] *.sv] {
    if {[file tail $f] ne "ntt_l2_pkg.sv"} {
      lappend files $f
    }
  }
  # 4. L3, L4: may not exist yet
  foreach lvl {l3 l4} {
    set got [pqc_glob [file join $rtl $lvl] *.sv]
    if {[llength $got] == 0} {
      puts "WARNING: filelist: no sources in rtl/$lvl yet (expected [expr {$lvl eq "l3" ? "ntt_core" : "pqc_ntt_axi_top"}])"
    }
    set files [concat $files $got]
  }
  # 5. FPGA-only Verilog shell for the block design module reference
  set files [concat $files [pqc_glob [file join $root fpga vivado src] *.v]]
  return $files
}
