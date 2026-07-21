#!/bin/sh
set -eu

: "${RESTORE_SOURCE:?RESTORE_SOURCE is required}"
: "${RESTORE_TARGET:?RESTORE_TARGET is required}"

if [ -e "$RESTORE_TARGET" ] && [ "$(find "$RESTORE_TARGET" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  echo "restore target must be absent or empty" >&2
  exit 64
fi

target_name=$(basename "$RESTORE_TARGET")
if ! tar -tzf "$RESTORE_SOURCE" | awk -v root="$target_name" '
  BEGIN { ok=1 }
  $0 ~ /^\// || $0 ~ /(^|\/)\.\.($|\/)/ || ($0 != root && index($0, root "/") != 1) { ok=0 }
  END { exit ok ? 0 : 1 }
'; then
  echo "backup contains unsafe or unexpected paths" >&2
  exit 65
fi

restore_tmp=$(mktemp -d "${TMPDIR:-/tmp}/photoapp-restore.XXXXXX")
trap 'rm -rf "$restore_tmp"' EXIT HUP INT TERM
tar -C "$restore_tmp" -xzf "$RESTORE_SOURCE"
ruby bin/verify_store "$restore_tmp/$target_name" >/dev/null
mkdir -p "$(dirname "$RESTORE_TARGET")"
if [ -d "$RESTORE_TARGET" ]; then
  rmdir "$RESTORE_TARGET"
fi
mv "$restore_tmp/$target_name" "$RESTORE_TARGET"
echo "restore verified at $RESTORE_TARGET"
