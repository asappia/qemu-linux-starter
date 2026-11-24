# Download and extract the pinned sources. Source this file; do not execute it.
[[ -n "${ROOT:-}" ]] || {
  printf 'error: source lib/acquire.sh from run.sh\n' >&2
  exit 1
}

load_sources() {
  local lock="config/sources.env"
  [[ -f "$lock" ]] || die "missing $lock"
  # shellcheck disable=SC1091
  source "$lock"
  local name value
  for name in LINUX_VERSION LINUX_URL LINUX_SHA256 LINUX_ARCHIVE \
    BUSYBOX_VERSION BUSYBOX_URL BUSYBOX_SHA256 BUSYBOX_ARCHIVE; do
    value=${!name:-}
    [[ -n "$value" ]] || die "$lock does not set $name"
  done
  [[ "$LINUX_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "LINUX_SHA256 is not a SHA-256 digest"
  [[ "$BUSYBOX_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "BUSYBOX_SHA256 is not a SHA-256 digest"
  [[ "$LINUX_URL" == https://* ]] || die "LINUX_URL must be an https URL"
  [[ "$BUSYBOX_URL" == https://* ]] || die "BUSYBOX_URL must be an https URL"
  case "${LINUX_ARCHIVE}${BUSYBOX_ARCHIVE}" in
    *[!a-zA-Z0-9._-]*)
      die "archive names must not contain path separators"
      ;;
  esac
}

file_sha256() {
  local actual rest
  read -r actual rest < <(sha256sum -- "$1")
  printf '%s\n' "$actual"
}

# True when a symlink target, joined with its archive path, stays under top.
symlink_stays_inside() {
  local member=$1 target=$2 top=$3
  local dir combined part resolved
  local -a raw=() parts=()
  if [[ "$member" == */* ]]; then
    dir=${member%/*}
  else
    dir=$top
  fi
  combined="${dir}/${target}"
  IFS=/ read -r -a raw <<< "$combined"
  for part in "${raw[@]}"; do
    case "$part" in
      '' | .) ;;
      ..)
        if [[ ${#parts[@]} -eq 0 ]]; then
          return 1
        fi
        unset 'parts[${#parts[@]}-1]'
        ;;
      *)
        parts+=("$part")
        ;;
    esac
  done
  resolved=$(
    IFS=/
    printf '%s' "${parts[*]}"
  )
  [[ "$resolved" == "$top" || "$resolved" == "$top"/* ]]
}

reject_archive_entries() {
  local archive=$1 expected_top=$2
  local list entry target member
  list=$(mktemp "$TMPDIR/archive-list.XXXXXX")
  if ! tar -tf "$archive" >"$list"; then
    rm -f -- "$list"
    die "unable to list archive $archive"
  fi
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -n "$entry" ]] || continue
    case "$entry" in
      "$expected_top"/* | "$expected_top") ;;
      *)
        rm -f -- "$list"
        die "archive $archive contains an unexpected path: $entry"
        ;;
    esac
    case "$entry" in
      /* | ../* | */../* | */..)
        rm -f -- "$list"
        die "archive $archive contains an unsafe path: $entry"
        ;;
    esac
  done <"$list"
  rm -f -- "$list"

  list=$(mktemp "$TMPDIR/archive-verbose.XXXXXX")
  if ! tar -tvf "$archive" >"$list"; then
    rm -f -- "$list"
    die "unable to inspect archive $archive"
  fi
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ "$entry" == *" -> "* ]] || continue
    target=${entry##* -> }
    member=${entry%% -> *}
    member=${member##* }
    case "$target" in
      /*)
        rm -f -- "$list"
        die "archive $archive contains an absolute symlink: $target"
        ;;
    esac
    if ! symlink_stays_inside "$member" "$target" "$expected_top"; then
      rm -f -- "$list"
      die "archive $archive contains a symlink that escapes: $member -> $target"
    fi
  done <"$list"
  rm -f -- "$list"
}

download_archive() {
  local archive=$1 url=$2 digest=$3
  local dest=".cache/sources/$archive"
  local actual attempt
  if [[ -e "$dest" && ! -f "$dest" ]]; then
    die "cached source $dest is not a regular file"
  fi
  if [[ -f "$dest" ]]; then
    actual=$(file_sha256 "$dest")
    if [[ "$actual" == "$digest" ]]; then
      log "download: cache hit $archive"
      return 0
    fi
    die "corrupt cached source $dest does not match the pinned SHA-256"
  fi

  partial_download=$(mktemp "$TMPDIR/download.XXXXXX")
  attempt=1
  while [[ "$attempt" -le 3 ]]; do
    if curl -q --fail --location --silent --show-error \
      --retry 3 --retry-delay 2 --connect-timeout 30 \
      --output "$partial_download" -- "$url"; then
      break
    fi
    if [[ "$attempt" -eq 3 ]]; then
      die "download failed for $archive"
    fi
    log "download: retry $attempt for $archive"
    sleep "$attempt"
    attempt=$((attempt + 1))
  done
  actual=$(file_sha256 "$partial_download")
  if [[ "$actual" != "$digest" ]]; then
    die "downloaded $archive does not match the pinned SHA-256"
  fi
  mv -f -- "$partial_download" "$dest"
  partial_download=""
  log "download: verified $archive"
}

extract_archive() {
  local archive=$1 top=$2
  local dest="build/src/$top"
  if [[ -e "$dest" ]]; then
    rm -rf -- "$dest"
  fi
  tar -xf ".cache/sources/$archive" -C build/src
  [[ -d "$dest" ]] || die "archive $archive did not create build/src/$top"
  log "download: extracted $top"
}

acquire_sources() {
  local stamp="build/stamps/sources"
  local expected recorded
  load_sources
  download_archive "$LINUX_ARCHIVE" "$LINUX_URL" "$LINUX_SHA256"
  download_archive "$BUSYBOX_ARCHIVE" "$BUSYBOX_URL" "$BUSYBOX_SHA256"
  expected=$(printf 'linux %s\nbusybox %s' "$LINUX_SHA256" "$BUSYBOX_SHA256")
  if [[ -f "$stamp" && -d "build/src/linux-${LINUX_VERSION}" && -d "build/src/busybox-${BUSYBOX_VERSION}" ]]; then
    recorded=$(cat -- "$stamp")
    if [[ "$recorded" == "$expected" ]]; then
      log "download: source trees are current"
      return 0
    fi
  fi
  reject_archive_entries ".cache/sources/$LINUX_ARCHIVE" "linux-${LINUX_VERSION}"
  reject_archive_entries ".cache/sources/$BUSYBOX_ARCHIVE" "busybox-${BUSYBOX_VERSION}"
  extract_archive "$LINUX_ARCHIVE" "linux-${LINUX_VERSION}"
  extract_archive "$BUSYBOX_ARCHIVE" "busybox-${BUSYBOX_VERSION}"
  printf '%s\n' "$expected" >"$stamp"
}
