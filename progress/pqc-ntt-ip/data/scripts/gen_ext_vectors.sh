#!/usr/bin/env bash
# Regenerate data/vectors/ext from scratch (P1-d). Single process at a time.
#
#   data/scripts/gen_ext_vectors.sh            fetch, ACVP run, extract, check
#   data/scripts/gen_ext_vectors.sh --golden   also check model/ golden model
#
# Steps:
#   1. fetch.sh                 pinned ACVP json + pq-crystals ref (checksum verified)
#   2. acvp_to_cases.py         ACVP json to build/acvp_cases_<ps>.txt
#   3. make -C harness run      ref + ACVP, raw dumps to build/raw_dump_<ps>.txt
#   4. make_ext_vectors.py      raw to canonical hex + manifest in vectors/ext
#   5. check_fips203.py         independent Python FIPS 203 Alg. 9/10/11 check
#   6. (--golden) golden_check  model/ NTT, INTT, MultiplyNTTs against vectors/ext
set -euo pipefail

DATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${DATA_DIR}/build"
ACVP_DIR="${DATA_DIR}/third_party/acvp-975de31eb83d"
mkdir -p "${BUILD}"

"${DATA_DIR}/scripts/fetch.sh"
python3 -I "${DATA_DIR}/scripts/acvp_to_cases.py" "${ACVP_DIR}" "${BUILD}"
make -C "${DATA_DIR}/harness" -j2 all
make -C "${DATA_DIR}/harness" run
python3 -I "${DATA_DIR}/scripts/make_ext_vectors.py" "${BUILD}" "${DATA_DIR}/vectors/ext"
python3 -I "${DATA_DIR}/scripts/check_fips203.py" "${DATA_DIR}/vectors/ext" | tee "${BUILD}/check_fips203.log"
(cd "${DATA_DIR}" && sha256sum -c --quiet vectors/ext/SHA256SUMS) && echo "vectors/ext checksums OK"

if [[ "${1:-}" == "--golden" ]]; then
  make -C "${DATA_DIR}/harness" golden
  "${BUILD}/golden_check" "${DATA_DIR}/vectors/ext" | tee "${BUILD}/golden_check.log"
fi
