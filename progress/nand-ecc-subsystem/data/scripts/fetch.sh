#!/bin/sh
# Fetch external reference data into data/third_party/ (git-ignored, never committed).
# Run from the project directory:  sh data/scripts/fetch.sh
# Files already present are not fetched again. Afterwards every file is checked against
# data/scripts/checksums.sha256 (created on the first run, then kept in the repository).
# Requests use plain curl/git with no personal information.
set -e
umask 077
D=data/third_party
mkdir -p $D/alist $D/refs $D/docs
CF=9d7257598885dc49b950b963893f86fa710f3104   # aff3ct/configuration_files (2019-12-12)
ER=51dff02f0fac4840be7d41c1a01a56e206cb5f07   # aff3ct/error_rate_references (2024-05-28)
GH=https://raw.githubusercontent.com/aff3ct

get() { # url dest
  if [ ! -s "$2" ]; then
    echo "fetch $2"
    curl -sSfL --retry 2 -o "$2.part" "$1" && mv "$2.part" "$2"
  fi
}

# IEEE 802.3an (2048,1723) RS-LDPC parity-check matrices as used by AFF3CT
get $GH/configuration_files/$CF/dec/LDPC/10GBPS-ETHERNET_1723_2048.alist     $D/alist/eth_1723_2048.alist
get $GH/configuration_files/$CF/dec/LDPC/10GBPS-ETHERNET_ALT_1723_2048.alist $D/alist/eth_alt_1723_2048.alist
# AFF3CT reference BER/FER curves (AWGN, BPSK) for the same matrix
R=$GH/error_rate_references/$ER/LDPC/AWGN/BPSK
get $R/BP_FLOODING/SPA/LDPC_N2048_K1723_flooding_SPA_i100_eth_10Gbps.txt          $D/refs/eth_flood_spa_i100.txt
get $R/BP_HORIZONTAL_LAYERED/SPA/LDPC_N2048_K1723_hlayered_SPA_i100_eth_10Gbps.txt $D/refs/eth_hlay_spa_i100.txt
get $R/BP_FLOODING/NMS/LDPC_N2048_K1723_flooding_NMS_i30_eth_10Gbps.txt           $D/refs/eth_flood_nms_i30.txt
# CCSDS 131.1-O-2 (C2 (8176,7156) circulant table 2-1)
get https://ccsds.org/Pubs/131x1o2e2s.pdf $D/docs/ccsds_131x1o2e2s.pdf
# [R5] Cui et al. TODAES 2021 (TLC fit tables, appendix A1-A3; printed numbers are quoted in data/params/)
get https://xiaorz.github.io/paper/TODAES2021-Cui.pdf $D/docs/cui_todaes2021.pdf
# [R3] Pan, Dong, Zhang FAST 2011 (MLC model section 2: order of RTN, CCI, retention)
get https://usenix.org/event/fast11/tech/full_papers/Pan.pdf $D/docs/pan_fast2011.pdf

S=data/scripts/checksums.sha256
if [ -f $S ]; then
  sha256sum -c --quiet $S && echo "checksums OK"
else
  (find $D/alist $D/refs $D/docs -type f | sort | xargs sha256sum) > $S
  echo "created $S"
fi
