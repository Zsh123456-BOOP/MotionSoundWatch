#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/fetch_app_logs.sh watch [destination]
  scripts/fetch_app_logs.sh phone [destination]

Environment overrides:
  WATCH_DEVICE_ID  Apple Watch UDID/CoreDevice id
  PHONE_DEVICE_ID  iPhone UDID/CoreDevice id
USAGE
}

target="${1:-}"
destination_root="${2:-/tmp/motionsound-logs}"

watch_device_id="${WATCH_DEVICE_ID:-B291F720-5021-54B9-9B1E-DB2D0632D9A0}"
phone_device_id="${PHONE_DEVICE_ID:-BAC2651E-2C9A-5BD5-BF85-6F98072714A9}"

case "$target" in
  watch)
    device_id="$watch_device_id"
    bundle_id="com.zhongsuhua.MotionSoundPhone.watchkitapp"
    ;;
  phone)
    device_id="$phone_device_id"
    bundle_id="com.zhongsuhua.MotionSoundPhone"
    ;;
  *)
    usage
    exit 2
    ;;
esac

timestamp="$(date -u +%Y%m%d-%H%M%S)"
destination="${destination_root}/${target}-${timestamp}"
mkdir -p "$destination"

copy_from_app() {
  local source_path="$1"
  local label="$2"
  if xcrun devicectl device copy from \
    --device "$device_id" \
    --domain-type appDataContainer \
    --domain-identifier "$bundle_id" \
    --source "$source_path" \
    --destination "$destination" >/dev/null 2>&1; then
    echo "Copied ${label} from ${target}." >&2
  else
    echo "No ${label} found on ${target}." >&2
  fi
}

copy_from_app Documents/MotionSoundDiagnostics MotionSoundDiagnostics
copy_from_app Documents/MotionSoundLogs MotionSoundLogs
copy_from_app Documents/MotionSoundTriggerLogs MotionSoundTriggerLogs
copy_from_app Documents/MotionSoundIncoming MotionSoundIncoming

echo "$destination"
