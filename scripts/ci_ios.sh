#!/usr/bin/env bash
set -euo pipefail

PROJECT="${PROJECT:-aicalendarapp.xcodeproj}"
SCHEME="${SCHEME:-aicalendarapp}"
CONFIGURATION="${CONFIGURATION:-Debug}"
ONLY_TESTING="${ONLY_TESTING:-aicalendarappTests}"

WORK_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}/aicalendarapp-ci}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$WORK_ROOT/DerivedData}"
SOURCE_PACKAGES_PATH="${SOURCE_PACKAGES_PATH:-$WORK_ROOT/SourcePackages}"
RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-$WORK_ROOT/aicalendarapp.xcresult}"

created_simulator=""

cleanup() {
  if [[ -n "$created_simulator" && "${KEEP_CI_SIMULATOR:-false}" != "true" ]]; then
    xcrun simctl shutdown "$created_simulator" >/dev/null 2>&1 || true
    xcrun simctl delete "$created_simulator" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

run_with_retries() {
  local attempts="$1"
  shift

  local attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if "$@"; then
      return 0
    fi

    if ((attempt == attempts)); then
      return 1
    fi

    echo "Command failed; retrying in 10 seconds ($attempt/$attempts): $*" >&2
    sleep 10
  done
}

pick_device_type() {
  local candidate
  local match
  for candidate in "iPhone 17" "iPhone 16" "iPhone 15" "iPhone 14"; do
    match="$(xcrun simctl list devicetypes | awk -v candidate="$candidate" '
      index($0, candidate " (") == 1 {
        sub(/^.*\(/, "")
        sub(/\).*$/, "")
        print
        exit
      }
    ')"
    if [[ -n "$match" ]]; then
      printf "%s\n" "$match"
      return 0
    fi
  done
}

pick_runtime() {
  xcrun simctl list runtimes available | awk '/^iOS / { runtime=$NF } END { print runtime }'
}

destination="${IOS_CI_DESTINATION:-}"
if [[ -z "$destination" ]]; then
  runtime="$(pick_runtime)"
  device_type="$(pick_device_type)"

  if [[ -z "$runtime" || -z "$device_type" ]]; then
    echo "Could not find an available iOS simulator runtime and iPhone device type." >&2
    xcrun simctl list runtimes available >&2
    xcrun simctl list devicetypes >&2
    exit 1
  fi

  created_simulator="$(xcrun simctl create "AI Calendar CI ${GITHUB_RUN_ID:-local}-$$" "$device_type" "$runtime")"
  xcrun simctl boot "$created_simulator"
  xcrun simctl bootstatus "$created_simulator" -b
  destination="platform=iOS Simulator,id=$created_simulator"
fi

mkdir -p "$DERIVED_DATA_PATH" "$SOURCE_PACKAGES_PATH"
rm -rf "$RESULT_BUNDLE_PATH"

echo "Xcode version:"
xcodebuild -version
echo "Using destination: $destination"

resolve_packages() {
  xcodebuild -resolvePackageDependencies \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH" \
    -skipPackageUpdates \
    -onlyUsePackageVersionsFromResolvedFile
}

run_unit_tests() {
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$destination" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH" \
    -resultBundlePath "$RESULT_BUNDLE_PATH" \
    -only-testing:"$ONLY_TESTING" \
    -skipPackageUpdates \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO
}

run_with_retries 3 resolve_packages
run_unit_tests
