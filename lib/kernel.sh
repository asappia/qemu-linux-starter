# Build the pinned AMD64 kernel. Source this file; do not execute it.
[[ -n "${ROOT:-}" ]] || {
  printf 'error: source lib/kernel.sh from run.sh\n' >&2
  exit 1
}

require_build_tools() {
  local -a missing=()
  local tool package
  while read -r tool package; do
    [[ -n "$tool" ]] || continue
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool (Ubuntu package: $package)")
    fi
  done <<'EOF'
gcc build-essential
make build-essential
bc bc
bison bison
flex flex
perl perl
python3 python3
EOF
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'error: missing prerequisite tools:\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
    printf 'error: install the listed packages, then rerun ./run.sh\n' >&2
    exit 1
  fi
  case "$(uname -m)" in
    x86_64) ;;
    *)
      die "this host is $(uname -m); an x86_64 compiler is required to build the AMD64 kernel"
      ;;
  esac
}

kernel_make() {
  local src=$1 out=$2
  shift 2
  make -C "$src" O="$out" ARCH=x86_64 "$@"
}

require_kernel_options() {
  local cfg=$1
  local symbol
  local -a required=(
    CONFIG_64BIT
    CONFIG_X86_64
    CONFIG_PCI
    CONFIG_BLOCK
    CONFIG_BLK_DEV
    CONFIG_VIRTIO_PCI
    CONFIG_VIRTIO_PCI_LEGACY
    CONFIG_VIRTIO_BLK
    CONFIG_EXT4_FS
    CONFIG_MSDOS_PARTITION
    CONFIG_DEVTMPFS
    CONFIG_DEVTMPFS_MOUNT
    CONFIG_SERIAL_8250
    CONFIG_SERIAL_8250_CONSOLE
    CONFIG_PRINTK
    CONFIG_PROC_FS
    CONFIG_SYSFS
    CONFIG_TMPFS
    CONFIG_BINFMT_ELF
    CONFIG_BINFMT_SCRIPT
    CONFIG_ACPI
    CONFIG_ACPI_SYSTEM_POWER_STATES_SUPPORT
  )
  for symbol in "${required[@]}"; do
    if ! grep -q "^${symbol}=y$" "$cfg"; then
      die "kernel config is missing ${symbol}=y"
    fi
  done
  if grep -q '^CONFIG_MODULES=y$' "$cfg"; then
    die "kernel config enabled modules; drivers must be built in"
  fi
}

build_kernel() {
  local src out fragment stamp expected bz
  src="$ROOT/build/src/linux-${LINUX_VERSION}"
  out="$ROOT/build/linux"
  fragment="$ROOT/config/linux.min"
  stamp="$ROOT/build/stamps/kernel"
  bz="$ROOT/build/artifacts/bzImage"
  [[ -d "$src" ]] || die "missing kernel source $src"
  [[ -f "$fragment" ]] || die "missing $fragment"
  require_build_tools
  mkdir -p -- "$ROOT/build/linux" "$ROOT/build/artifacts" "$ROOT/build/logs" "$ROOT/build/stamps"

  expected=$(sha256sum -- "$fragment" | awk '{ print $1 }')
  expected="${LINUX_SHA256} ${expected}"
  if [[ -f "$stamp" && -f "$bz" && "$(cat -- "$stamp")" == "$expected" ]]; then
    log "kernel: cache hit bzImage"
    return 0
  fi

  log "kernel: configuring minimal AMD64 kernel"
  kernel_make "$src" "$out" KCONFIG_ALLCONFIG="$fragment" allnoconfig \
    >"$ROOT/build/logs/kernel-config.log" 2>&1
  require_kernel_options "$out/.config"

  log "kernel: compiling"
  kernel_make "$src" "$out" -j"$(nproc)" >"$ROOT/build/logs/kernel-build.log" 2>&1
  [[ -f "$out/arch/x86/boot/bzImage" ]] || die "kernel build did not produce bzImage"
  cp -f -- "$out/arch/x86/boot/bzImage" "$bz"
  printf '%s\n' "$expected" >"$stamp"
  log "kernel: built $bz"
}
