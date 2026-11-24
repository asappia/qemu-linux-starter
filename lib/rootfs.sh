# Build the static BusyBox userspace and the ext4 root image.
# Source this file; do not execute it.
[[ -n "${ROOT:-}" ]] || {
  printf 'error: source lib/rootfs.sh from run.sh\n' >&2
  exit 1
}

require_option() {
  local cfg=$1 symbol=$2
  if ! grep -q "^${symbol}=y$" "$cfg"; then
    die "BusyBox config is missing ${symbol}=y"
  fi
}

apply_min_config() {
  local cfg=$1 fragment=$2
  local line symbol
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      CONFIG_*=*)
        symbol=${line%%=*}
        ;;
      '# CONFIG_'*' is not set')
        symbol=${line#\# }
        symbol=${symbol%% is not set}
        ;;
      *)
        continue
        ;;
    esac
    grep -v -e "^${symbol}=" -e "^# ${symbol} is not set$" "$cfg" >"${cfg}.tmp"
    printf '%s\n' "$line" >>"${cfg}.tmp"
    mv "${cfg}.tmp" "$cfg"
  done <"$fragment"
}

build_busybox() {
  local src out fragment stamp expected
  src="$ROOT/build/src/busybox-${BUSYBOX_VERSION}"
  out="$ROOT/build/busybox"
  fragment="$ROOT/config/busybox.min"
  stamp="$ROOT/build/stamps/busybox"
  [[ -d "$src" ]] || die "missing BusyBox source $src"
  [[ -f "$fragment" ]] || die "missing $fragment"
  mkdir -p -- "$out" "$ROOT/build/logs" "$ROOT/build/stamps"

  expected=$(sha256sum -- "$fragment" | awk '{ print $1 }')
  expected="${BUSYBOX_SHA256} ${expected}"
  if [[ -f "$stamp" && -x "$out/busybox" && "$(cat -- "$stamp")" == "$expected" ]]; then
    log "busybox: cache hit"
    return 0
  fi

  log "busybox: configuring"
  make -C "$src" O="$out" allnoconfig >"$ROOT/build/logs/busybox-config.log" 2>&1
  apply_min_config "$out/.config" "$fragment"
  make -C "$src" O="$out" oldconfig </dev/null >>"$ROOT/build/logs/busybox-config.log" 2>&1
  require_option "$out/.config" CONFIG_STATIC
  require_option "$out/.config" CONFIG_ASH
  require_option "$out/.config" CONFIG_SH_IS_ASH
  require_option "$out/.config" CONFIG_POWEROFF
  require_option "$out/.config" CONFIG_MOUNT
  if grep -q '^CONFIG_LOGIN=y$' "$out/.config"; then
    die "BusyBox config enabled login"
  fi

  log "busybox: compiling"
  make -C "$src" O="$out" -j"$(nproc)" >"$ROOT/build/logs/busybox-build.log" 2>&1
  [[ -x "$out/busybox" ]] || die "BusyBox build did not produce busybox"
  if readelf -h "$out/busybox" | grep -q 'Machine:.*X86-64'; then
    :
  else
    die "BusyBox is not an AMD64 executable"
  fi
  if readelf -d "$out/busybox" 2>/dev/null | grep -q 'NEEDED'; then
    die "BusyBox is not statically linked"
  fi
  "$out/busybox" ash -n "$ROOT/guest/init"
  printf '%s\n' "$expected" >"$stamp"
  log "busybox: built $out/busybox"
}

image_paths() {
  local image=$1 path=$2
  local line mode name child
  while IFS= read -r line; do
    [[ "$line" == /* ]] || continue
    IFS=/ read -r _ _ mode _ _ name _extra <<<"$line"
    [[ -n "$name" && "$name" != "." && "$name" != ".." ]] || continue
    if [[ "$path" == "/" ]]; then
      child="/${name}"
    else
      child="${path}/${name}"
    fi
    printf '%s\n' "$child"
    if [[ "$mode" == 04* ]]; then
      image_paths "$image" "$child"
    fi
  done < <(debugfs -R "ls -p ${path}" "$image")
}

own_rootfs() {
  local image=$1 cmds path
  cmds=$(mktemp "$TMPDIR/debugfs.XXXXXX")
  {
    echo "set_inode_field / uid 0"
    echo "set_inode_field / gid 0"
    while IFS= read -r path; do
      printf 'set_inode_field %s uid 0\n' "$path"
      printf 'set_inode_field %s gid 0\n' "$path"
    done < <(image_paths "$image" /)
  } >"$cmds"
  debugfs -w -f "$cmds" "$image" >/dev/null
  rm -f -- "$cmds"
}

make_guest_tree() {
  local tree=$1
  rm -rf -- "$tree"
  mkdir -p -- "$tree/bin" "$tree/sbin" "$tree/dev" "$tree/proc" "$tree/sys" "$tree/tmp"
  cp -f -- "$ROOT/build/busybox/busybox" "$tree/bin/busybox"
  chmod 755 "$tree/bin/busybox"
  ln -s busybox "$tree/bin/sh"
  cp -f -- "$ROOT/guest/init" "$tree/sbin/init"
  chmod 755 "$tree/sbin/init"
  cp -f -- "$ROOT/guest/startup" "$tree/bin/startup"
  chmod 755 "$tree/bin/startup"
}

write_ext4() {
  local tree=$1 image=$2
  command -v mke2fs >/dev/null 2>&1 || die "mke2fs is missing (Ubuntu package: e2fsprogs)"
  command -v debugfs >/dev/null 2>&1 || die "debugfs is missing (Ubuntu package: e2fsprogs)"
  rm -f -- "$image"
  mke2fs -F -q -t ext4 -b 4096 -m 0 \
    -d "$tree" \
    -E root_owner=0:0 \
    -O '^64bit,^metadata_csum' \
    -L rootfs \
    "$image" 32M
  own_rootfs "$image"
  e2fsck -fn "$image" >"$ROOT/build/logs/rootfs-fsck.log" 2>&1
}

build_rootfs() {
  local tree image stamp expected init_hash
  tree="$ROOT/build/rootfs-tree"
  image="$ROOT/build/artifacts/rootfs.img"
  stamp="$ROOT/build/stamps/rootfs"
  build_busybox
  init_hash=$(sha256sum -- "$ROOT/guest/init" "$ROOT/guest/startup" | sha256sum | awk '{ print $1 }')
  expected="${init_hash} $(cat -- "$ROOT/build/stamps/busybox")"
  if [[ -f "$stamp" && -f "$image" && "$(cat -- "$stamp")" == "$expected" ]]; then
    log "rootfs: cache hit rootfs.img"
    return 0
  fi
  log "rootfs: creating ext4 image"
  make_guest_tree "$tree"
  write_ext4 "$tree" "$image"
  printf '%s\n' "$expected" >"$stamp"
  log "rootfs: built $image"
}
