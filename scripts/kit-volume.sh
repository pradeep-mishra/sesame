#!/bin/bash
# kit-volume.sh make | detach | attach | destroy | ping
#
# The unplugged-drive stand-in (verify.md, Kit scripts and Not covered; S7.8): a disk image that is mounted
# like a drive, detached like an unplug and attached again like a plug-in. Real removal, sleep and wake and
# network volumes stay unproven (a mounted image detached and reattached stands in for a USB drive).
#   make      builds a fresh sparse disk image under $KIT_ROOT/run/volume/, mounts it at the fixed mount path
#             $KIT_ROOT/run/volume/mnt, fills it with the generated golden photos (built by
#             kit-fixtures.sh build golden, copied to <mount>/photos) and prints the mount path as its
#             last line. An earlier image is destroyed first.
#   detach    unmounts it (the unplug); forced when a program still holds a file. Exit 4 when nothing is mounted.
#   attach    mounts the same image again at the same mount path and prints it as its last line (the plug-in).
#             Exit 4 when there is no image (make first).
#   destroy   detaches and deletes the image and its folder. Exit 0 whether one existed or not (the call
#             `kit-reset.sh --cleanup` makes).
#   ping      makes a tiny image elsewhere, attaches it, writes a file, detaches it, attaches it again and
#             finds the same path and the file, then detaches and deletes it.
# Exit codes: 0 done; 1 failed; 2 usage; 4 not valid (a precondition did not hold).
. "$(dirname "$0")/kit-lib/common.sh"

VOL="$KIT_ROOT/run/volume"
IMAGE="$KIT_ROOT/run/volume/sesame-kit-volume.sparseimage"
MOUNT="$KIT_ROOT/run/volume/mnt"
VOLNAME="SesameKitVolume"

usage() {
  cat >&2 <<'EOF'
usage: kit-volume.sh make | detach | attach | destroy | ping
       make      build a disk image under KIT_ROOT/run, mount it, fill it with generated photos, print the mount path
       detach    unmount it (the unplug)
       attach    mount the same image at the same mount path (the plug-in)
       destroy   detach and delete the image
       ping      a tiny image is attached, detached and attached again
EOF
}

# is_mounted <path> : status 0 when a volume is mounted at that path (the mount table names the real path).
is_mounted() {
  local real
  real="$(cd "$1" 2>/dev/null && pwd -P)"
  mount | awk -v a="$1" -v b="$real" '$2 == "on" && ($3 == a || (b != "" && $3 == b)) { f = 1 } END { exit !f }'
}

# do_attach <image> <mount path> : mounts the image at exactly that path.
do_attach() {
  local out
  mkdir -p "$2" || return 1
  out="$(hdiutil attach "$1" -mountpoint "$2" -noverify -noautoopen 2>&1)" || {
    echo "hdiutil attach failed: $out"
    return 1
  }
  is_mounted "$2" || { echo "hdiutil attach said ok but nothing is mounted at $2: $out"; return 1; }
  return 0
}

# do_detach <mount path> : unmounts it; forced when a program holds a file on it.
do_detach() {
  local out i
  for i in 1 2 3; do
    out="$(hdiutil detach "$1" 2>&1)" && return 0
    is_mounted "$1" || return 0
    sleep 1
  done
  out="$(hdiutil detach "$1" -force 2>&1)" && return 0
  is_mounted "$1" || return 0
  echo "hdiutil detach failed: $out"
  return 1
}

cmd_destroy() {
  local was=0
  if [ -d "$MOUNT" ] && is_mounted "$MOUNT"; then
    was=1
    do_detach "$MOUNT" || echo "note: the image could not be detached"
  fi
  if [ -e "$IMAGE" ]; then
    was=1
    rm -f "$IMAGE"
  fi
  [ -d "$VOL" ] && { rmdir "$MOUNT" 2>/dev/null; rmdir "$VOL" 2>/dev/null; }
  if [ "$was" = 1 ]; then
    echo "disk image detached and deleted"
  else
    echo "no disk image existed"
  fi
  return 0
}

