#!/usr/bin/env bash
set -euo pipefail

PROJECT="${PROJECT:-aicalendarapp.xcodeproj}"
SCHEME="${SCHEME:-aicalendarapp}"
CONFIGURATION="${CONFIGURATION:-Debug}"
ONLY_TESTING="${ONLY_TESTING:-aicalendarappTests}"

if [[ -z "${WORK_ROOT:-}" ]]; then
  if [[ -n "${RUNNER_TEMP:-}" ]]; then
    WORK_ROOT="$RUNNER_TEMP"
  else
    WORK_ROOT="$PWD/.build/ci-ios"
  fi
fi
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$WORK_ROOT/DerivedData}"
SOURCE_PACKAGES_PATH="${SOURCE_PACKAGES_PATH:-$WORK_ROOT/SourcePackages}"
RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-$WORK_ROOT/aicalendarapp.xcresult}"
PACKAGE_CACHE_PATH="${PACKAGE_CACHE_PATH:-$WORK_ROOT/PackageCache}"
if [[ -z "${PACKAGE_RESOLUTION_TIMEOUT_SECONDS:-}" ]]; then
  if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    PACKAGE_RESOLUTION_TIMEOUT_SECONDS=900
  else
    PACKAGE_RESOLUTION_TIMEOUT_SECONDS=900
  fi
fi

if [[ -z "${IOS_CI_SIMULATOR_BOOT_TIMEOUT_SECONDS:-}" ]]; then
  IOS_CI_SIMULATOR_BOOT_TIMEOUT_SECONDS=300
fi

if [[ -z "${IOS_CI_TEST_TIMEOUT_SECONDS:-}" ]]; then
  if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    IOS_CI_TEST_TIMEOUT_SECONDS=2400
  else
    IOS_CI_TEST_TIMEOUT_SECONDS=2400
  fi
fi

PACKAGE_RESOLUTION_ATTEMPTS="${PACKAGE_RESOLUTION_ATTEMPTS:-2}"

if [[ -z "${RESET_IOS_CI_PACKAGES:-}" ]]; then
  if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    RESET_IOS_CI_PACKAGES=true
  else
    RESET_IOS_CI_PACKAGES=false
  fi
fi

if [[ -z "${DISABLE_IOS_CI_PACKAGE_REPOSITORY_CACHE:-}" ]]; then
  if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    DISABLE_IOS_CI_PACKAGE_REPOSITORY_CACHE=true
  else
    DISABLE_IOS_CI_PACKAGE_REPOSITORY_CACHE=false
  fi
fi

PACKAGE_REPOSITORY_CACHE_ARG=""
if [[ "$DISABLE_IOS_CI_PACKAGE_REPOSITORY_CACHE" == "true" ]]; then
  PACKAGE_REPOSITORY_CACHE_ARG="-disablePackageRepositoryCache"
fi

if [[ -z "${IOS_CI_GIT_HTTP_VERSION:-}" && "${GITHUB_ACTIONS:-false}" != "true" ]]; then
  IOS_CI_GIT_HTTP_VERSION="HTTP/1.1"
fi

if [[ -z "${IOS_CI_GIT_LOW_SPEED_LIMIT+x}" && "${GITHUB_ACTIONS:-false}" != "true" ]]; then
  IOS_CI_GIT_LOW_SPEED_LIMIT=1024
fi

if [[ -z "${IOS_CI_GIT_LOW_SPEED_TIME+x}" && "${GITHUB_ACTIONS:-false}" != "true" ]]; then
  IOS_CI_GIT_LOW_SPEED_TIME=120
fi

append_git_config() {
  local key="$1"
  local value="$2"
  local config_index="${GIT_CONFIG_COUNT:-0}"

  export GIT_CONFIG_COUNT=$((config_index + 1))
  export "GIT_CONFIG_KEY_${config_index}=$key"
  export "GIT_CONFIG_VALUE_${config_index}=$value"
}

IOS_CI_GIT_HTTP_VERSION_APPLIED=false
if [[ -n "${IOS_CI_GIT_HTTP_VERSION:-}" ]]; then
  append_git_config http.version "$IOS_CI_GIT_HTTP_VERSION"
  IOS_CI_GIT_HTTP_VERSION_APPLIED=true
fi

IOS_CI_GIT_LOW_SPEED_APPLIED=false
if [[ -n "${IOS_CI_GIT_LOW_SPEED_LIMIT:-}" && -n "${IOS_CI_GIT_LOW_SPEED_TIME:-}" ]]; then
  append_git_config http.lowSpeedLimit "$IOS_CI_GIT_LOW_SPEED_LIMIT"
  append_git_config http.lowSpeedTime "$IOS_CI_GIT_LOW_SPEED_TIME"
  IOS_CI_GIT_LOW_SPEED_APPLIED=true
