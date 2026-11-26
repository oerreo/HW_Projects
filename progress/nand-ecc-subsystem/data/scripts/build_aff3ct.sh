#!/bin/sh
# Clone and build the AFF3CT reference implementation (MIT) into data/third_party/aff3ct (git-ignored).
# Run from the project directory:  sh data/scripts/build_aff3ct.sh   (serial, one core, about 1 h)
# Shared-server privacy (.claude/rules/process-privacy.md): the build runs through a symlink in the
# private runtime directory so that compiler command lines do not carry the project path, and the
# patched executable reads its options from the file named by A_ARGS (aff3ct_argfile.patch).
set -e
umask 077
P=$(pwd)
D=$P/data/third_party/aff3ct
TAG=v4.7.4   # f6aabe7fbbc5e33bcb5ad84b5d268576e8a495f4
if [ ! -d "$D/.git" ]; then
  git clone -q --depth 1 --branch $TAG https://github.com/aff3ct/aff3ct.git "$D"
  (cd "$D" && git submodule update --init --depth 1 lib/MIPP lib/date lib/cli lib/streampu &&
   (cd lib/cli && git submodule update --init --depth 1 lib/rang) &&
   cd lib/streampu && git submodule update --init --depth 1 lib/rang lib/cpptrace lib/json)
fi
cd "$D"
if ! grep -q A_ARGS src/main.cpp; then
  sed -n '/^---/,$p' "$P/data/scripts/aff3ct_argfile.patch" | patch -p1
fi
R=/tmp/.rt-$(id -u)
mkdir -p $R && chmod 700 $R
ln -sfn "$D" $R/a
mkdir -p $R/a/build && cd $R/a/build
cmake -S $R/a -B . -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-funroll-loops -march=native" \
  -DAFF3CT_COMPILE_EXE=ON -DAFF3CT_COMPILE_STATIC_LIB=OFF -DAFF3CT_COMPILE_SHARED_LIB=OFF \
  -DSPU_BENCHMARK=OFF -DSPU_TESTS=OFF -DSPU_STACKTRACE=OFF -DSPU_COLORS=OFF > cmake.log 2>&1
make -j1 > make.log 2>&1
ls -la bin/
