#!/bin/bash
# Usage: source scripts/env.sh <questa|hls|nc|dc|rise>
# Site-specific tool environments live outside the repository.
_env_dir="${RESEARCH_TOOLS_ENV_DIR:-/Tools/env}"
case "$1" in
  questa|hls) source "$_env_dir/catapult_eval_env.2026.3_1.bsh" >/dev/null 2>&1 ;;
  nc)         source "$_env_dir/cadence_ic152.bsh"              >/dev/null 2>&1 ;;
  dc)         source "$_env_dir/synopsys_syn_merge.bsh"         >/dev/null 2>&1 ;;
  rise)       source "$_env_dir/rise_eval_env.latest.bsh"       >/dev/null 2>&1 ;;
  *) echo "usage: source scripts/env.sh <questa|hls|nc|dc|rise>" >&2; return 1 2>/dev/null || exit 1 ;;
esac
unset _env_dir
