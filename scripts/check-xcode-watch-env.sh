#!/usr/bin/env bash
set -u

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root" || exit 1

section() {
  printf '\n== %s ==\n' "$1"
}

run() {
  printf '+ %s\n' "$*"
  "$@"
}

section "Xcode"
run xcode-select -p
run xcodebuild -version
run xcodebuild -checkFirstLaunchStatus

section "Installed SDKs"
run xcodebuild -showsdks

section "Simulator Runtimes"
run xcrun simctl list runtimes

section "Connected Devices"
run xcrun xctrace list devices

section "Xcode Language Model Download State"
if defaults read com.apple.dt.Xcode >/tmp/motionsound-xcode-defaults.txt 2>/dev/null; then
  rg -i "DVTTextEnablePredictiveCompletion|IDE_CA_Daily_LanguageModel|IDEModelAccess" /tmp/motionsound-xcode-defaults.txt || true
else
  echo "No readable com.apple.dt.Xcode defaults."
fi
rm -f /tmp/motionsound-xcode-defaults.txt

section "Project Schemes"
run xcodebuild -list -project MotionSoundWatch.xcodeproj

section "Phone Destinations"
run xcodebuild -project MotionSoundWatch.xcodeproj -scheme MotionSoundPhone -showdestinations

section "Watch Destinations"
run xcodebuild -project MotionSoundWatch.xcodeproj -scheme MotionSoundWatch -showdestinations

section "Build Smoke Tests"
run swift test
run xcodebuild -project MotionSoundWatch.xcodeproj -target MotionSoundPhone -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
run xcodebuild -project MotionSoundWatch.xcodeproj -target MotionSoundWatch -configuration Debug -sdk watchos CODE_SIGNING_ALLOWED=NO build
run xcodebuild -project MotionSoundWatch.xcodeproj -target MotionSoundPhone -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
run xcodebuild -project MotionSoundWatch.xcodeproj -target MotionSoundWatch -configuration Debug -sdk watchsimulator CODE_SIGNING_ALLOWED=NO build

section "Result"
echo "If Connected Devices only lists the Mac, plug in and unlock the iPhone, trust this Mac, enable Developer Mode on iPhone and Watch, then rerun this script."
echo "If simulator runtimes are empty, real-device development can continue; install runtimes later from Xcode > Settings > Components or xcodebuild -downloadPlatform."
