# Assemble a BIOS disk that boots without an external kernel.
# Source this file; do not execute it.
[[ -n "${ROOT:-}" ]] || {
  printf 'error: source lib/disk.sh from run.sh\n' >&2
  exit 1
}

grub_lib_dir() {
  local dir
  for dir in /usr/lib/grub/i386-pc; do
    if [[ -f "${dir}/boot.img" && -f "${dir}/biosdisk.mod" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  die "GRUB i386-pc modules are missing (Ubuntu package: grub-pc-bin)"
}

build_disk() {
  local tree part disk core lib stamp expected
  tree="$ROOT/build/disk-tree"
  part="$ROOT/build/disk-part.img"
  disk="$ROOT/build/artifacts/disk.img"
  core="$ROOT/build/grub-core.img"
  stamp="$ROOT/build/stamps/disk"
  command -v grub-mkimage >/dev/null 2>&1 || \
    die "grub-mkimage is missing (Ubuntu package: grub-pc-bin)"
  command -v sfdisk >/dev/null 2>&1 || \
    die "sfdisk is missing (Ubuntu package: fdisk)"
  build_kernel
  build_busybox
  lib=$(grub_lib_dir)
  expected=$(sha256sum -- "$ROOT/config/grub.cfg" "$ROOT/config/grub-early.cfg" \
    "$ROOT/guest/init" "$ROOT/guest/startup" \
    "$ROOT/build/artifacts/bzImage" "$ROOT/build/busybox/busybox" \
    | sha256sum | awk '{ print $1 }')
  if [[ -f "$stamp" && -f "$disk" && "$(cat -- "$stamp")" == "$expected" ]]; then
    log "disk: cache hit disk.img"
    return 0
  fi

  log "disk: creating GRUB BIOS image"
  grub-mkimage -O i386-pc -o "$core" -d "$lib" \
    -p '(hd0,msdos1)/boot/grub' \
    -c "$ROOT/config/grub-early.cfg" \
    biosdisk part_msdos ext2 normal configfile linux serial terminal
  make_guest_tree "$tree"
  mkdir -p -- "$tree/boot/grub"
  cp -f -- "$ROOT/build/artifacts/bzImage" "$tree/boot/bzImage"
  cp -f -- "$ROOT/config/grub.cfg" "$tree/boot/grub/grub.cfg"
  write_ext4 "$tree" "$part"

  rm -f -- "$disk"
  dd if=/dev/zero of="$disk" bs=1M count=33 status=none
  sfdisk --wipe always "$disk" <<'EOF'
label: dos
start=2048, size=65536, type=83, bootable
EOF
  dd if="$part" of="$disk" bs=512 seek=2048 conv=notrunc status=none
  dd if="${lib}/boot.img" of="$disk" bs=440 count=1 conv=notrunc status=none
  dd if="$core" of="$disk" bs=512 seek=1 conv=notrunc status=none
  printf '%s\n' "$expected" >"$stamp"
  log "disk: built $disk"
}

run_disk() {
  local disk serial
  disk="$ROOT/build/artifacts/disk.img"
  serial="$ROOT/build/logs/disk-serial.log"
  [[ -f "$disk" ]] || die "missing $disk"
  require_qemu
  log "qemu: booting disk.img"
  launch_qemu "$serial" \
    -drive "file=${disk},format=raw,if=virtio,readonly=on"
  log "qemu: disk booted without an external kernel"
}
