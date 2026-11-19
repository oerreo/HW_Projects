#!/bin/bash
# Usage: source scripts/env.sh <questa|hls|rise>
# Site-specific tool environments live outside the repository.
_env_dir="${RESEARCH_TOOLS_ENV_DIR:-/Tools/env}"
# License policy (user instruction 2026-11-19): eval environments only, license
# server bm06 only. nc and dc are neither, so they are refused unless the user
# has explicitly allowed one run (RESEARCH_ALLOW_NONEVAL=1 in that shell).
case "$1" in
  questa|hls) source "$_env_dir/catapult_eval_env.2026.3_1.bsh" >/dev/null 2>&1 ;;
  rise)       source "$_env_dir/rise_eval_env.latest.bsh"       >/dev/null 2>&1 ;;
  nc|dc)
    if [ "${RESEARCH_ALLOW_NONEVAL:-0}" != 1 ]; then
      echo "env.sh: $1 is not an eval/bm06 license environment; not allowed (ask the user)" >&2
      unset _env_dir
      return 1 2>/dev/null || exit 1
    fi
    if [ "$1" = nc ]; then source "$_env_dir/cadence_ic152.bsh" >/dev/null 2>&1
    else                   source "$_env_dir/synopsys_syn_merge.bsh" >/dev/null 2>&1; fi ;;
  *) echo "usage: source scripts/env.sh <questa|hls|rise>" >&2; return 1 2>/dev/null || exit 1 ;;
esac
# every license server named by the environment must be bm06
if [ "${RESEARCH_ALLOW_NONEVAL:-0}" != 1 ]; then
  _bad=$(printf '%s:%s' "${MGLS_LICENSE_FILE:-}" "${LM_LICENSE_FILE:-}" | tr ':' '\n' |
         grep '@' | grep -v -E '@bm06(\.|$)' | head -1)
  if [ -n "$_bad" ]; then
    echo "env.sh: a license server other than bm06 is configured; refusing" >&2
    unset MGLS_LICENSE_FILE LM_LICENSE_FILE _bad _env_dir
    return 1 2>/dev/null || exit 1
  fi
  unset _bad
fi
unset _env_dir

# Privacy on the shared server: files private to the owner, tool temp files in a
# private directory instead of world-readable /tmp (simulator transcripts,
# auto-compiled DPI objects).
umask 077
# Some tools chmod their TMPDIR to 777, so the private directory is the parent.
_rt="/tmp/.rt-$(id -u)"
mkdir -p "$_rt/t" 2>/dev/null
chmod 700 "$_rt" 2>/dev/null
export TMPDIR="$_rt/t" TMP="$_rt/t" TEMP="$_rt/t"
unset _rt
