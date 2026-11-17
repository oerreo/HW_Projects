# zybo_z7_20.xdc: constraints of the pqc_ntt_axi_top FPGA build.
#
# Intentionally (almost) empty. The design uses only the Zynq PS and the PL
# logic behind M_AXI_GP0:
#   * DDR and FIXED_IO (MIO, including UART1 on MIO 48/49) are PS pins
#     placed by the processing_system7 IP; no PL package pin is used, so no
#     PACKAGE_PIN / IOSTANDARD constraint is needed.
#   * FCLK_CLK0 gets its create_clock from the processing_system7 IP
#     (generated XDC, period from PCW_FPGA0_PERIPHERAL_FREQMHZ). Do not add
#     a second create_clock here.
#   * Single clock domain, no CDC, no false or multicycle path.
#
# Bitstream configuration bank settings (CFGBVS / CONFIG_VOLTAGE) are not
# set: the PL is configured by the PS over PCAP / JTAG on the Zynq, and
# whether Vivado's DRC asks for them on xc7z020 is not verified. If
# report_drc shows CFGBVS-1, add (bank 0 is 3.3 V on the Zybo Z7):
#   set_property CFGBVS VCCO [current_design]
#   set_property CONFIG_VOLTAGE 3.3 [current_design]
