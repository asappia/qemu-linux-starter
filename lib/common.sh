# Shared helpers for run.sh. Source this file; do not execute it.
[[ -n "${ROOT:-}" ]] || {
  printf 'error: source lib/common.sh from run.sh\n' >&2
  exit 1
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
}

log() {
  printf '%s\n' "$*" >&2
}

on_exit() {
  if [[ -n "${partial_download}" && -f "${partial_download}" ]]; then
    rm -f -- "${partial_download}"
  fi
}

require_repo_root() {
  local actual
  actual=$(pwd -P)
  if [[ "$actual" != "$ROOT" ]]; then
    die "run ./run.sh from the repository root ($ROOT)"
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
--clean removes build/ (including logs and test reports) and keeps .cache/.
EOF
}

ensure_contained_dir() {
  local path=$1
  local root target
  root=$(pwd -P)
  if [[ -L "$path" ]]; then
    target=$(readlink -f -- "$path")
    case "$target" in
      "$root"/*) ;;
      *)
        die "refusing to use $path: symlink escapes the workspace"
        ;;
    esac
  elif [[ -e "$path" && ! -d "$path" ]]; then
    die "refusing to use $path: not a directory"
  fi
}

prepare_workspace() {
  ensure_contained_dir .cache
  ensure_contained_dir build
  mkdir -p -- .cache/sources build/src build/stamps build/tmp build/logs
  export TMPDIR="$PWD/build/tmp"
  export TMP="$TMPDIR"
}

ensure_apt_packages() {
  local -a packages=(
    build-essential
    bc
    bison
    flex
    perl
    python3
    pkg-config
    libelf-dev
    curl
    ca-certificates
    xz-utils
    bzip2
  )
  local -a missing=()
  local pkg
  if ! command -v apt-get >/dev/null 2>&1; then
    die "apt-get is required; use Ubuntu 20.04 LTS or 22.04 LTS"
  fi
  for pkg in "${packages[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi
  log "apt: installing ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  if [[ "$(id -u)" -eq 0 ]]; then
    apt-get update
    apt-get install -y --no-install-recommends "${missing[@]}"
  else
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends "${missing[@]}"
  fi
}

require_tools() {
  local -a missing=()
  local tool package
  while read -r tool package; do
    [[ -n "$tool" ]] || continue
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool (Ubuntu package: $package)")
    fi
  done <<'EOF'
curl curl
sha256sum coreutils
tar tar
xz xz-utils
bzip2 bzip2
EOF
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'error: missing prerequisite tools:\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
    printf 'error: install the listed packages, then rerun ./run.sh\n' >&2
    exit 1
  fi
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
