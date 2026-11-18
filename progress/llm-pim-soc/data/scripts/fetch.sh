#!/bin/sh
# Download third-party inputs into data/third_party (not committed).
# Usage (from the project directory): sh data/scripts/fetch.sh
# Verifies every file against data/scripts/checksums.sha256 when that file lists it.
set -eu
umask 077
here=$(cd "$(dirname "$0")" && pwd)
tp="$here/../third_party"
mkdir -p "$tp/models" "$tp/llama2c" "$tp/tinystories"

HF=https://huggingface.co
GH=https://raw.githubusercontent.com/karpathy/llama2.c/master

get() { # url dest [range]
  if [ -s "$2" ]; then return 0; fi
  if [ $# -ge 3 ]; then
    curl -fsSL --retry 3 -A "curl" -r "$3" -o "$2.part" "$1"
  else
    curl -fsSL --retry 3 -A "curl" -o "$2.part" "$1"
  fi
  mv "$2.part" "$2"
}

# Checkpoints and tokenizers (karpathy/tinyllamas, HF model card: MIT)
get "$HF/karpathy/tinyllamas/resolve/main/stories260K/stories260K.bin" "$tp/models/stories260K.bin"
get "$HF/karpathy/tinyllamas/resolve/main/stories260K/tok512.bin"      "$tp/models/tok512.bin"
get "$HF/karpathy/tinyllamas/resolve/main/stories15M.bin"              "$tp/models/stories15M.bin"
get "$HF/karpathy/tinyllamas/resolve/main/README.md"                   "$tp/models/README.tinyllamas.md"
# Llama 2 tokenizer as redistributed in the llama2.c repository
get "$GH/tokenizer.bin" "$tp/models/tokenizer.bin"

# Reference implementation (MIT). Used only to produce reference outputs.
for f in run.c runq.c export.py model.py tokenizer.py LICENSE README.md; do
  get "$GH/$f" "$tp/llama2c/$f"
done

# TinyStories validation split: first 256 KiB only (CDLA-Sharing-1.0)
get "$HF/datasets/roneneldan/TinyStories/resolve/main/TinyStories-valid.txt" \
    "$tp/tinystories/valid_head.txt" "0-262143"
get "$HF/datasets/roneneldan/TinyStories/resolve/main/README.md" "$tp/tinystories/README.dataset.md"

if [ -s "$here/checksums.sha256" ]; then
  (cd "$tp" && sha256sum -c --quiet "$here/checksums.sha256") && echo "checksums OK"
else
  echo "no checksum list; generating one"
  (cd "$tp" && find . -type f ! -name '*.part' | sort | xargs sha256sum) > "$here/checksums.sha256"
fi
