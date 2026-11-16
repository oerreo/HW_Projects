#!/usr/bin/env bash
# Fetch external test data for pqc-ntt-ip (P1-d).
#
#   data/scripts/fetch.sh            download into data/third_party/ (refuses to overwrite)
#   data/scripts/fetch.sh --verify   only re-check sha256 against data/checksums.sha256
#
# Everything is pinned to a commit hash so that the checksums are stable.
# Downloads land in fresh, empty directories and nothing downloaded is executed here.
set -euo pipefail

DATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TP="${DATA_DIR}/third_party"
SUMS="${DATA_DIR}/checksums.sha256"

ACVP_COMMIT=975de31eb83d87039ec88934fdc47d8c312b892d
KYBER_COMMIT=3edd5af5991927164edd4aacebfcbee00b8064e7

ACVP_DIR="${TP}/acvp-${ACVP_COMMIT:0:12}"
KYBER_DIR="${TP}/kyber-${KYBER_COMMIT:0:12}"
KYBER_TGZ="${TP}/kyber-${KYBER_COMMIT:0:12}.tar.gz"

verify() {
  (cd "${DATA_DIR}" && sha256sum -c --quiet "${SUMS}") && echo "checksums OK"
}

if [[ "${1:-}" == "--verify" ]]; then
  verify
  exit 0
fi

fetch() {  # url dest
  curl -fsSL --retry 3 --max-time 120 -o "$2" "$1"
}

# 1. NIST ACVP-Server ML-KEM vector sets (only the files we need).
if [[ -e "${ACVP_DIR}" ]]; then
  echo "exists, skip: ${ACVP_DIR}"
else
  mkdir -p "${ACVP_DIR}"
  RAW="https://raw.githubusercontent.com/usnistgov/ACVP-Server/${ACVP_COMMIT}"
  fetch "${RAW}/README.md" "${ACVP_DIR}/README.md"
  for set in ML-KEM-keyGen-FIPS203 ML-KEM-encapDecap-FIPS203; do
    mkdir -p "${ACVP_DIR}/${set}"
    for f in prompt.json expectedResults.json internalProjection.json registration.json; do
      fetch "${RAW}/gen-val/json-files/${set}/${f}" "${ACVP_DIR}/${set}/${f}"
    done
  done
fi

# 2. pq-crystals/kyber reference implementation, one commit as a tarball.
if [[ -e "${KYBER_DIR}" ]]; then
  echo "exists, skip: ${KYBER_DIR}"
else
  fetch "https://codeload.github.com/pq-crystals/kyber/tar.gz/${KYBER_COMMIT}" "${KYBER_TGZ}"
  mkdir -p "${KYBER_DIR}"
  # Extract only the license/readme and ref/ sources; refuse absolute or .. paths.
  if tar -tzf "${KYBER_TGZ}" | grep -E '(^/|(^|/)\.\.(/|$))' ; then
    echo "unsafe path in tarball" >&2; exit 1
  fi
  tar -xzf "${KYBER_TGZ}" -C "${KYBER_DIR}" --strip-components=1 --no-same-owner \
    "kyber-${KYBER_COMMIT}/LICENSE" "kyber-${KYBER_COMMIT}/README.md" "kyber-${KYBER_COMMIT}/ref"
fi

if [[ -f "${SUMS}" ]]; then
  verify
else
  echo "no ${SUMS} (see data/README.md, section checksums)"
fi