fi

created_simulator=""

cleanup() {
  if [[ -n "$created_simulator" && "${KEEP_CI_SIMULATOR:-false}" != "true" ]]; then
    xcrun simctl shutdown "$created_simulator" >/dev/null 2>&1 || true
    xcrun simctl delete "$created_simulator" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

run_with_timeout() {
  local timeout_seconds="$1"
  local timeout_label="$2"
  local diagnostics_function="$3"
  shift 3

  if [[ "$timeout_seconds" -le 0 ]]; then
    "$@"
    return "$?"
  fi

  echo "$timeout_label timeout: ${timeout_seconds}s"

  "$@" &
  local command_pid="$!"

  (
    sleep "$timeout_seconds"
    if kill -0 "$command_pid" >/dev/null 2>&1; then
      echo "$timeout_label timed out after ${timeout_seconds} seconds: $*" >&2
      if [[ -n "$diagnostics_function" ]]; then
        "$diagnostics_function"
      fi
      terminate_process_tree "$command_pid" TERM
      sleep 5
      terminate_process_tree "$command_pid" KILL
    fi
  ) &
  local watchdog_pid="$!"

  local status=0
  wait "$command_pid" || status="$?"
  kill "$watchdog_pid" >/dev/null 2>&1 || true
  wait "$watchdog_pid" >/dev/null 2>&1 || true
  return "$status"
}

terminate_process_tree() {
  local root_pid="$1"
  local signal="$2"
  local child_pid

  while read -r child_pid; do
    [[ -z "$child_pid" ]] && continue
    terminate_process_tree "$child_pid" "$signal"
  done < <(pgrep -P "$root_pid" 2>/dev/null || true)

  kill "-$signal" "$root_pid" >/dev/null 2>&1 || true
}

print_package_resolution_diagnostics() {
  echo "Active package-resolution processes:" >&2
  ps -axo pid=,ppid=,stat=,etime=,command= | awk -v source="$SOURCE_PACKAGES_PATH" -v cache="$PACKAGE_CACHE_PATH" '
    index($0, source) || index($0, cache) || $0 ~ /xcodebuild -resolvePackageDependencies/ { print }
  ' >&2 || true

  echo "Package directory sizes:" >&2
  du -sh "$SOURCE_PACKAGES_PATH" "$PACKAGE_CACHE_PATH" 2>/dev/null >&2 || true
}

print_ios_test_diagnostics() {
  echo "Active Xcode test and simulator processes:" >&2
  ps -axo pid=,ppid=,stat=,etime=,command= | awk '
    $0 ~ /xcodebuild test/ ||
    $0 ~ /xctest/ ||
    $0 ~ /Simulator/ ||
    $0 ~ /CoreSimulator/ { print }
  ' >&2 || true

  if [[ -n "$created_simulator" ]]; then
    echo "CI simulator state:" >&2
    xcrun simctl list devices 2>/dev/null | awk -v udid="$created_simulator" 'index($0, udid) { print }' >&2 || true
  fi

  echo "DerivedData, SourcePackages, and result bundle sizes:" >&2
  du -sh "$DERIVED_DATA_PATH" "$SOURCE_PACKAGES_PATH" "$RESULT_BUNDLE_PATH" 2>/dev/null >&2 || true
}

terminate_package_resolution_processes() {
  local pid
  local current_subshell_pid="${BASHPID:-}"
  while read -r pid; do
    [[ -z "$pid" || "$pid" == "$$" || "$pid" == "$current_subshell_pid" ]] && continue
    kill -TERM "$pid" >/dev/null 2>&1 || true
  done < <(ps -axo pid=,command= | awk -v source="$SOURCE_PACKAGES_PATH" -v cache="$PACKAGE_CACHE_PATH" '
    (index($0, source) || index($0, cache)) && $0 !~ /awk -v source=/ { print $1 }
  ')
  sleep 2

  while read -r pid; do
    [[ -z "$pid" || "$pid" == "$$" || "$pid" == "$current_subshell_pid" ]] && continue
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done < <(ps -axo pid=,command= | awk -v source="$SOURCE_PACKAGES_PATH" -v cache="$PACKAGE_CACHE_PATH" '
    (index($0, source) || index($0, cache)) && $0 !~ /awk -v source=/ { print $1 }
  ')
}

replace_path_with_clean_directory() {
  local path="$1"
  if [[ -e "$path" ]]; then
    local stale_path="${path}.stale.$$.$(date +%s).$RANDOM"
    mv "$path" "$stale_path" >/dev/null 2>&1 || rm -rf "$path" >/dev/null 2>&1 || true
    rm -rf "$stale_path" >/dev/null 2>&1 || true
  fi
  mkdir -p "$path"
}

clear_package_resolution_state() {
  terminate_package_resolution_processes
  replace_path_with_clean_directory "$SOURCE_PACKAGES_PATH"
  replace_path_with_clean_directory "$PACKAGE_CACHE_PATH"

  local repository_cache="${SWIFTPM_REPOSITORY_CACHE:-$HOME/Library/Caches/org.swift.swiftpm/repositories}"
  if [[ -d "$repository_cache" ]]; then
    find "$repository_cache" -maxdepth 1 -type d \( \
      -iname "*Superscript*" -o \
      -iname "*Superwall*" \
    \) -exec rm -rf {} +
  fi
}

run_package_resolution_with_retries() {
  local attempts="$1"
  shift

  local attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if run_with_timeout "$PACKAGE_RESOLUTION_TIMEOUT_SECONDS" "Package resolution" print_package_resolution_diagnostics "$@"; then
      return 0
    fi

    if ((attempt == attempts)); then
      terminate_package_resolution_processes
      return 1
    fi

    echo "Package resolution failed; clearing SwiftPM package state before retry ($attempt/$attempts)." >&2
    clear_package_resolution_state
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

mkdir -p "$DERIVED_DATA_PATH" "$SOURCE_PACKAGES_PATH" "$PACKAGE_CACHE_PATH"
rm -rf "$RESULT_BUNDLE_PATH"

echo "Xcode version:"
xcodebuild -version
echo "Package cache path: $PACKAGE_CACHE_PATH"
echo "Package resolution timeout: ${PACKAGE_RESOLUTION_TIMEOUT_SECONDS}s; attempts: ${PACKAGE_RESOLUTION_ATTEMPTS}; reset packages: $RESET_IOS_CI_PACKAGES; disable repository cache: $DISABLE_IOS_CI_PACKAGE_REPOSITORY_CACHE"
echo "Simulator boot timeout: ${IOS_CI_SIMULATOR_BOOT_TIMEOUT_SECONDS}s; test timeout: ${IOS_CI_TEST_TIMEOUT_SECONDS}s"
if [[ "$IOS_CI_GIT_HTTP_VERSION_APPLIED" == "true" ]]; then
  echo "Git HTTP version override: $IOS_CI_GIT_HTTP_VERSION"
fi
if [[ "$IOS_CI_GIT_LOW_SPEED_APPLIED" == "true" ]]; then
  echo "Git low-speed guard: ${IOS_CI_GIT_LOW_SPEED_LIMIT} bytes/s for ${IOS_CI_GIT_LOW_SPEED_TIME}s"
fi

if [[ "$RESET_IOS_CI_PACKAGES" == "true" ]]; then
  clear_package_resolution_state
fi

resolve_packages() {
  xcodebuild -resolvePackageDependencies \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH" \
    -packageCachePath "$PACKAGE_CACHE_PATH" \
    -scmProvider system \
    ${PACKAGE_REPOSITORY_CACHE_ARG:+"$PACKAGE_REPOSITORY_CACHE_ARG"} \
    -skipPackageUpdates \
    -onlyUsePackageVersionsFromResolvedFile
}

run_package_resolution_with_retries "$PACKAGE_RESOLUTION_ATTEMPTS" resolve_packages

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
  run_with_timeout "$IOS_CI_SIMULATOR_BOOT_TIMEOUT_SECONDS" "Simulator boot" print_ios_test_diagnostics xcrun simctl bootstatus "$created_simulator" -b
  destination="platform=iOS Simulator,id=$created_simulator"
fi

echo "Using destination: $destination"

run_unit_tests() {
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$destination" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH" \
    -packageCachePath "$PACKAGE_CACHE_PATH" \
    -scmProvider system \
    ${PACKAGE_REPOSITORY_CACHE_ARG:+"$PACKAGE_REPOSITORY_CACHE_ARG"} \
    -resultBundlePath "$RESULT_BUNDLE_PATH" \
    -only-testing:"$ONLY_TESTING" \
    -skipPackageUpdates \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO
}

run_with_timeout "$IOS_CI_TEST_TIMEOUT_SECONDS" "iOS unit tests" print_ios_test_diagnostics run_unit_tests
