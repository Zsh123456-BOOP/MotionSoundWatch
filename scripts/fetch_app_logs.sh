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

watch_device_id="${WATCH_DEVICE_ID:-00008310-0014FC5E0C28A01E}"
phone_device_id="${PHONE_DEVICE_ID:-00008130-00114C441AE8001C}"

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

xcrun devicectl device copy from \
  --device "$device_id" \
  --domain-type appDataContainer \
  --domain-identifier "$bundle_id" \
  --source Documents/MotionSoundLogs \
  --destination "$destination"

echo "$destination"
