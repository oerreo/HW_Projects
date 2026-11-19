# zybo_z7_20.xdc: constraints of the HP bandwidth build (fpga/bw).
#
# Intentionally empty, for the same reasons as in the pqc-ntt-ip build:
#   * only Zynq PS pins (DDR, FIXED_IO incl. UART1 on MIO 48/49) are used; they are placed by
#     the processing_system7 IP, no PL package pin, no PACKAGE_PIN / IOSTANDARD;
#   * FCLK_CLK0 gets its create_clock from the processing_system7 IP (generated XDC); do not
#     add a second one;
#   * one clock domain (FCLK_CLK0 drives GP0, HP0, HP2, the interconnects and bw_top).
# If report_drc shows CFGBVS-1, add (bank 0 is 3.3 V on the Zybo Z7):
#   set_property CFGBVS VCCO [current_design]
#   set_property CONFIG_VOLTAGE 3.3 [current_design]
