#!/bin/bash
set -euo pipefail

: "${GITHUB_ENV:?Run this provisioning script in a GitHub Actions test job}"

xcodebuild -version
sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
# Prefer the SDK's runtime, but CoreSimulator can support newer installed runtimes.
runtime_version="$(echo "$sdk_version" | cut -d. -f1,2)"
device_type=com.apple.CoreSimulator.SimDeviceType.iPhone-17
runtime_id=""

# CoreSimulator can still be discovering installed runtimes after switching Xcode.
for attempt in 1 2 3; do
  runtimes="$(xcrun simctl list runtimes --json)"
  runtime_id="$(jq -r --arg version "$runtime_version" --arg type "$device_type" '
    [.runtimes[] | select(.isAvailable == true)
      | select(.identifier | startswith("com.apple.CoreSimulator.SimRuntime.iOS-"))
      | select(any(.supportedDeviceTypes[]?; .identifier == $type))]
    | sort_by([((.version | split(".")[0:2] | join(".")) == $version),
               (.version | split(".") | map(tonumber)), .identifier])
    | last | .identifier // empty
  ' <<< "$runtimes")"
  if [[ -n "$runtime_id" ]]; then break; fi
  if [[ "$attempt" != 3 ]]; then sleep 5; fi
done

if [[ -z "$runtime_id" ]]; then
  echo "$runtimes"
  echo "::error::No available iOS runtime explicitly supporting iPhone 17 (selected SDK: $sdk_version). Install a compatible runtime, for example: xcodebuild -downloadPlatform iOS -buildVersion $runtime_version."
  exit 1
fi

devices="$(xcrun simctl list devices available --json)"
udid="$(jq -r --arg runtime "$runtime_id" --arg type "$device_type" '
  [.devices[$runtime][]? | select(.isAvailable == true and .deviceTypeIdentifier == $type)]
  | sort_by(.state != "Booted", .udid) | first | .udid // empty
' <<< "$devices")"
if [[ -z "$udid" ]]; then
  udid="$(xcrun simctl create 'iPhone 17' "$device_type" "$runtime_id")"
fi

echo "Using iPhone 17: $udid ($runtime_id, SDK $sdk_version)"
# Try a different installed runtime after a failed boot, not the same stalled device.
fallback_runtime_id="$(jq -r --arg primary "$runtime_id" --arg type "$device_type" '
  [.runtimes[] | select(.isAvailable == true)
    | select(.identifier | startswith("com.apple.CoreSimulator.SimRuntime.iOS-"))
    | select(any(.supportedDeviceTypes[]?; .identifier == $type))
    | select(.identifier != $primary)]
  | sort_by([(.version | split(".") | map(tonumber)), .identifier])
  | last | .identifier // $primary
' <<< "$runtimes")"
echo "If readiness fails: fresh CI device on $fallback_runtime_id (newest supported alternate, or same runtime if none)"
python3 "$(dirname "$0")/boot-ios-simulator.py" "$udid" "$fallback_runtime_id" "$device_type"
