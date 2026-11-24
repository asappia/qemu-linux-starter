#!/usr/bin/env bash
# Build and boot a tiny AMD64 Linux guest. Later revisions fill in the
# image and QEMU steps; this revision only accepts the public CLI.
set -euo pipefail

die() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
}

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P
}

require_repo_root() {
  local expected actual
  expected=$(repo_root)
  actual=$(pwd -P)
  if [[ "$actual" != "$expected" ]]; then
    die "run ./run.sh from the repository root ($expected)"
  fi
  case "$actual" in
    *[[:space:]]*)
      die "repository path contains whitespace, which the kernel build rejects"
      ;;
  esac
}

usage() {
  cat <<'EOF'
Usage: ./run.sh [option]

Options:
  (none)        Build and verify the direct-boot baseline
  --bootable    Build and verify the self-contained raw disk
  --build-only  Build baseline artifacts without launching QEMU
  --run-only    Run and verify existing baseline artifacts
  --clean       Remove build/ and keep the .cache/ download cache
  --help        Show this help

Run this script from the repository root. It does not read standard input.
EOF
}

clean_outputs() {
  local root path target
  root=$(pwd -P)
  path="build"
  if [[ -L "$path" ]]; then
    target=$(readlink -f -- "$path")
    case "$target" in
      "$root"/*) ;;
      *)
        die "refusing to remove $path: symlink escapes the workspace"
        ;;
    esac
  elif [[ -e "$path" && ! -d "$path" ]]; then
    die "refusing to remove $path: not a directory"
  fi
  if [[ -e "$path" || -L "$path" ]]; then
    rm -rf -- "$path"
  fi
  printf 'removed build/ (download cache in .cache/ was kept)\n'
}

not_implemented() {
  die "$1 is not implemented"
}

parse_args() {
  local mode=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help)
        [[ -z "$mode" ]] || die "unexpected argument: $1" 2
        mode="help"
        ;;
      --clean)
        [[ -z "$mode" ]] || die "unexpected argument: $1" 2
        mode="clean"
        ;;
      --build-only)
        [[ -z "$mode" ]] || die "unexpected argument: $1" 2
        mode="build-only"
        ;;
      --run-only)
        [[ -z "$mode" ]] || die "unexpected argument: $1" 2
        mode="run-only"
        ;;
      --bootable)
        [[ -z "$mode" ]] || die "unexpected argument: $1" 2
        mode="bootable"
        ;;
      --)
        die "unknown option: $1" 2
        ;;
      -*)
        die "unknown option: $1" 2
        ;;
      *)
        die "unexpected argument: $1" 2
        ;;
    esac
    shift
  done
  if [[ -z "$mode" ]]; then
    mode="baseline"
  fi
  printf '%s\n' "$mode"
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
    baseline)
      require_repo_root
      not_implemented "direct-boot baseline"
      ;;
    build-only)
      require_repo_root
      not_implemented "baseline build"
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
