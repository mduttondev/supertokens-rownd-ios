#!/bin/bash

set -euo pipefail

repository_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_root="${TMPDIR:-/tmp}/rownd-cocoapods-runtime"

cleanup() {
  if [[ "${KEEP_COCOAPODS_RUNTIME_FIXTURE:-0}" != "1" ]]; then
    rm -rf "$fixture_root"
  fi
}
trap cleanup EXIT

rm -rf "$fixture_root"

for linkage in static-library static-framework dynamic-framework; do
  work_dir="$fixture_root/$linkage"
  ruby "$repository_dir/Tests/CocoaPodsRuntime/generate_project.rb" "$work_dir" "$repository_dir" "$linkage"
  pod install --project-directory="$work_dir"

  xcodebuild \
    -workspace "$work_dir/CocoaPodsRuntime.xcworkspace" \
    -scheme CocoaPodsRuntime \
    -destination "${COCOAPODS_RUNTIME_DESTINATION:-${IOS_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17}}" \
    -derivedDataPath "$work_dir/DerivedData" \
    -parallel-testing-enabled NO \
    test
done
