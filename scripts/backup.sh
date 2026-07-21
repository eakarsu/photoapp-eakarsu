#!/bin/sh
set -eu

: "${PHOTOAPP_DATA_ROOT:?PHOTOAPP_DATA_ROOT is required}"
: "${BACKUP_PATH:?BACKUP_PATH is required}"

ruby bin/verify_store "$PHOTOAPP_DATA_ROOT" >/dev/null
parent=$(dirname "$PHOTOAPP_DATA_ROOT")
name=$(basename "$PHOTOAPP_DATA_ROOT")
temporary="${BACKUP_PATH}.tmp.$$"
trap 'rm -f "$temporary"' EXIT HUP INT TERM
tar -C "$parent" -czf "$temporary" "$name"
mv "$temporary" "$BACKUP_PATH"
trap - EXIT HUP INT TERM
echo "backup written to $BACKUP_PATH"
