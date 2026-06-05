#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/deploy_to_devices.sh

Environment overrides:
  PHONE_DEVICE_ID        iPhone CoreDevice id
  WATCH_DEVICE_ID        Apple Watch CoreDevice id
  DERIVED_DATA_PATH      Xcode DerivedData path
  MOTIONSOUND_TEST_RUN_ID  Reuse a specific diagnostics run id
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

project="MotionSoundWatch.xcodeproj"
scheme="MotionSoundPhone"
phone_bundle_id="com.zhongsuhua.MotionSoundPhone"
watch_bundle_id="com.zhongsuhua.MotionSoundPhone.watchkitapp"
phone_device_id="${PHONE_DEVICE_ID:-BAC2651E-2C9A-5BD5-BF85-6F98072714A9}"
watch_device_id="${WATCH_DEVICE_ID:-B291F720-5021-54B9-9B1E-DB2D0632D9A0}"
derived_data="${DERIVED_DATA_PATH:-/tmp/MotionSoundDeployDD}"

commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
dirty="false"
if ! git diff --quiet --ignore-submodules -- 2>/dev/null || ! git diff --cached --quiet --ignore-submodules -- 2>/dev/null; then
  dirty="true"
fi

timestamp="$(date -u +%Y%m%d-%H%M%S)"
run_id="${MOTIONSOUND_TEST_RUN_ID:-${timestamp}-${commit}}"
deploy_root="/tmp/motionsound-deployments/${run_id}"
mkdir -p "$deploy_root"

echo "MotionSound deploy run: ${run_id}"
echo "Git commit: ${commit} dirty=${dirty}"

xcodebuild \
  -project "$project" \
  -scheme "$scheme" \
  -destination "id=${phone_device_id}" \
  -configuration Debug \
  -derivedDataPath "$derived_data" \
  build | tee "${deploy_root}/xcodebuild.log"

phone_app="${derived_data}/Build/Products/Debug-iphoneos/MotionSoundPhone.app"
watch_app="$(find "${derived_data}/Build/Products/Debug-watchos" -maxdepth 2 -name 'MotionSoundWatch.app' -type d 2>/dev/null | head -n 1 || true)"

if [[ ! -d "$phone_app" ]]; then
  echo "Phone app not found: ${phone_app}" >&2
  exit 1
fi
if [[ -z "$watch_app" || ! -d "$watch_app" ]]; then
  echo "Watch app not found under ${derived_data}/Build/Products/Debug-watchos" >&2
  exit 1
fi

xcrun devicectl device install app --device "$phone_device_id" "$phone_app" \
  | tee "${deploy_root}/install-phone.log"
xcrun devicectl device install app --device "$watch_device_id" "$watch_app" \
  | tee "${deploy_root}/install-watch.log"

launch_env="{\"MOTIONSOUND_TEST_RUN_ID\":\"${run_id}\",\"MOTIONSOUND_BUILD_COMMIT\":\"${commit}\",\"MOTIONSOUND_RESET_DIAGNOSTICS\":\"1\"}"

xcrun devicectl device process launch \
  --device "$phone_device_id" \
  --terminate-existing \
  --environment-variables "$launch_env" \
  "$phone_bundle_id" \
  | tee "${deploy_root}/launch-phone.log"

xcrun devicectl device process launch \
  --device "$watch_device_id" \
  --terminate-existing \
  --environment-variables "$launch_env" \
  "$watch_bundle_id" \
  | tee "${deploy_root}/launch-watch.log"

cat > "${deploy_root}/deploy.json" <<JSON
{
  "schemaVersion": 1,
  "testRunId": "${run_id}",
  "buildCommit": "${commit}",
  "gitDirty": ${dirty},
  "project": "${project}",
  "scheme": "${scheme}",
  "phoneDeviceId": "${phone_device_id}",
  "watchDeviceId": "${watch_device_id}",
  "phoneBundleId": "${phone_bundle_id}",
  "watchBundleId": "${watch_bundle_id}",
  "derivedDataPath": "${derived_data}",
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

echo "${deploy_root}"
