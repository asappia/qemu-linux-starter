# Boot the direct-kernel guest and check its serial log.
# Source this file; do not execute it.
[[ -n "${ROOT:-}" ]] || {
  printf 'error: source lib/qemu.sh from run.sh\n' >&2
  exit 1
}

qemu_timeout() {
  local value=${QEMU_TIMEOUT:-120}
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    die "QEMU_TIMEOUT must be a positive number of seconds"
  fi
  printf '%s\n' "$value"
}

require_qemu() {
  command -v qemu-system-x86_64 >/dev/null 2>&1 || \
    die "qemu-system-x86_64 is missing (Ubuntu package: qemu-system-x86)"
  command -v timeout >/dev/null 2>&1 || \
    die "timeout is missing (Ubuntu package: coreutils)"
}

guest_ok() {
  local raw=$1 norm=$2
  local count=0 line
  tr -d '\r' <"$raw" >"$norm"
  while true; do
    if IFS= read -r line; then
      if [[ "$line" == "hello world" ]]; then
        count=$((count + 1))
      fi
    else
      if [[ "$line" == "hello world" ]]; then
        die "guest greeting is not a complete line"
      fi
      break
    fi
  done <"$norm"
  if [[ "$count" -ne 1 ]]; then
    die "expected one hello world line from the guest, found ${count}"
  fi
  if grep -E -q 'Kernel panic|Oops:|BUG:|startup failure|shutdown failure|not syncing|Unable to mount root' "$norm"; then
    die "guest log reports a startup or shutdown failure"
  fi
  if ! grep -q 'reboot: Power down' "$norm"; then
    die "guest did not reach poweroff"
  fi
}

run_guest() {
  local bz image serial norm seconds rc
  bz="$ROOT/build/artifacts/bzImage"
  image="$ROOT/build/artifacts/rootfs.img"
  serial="$ROOT/build/logs/guest-serial.log"
  norm="$ROOT/build/logs/guest-serial.norm"
  [[ -f "$bz" ]] || die "missing $bz; run ./run.sh --build-only"
  [[ -f "$image" ]] || die "missing $image; run ./run.sh --build-only"
  require_qemu
  mkdir -p -- "$ROOT/build/logs"
  seconds=$(qemu_timeout)
  rm -f -- "$serial" "$norm"
  log "qemu: booting baseline for ${seconds}s"
  set +e
  timeout "$seconds" qemu-system-x86_64 \
    -machine pc \
    -accel tcg \
    -cpu qemu64 \
    -m 256 \
    -no-reboot \
    -display none \
    -monitor none \
    -nic none \
    -serial "file:${serial}" \
    -kernel "$bz" \
    -append "console=ttyS0,115200 root=/dev/vda rootfstype=ext4 rootwait ro init=/sbin/init" \
    -drive "file=${image},format=raw,if=virtio,readonly=on" \
    </dev/null >"$ROOT/build/logs/qemu.log" 2>&1
  rc=$?
  set -e
  if [[ -f "$serial" ]]; then
    cat -- "$serial"
  fi
  if [[ "$rc" -eq 124 ]]; then
    die "qemu timed out after ${seconds}s"
  fi
  if [[ "$rc" -ne 0 ]]; then
    die "qemu exited with status ${rc}"
  fi
  [[ -f "$serial" ]] || die "qemu produced no guest serial log"
  guest_ok "$serial" "$norm"
  log "qemu: guest printed hello world and powered off"
}
