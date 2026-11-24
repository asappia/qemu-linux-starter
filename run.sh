#!/usr/bin/env bash
# Build and boot a tiny AMD64 Linux guest.
# Helpers live in lib/. This file only parses the command and runs it.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/acquire.sh
source "$ROOT/lib/acquire.sh"
# shellcheck source=lib/kernel.sh
source "$ROOT/lib/kernel.sh"

partial_download=""
trap on_exit EXIT

prepare_downloads() {
  require_repo_root
  ensure_apt_packages
  require_tools
  prepare_workspace
  acquire_sources
}

main() {
  local mode
  mode=$(parse_args "$@")
  case "$mode" in
    help)
      usage
      ;;
    clean)
      require_repo_root
      clean_outputs
      ;;
    build-only)
      prepare_downloads
      build_kernel
      ;;
    baseline)
      prepare_downloads
      build_kernel
      not_implemented "guest boot"
      ;;
    run-only)
      require_repo_root
      not_implemented "baseline run"
      ;;
    bootable)
      require_repo_root
      not_implemented "bootable disk"
      ;;
    *)
      die "internal error: bad mode $mode" 2
      ;;
  esac
}

main "$@"
