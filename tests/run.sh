#!/usr/bin/env bash
# Run the jev-lens.nvim test suite in a headless nvim with an isolated data dir.
#
#   tests/run.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
data="$(mktemp -d "${TMPDIR:-/tmp}/jev-lens-data.XXXXXX")"
trap 'rm -rf "$data"' EXIT

JEV_LENS_DIR="$data" nvim --headless --clean \
  -u "$here/minimal_init.lua" \
  -l "$here/spec.lua"