cmd_make() {
  local src n out
  cmd_destroy >/dev/null
  out="$(KIT_NO_EVIDENCE=1 "$KIT_SCRIPTS/kit-fixtures.sh" build golden 2>&1)" || {
    echo "kit-fixtures.sh build golden failed: $out"
    return 1
  }
  src="$KIT_ROOT/fixtures/golden/photos"
  if [ ! -d "$src" ]; then
    echo "kit-fixtures.sh build golden left no $src"
    return 1
  fi
  mkdir -p "$VOL" || return 1
  out="$(hdiutil create -type SPARSE -size 256m -fs APFS -volname "$VOLNAME" "$IMAGE" 2>&1)" || {
    echo "hdiutil create failed: $out"
    return 1
  }
  do_attach "$IMAGE" "$MOUNT" || { cmd_destroy >/dev/null; return 1; }
  mkdir -p "$MOUNT/photos" || { cmd_destroy >/dev/null; return 1; }
  cp -pR "$src/." "$MOUNT/photos/" || { echo "could not copy the photos to $MOUNT/photos"; cmd_destroy >/dev/null; return 1; }
  n="$(find "$MOUNT/photos" -type f | wc -l | tr -d ' ')"
  if [ "$n" = 0 ]; then
    echo "no photo reached the volume"
    cmd_destroy >/dev/null
    return 1
  fi
  echo "disk image $IMAGE made, volume $VOLNAME mounted, $n generated photos in $MOUNT/photos"
  echo "$MOUNT"
  return 0
}

cmd_detach() {
  if [ ! -d "$MOUNT" ] || ! is_mounted "$MOUNT"; then
    echo "not valid: nothing is mounted at $MOUNT (scripts/kit-volume.sh make or attach first)"
    return 4
  fi
  do_detach "$MOUNT" || return 1
  echo "detached $MOUNT (the drive is unplugged; the image is kept)"
  return 0
}

cmd_attach() {
  if [ ! -e "$IMAGE" ]; then
    echo "not valid: there is no disk image (scripts/kit-volume.sh make first)"
    return 4
  fi
  if [ -d "$MOUNT" ] && is_mounted "$MOUNT"; then
    echo "already mounted"
    echo "$MOUNT"
    return 0
  fi
  do_attach "$IMAGE" "$MOUNT" || return 1
  echo "attached $IMAGE"
  echo "$MOUNT"
  return 0
}

cmd_ping() {
  local d="$KIT_ROOT/run/volume-ping" img mnt out ok=1
  img="$d/ping.sparseimage"
  mnt="$d/mnt"
  rm -rf "$d"
  mkdir -p "$d" || return 1
  out="$(hdiutil create -type SPARSE -size 16m -fs APFS -volname SesameKitPing "$img" 2>&1)" || {
    echo "KIT-VOLUME PING FAILED: hdiutil create failed: $out"
    rm -rf "$d"
    return 1
  }
  if do_attach "$img" "$mnt"; then
    printf 'ping\n' > "$mnt/ping.txt"
    if do_detach "$mnt" && ! is_mounted "$mnt"; then
      echo "OK volume: detached, nothing mounted at $mnt"
      if do_attach "$img" "$mnt" && [ -f "$mnt/ping.txt" ]; then
        echo "OK volume: attached again at the same path $mnt, the file is there"
      else
        echo "FAILED volume: the second attach did not give the same path with the file"
        ok=0
      fi
      is_mounted "$mnt" && { do_detach "$mnt" || ok=0; }
    else
      echo "FAILED volume: the image did not detach"
      ok=0
    fi
  else
    ok=0
  fi
  is_mounted "$mnt" && do_detach "$mnt"
  rm -rf "$d"
  if [ "$ok" = 1 ]; then
    echo "KIT-VOLUME PING OK: a tiny disk image was attached, detached and attached again at one path, then deleted"
    return 0
  fi
  echo "KIT-VOLUME PING FAILED"
  return 1
}

main() {
  case "$1" in
    make) [ $# = 1 ] || { usage; return 2; }; cmd_make ;;
    detach) [ $# = 1 ] || { usage; return 2; }; cmd_detach ;;
    attach) [ $# = 1 ] || { usage; return 2; }; cmd_attach ;;
    destroy) [ $# = 1 ] || { usage; return 2; }; cmd_destroy ;;
    ping) [ $# = 1 ] || { usage; return 2; }; cmd_ping ;;
    *) usage; return 2 ;;
  esac
}

kit_wrap "$(kit_slug kit-volume "$@")" main "$@"
exit $?
