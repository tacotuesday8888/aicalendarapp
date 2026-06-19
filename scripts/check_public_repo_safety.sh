#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

failures=0

report_failure() {
  printf '::error::%s\n' "$1" >&2
  failures=1
}

tracked_path_matches() {
  local pattern="$1"
  git ls-files | awk -v pattern="$pattern" '$0 ~ pattern { print }'
}

check_forbidden_paths() {
  local matches
  local -a forbidden_patterns=(
    '(^|/)\.firebaserc$'
    '(^|/)\.env($|[^A-Za-z0-9_].*)'
    '(^|/)GoogleService-Info\.plist$'
    '(^|/)Secrets\.xcconfig$'
    '(^|/)Secrets\.[^.]+\.xcconfig$'
    '(^|/)ExportOptions\.plist$'
    '(^|/)private/'
    '(^|/)docs/private/'
    '(^|/)node_modules/'
    '(^|/)\.build/'
    '(^|/)DerivedData/'
    '(^|/)xcuserdata/'
    '(^|/)\.firebase/'
    '(^|/)backend/functions/lib/'
    '(^|/).*\.xcarchive/'
    '(^|/).*\.mobileprovision$'
    '(^|/).*\.provisionprofile$'
    '(^|/).*\.p8$'
    '(^|/).*\.p12$'
    '(^|/).*\.cer$'
    '(^|/).*\.pem$'
    '(^|/).*\.key$'
    '(^|/).*\.keystore$'
    '(^|/).*\.log$'
  )

  for pattern in "${forbidden_patterns[@]}"; do
    matches="$(tracked_path_matches "$pattern" || true)"
    matches="$(
      printf '%s\n' "$matches" | awk '
        /(^|\/)\.env\.example$/ { next }
        /(^|\/)\.env\.template$/ { next }
        /(^|\/).*\.env\.example$/ { next }
        /(^|\/).*\.env\.template$/ { next }
        /(^|\/)Secrets\.template\.xcconfig$/ { next }
        NF { print }
      '
    )"
    if [[ -n "$matches" ]]; then
      report_failure "Forbidden public-repo path is tracked: pattern '$pattern'"
      printf '%s\n' "$matches" >&2
    fi
  done

  matches="$(git ls-files -ci --exclude-standard || true)"
  if [[ -n "$matches" ]]; then
    report_failure "Tracked files are ignored by .gitignore. These are usually local configs, generated outputs, or secrets:"
    printf '%s\n' "$matches" >&2
  fi
}

check_secret_like_content() {
  local label="$1"
  local pattern="$2"
  local matches
  local status

  set +e
  matches="$(
    git grep -I -n -E -e "$pattern" -- \
      . \
      ':(exclude)backend/functions/package-lock.json' \
      ':(exclude)Package.resolved'
  )"
  status="$?"
  set -e

  if [[ "$status" -gt 1 ]]; then
    report_failure "Public repository safety scan failed while checking: $label"
    return
  fi

  if [[ -n "$matches" ]]; then
    report_failure "Potential tracked secret or real service credential detected: $label"
    printf '%s\n' "$matches" >&2
  fi
}

check_forbidden_paths

check_secret_like_content "Google API key" 'AIza[0-9A-Za-z_-]{35}'
check_secret_like_content "OpenAI-style secret key" 'sk-[A-Za-z0-9_-]{20,}'
check_secret_like_content "RevenueCat secret key" 'sk_[A-Za-z0-9]{20,}'
check_secret_like_content "RevenueCat iOS public SDK key in tracked source" 'appl_[A-Za-z0-9]{20,}'
check_secret_like_content "GitHub token" 'gh[pousr]_[A-Za-z0-9_]{36,}'
check_secret_like_content "Slack token" 'xox[baprs]-[A-Za-z0-9-]{20,}'
check_secret_like_content "JWT-like token" 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}'
check_secret_like_content "private key material" '-----BEGIN ((RSA|DSA|EC|OPENSSH) )?PRIVATE KEY-----'
check_secret_like_content "Google OAuth client ID" '[0-9]{6,}-[A-Za-z0-9_-]{16,}\.apps\.googleusercontent\.com'

if [[ "$failures" -ne 0 ]]; then
  printf 'Public repository safety check failed.\n' >&2
  exit 1
fi

printf 'Public repository safety check passed.\n'
