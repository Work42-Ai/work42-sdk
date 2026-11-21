#!/bin/bash
# api-baseline.sh — the public API of Work42UI and Work42PluginKit, frozen per SDK release (WOR-856).
#
#   scripts/api-baseline.sh dump    write api-baselines/<version>/<Module>.json for the current SDK version
#   scripts/api-baseline.sh check   diagnose the current SDK against the newest baseline with the same major version
#
# `check` exits non-zero when a public declaration was removed or changed; additions pass. A major version with no
# baseline yet passes with a note (the first release of a major version has nothing to break).
# Run `dump` once per release, after the version bump, and commit the result: a baseline is never regenerated.

set -euo pipefail

SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINES="$SDK_ROOT/api-baselines"
VERSION_FILE="$SDK_ROOT/Work42UI/Sources/Work42UI/Work42SDKCompatibility.swift"
MODULES=(Work42UI Work42PluginKit)

die() { echo "api-baseline: $*" >&2; exit 1; }

sdk_version() {
  sed -n 's/.*static let version = "\([0-9][0-9.]*[^"]*\)".*/\1/p' "$VERSION_FILE" | head -1
}

major_of() { echo "${1%%.*}"; }

# Builds both packages and prints the directories holding their .swiftmodule files, one -I flag each.
build_and_module_flags() {
  local flags=()
  for module in "${MODULES[@]}"; do
    (cd "$SDK_ROOT/$module" && swift build --target "$module" >&2) || die "swift build failed for $module"
    local bin
    bin="$(cd "$SDK_ROOT/$module" && swift build --show-bin-path)"
    flags+=(-I "$bin/Modules" -I "$bin")
  done
  printf '%s\n' "${flags[@]}"
}

digester_common() {
  local target
  target="$(swift -print-target-info | sed -n 's/.*"unversionedTriple" *: *"\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "$target" ]] || die "cannot read the compiler's target triple"
  echo "-sdk" "$(xcrun --show-sdk-path)" "-target" "${target/macosx/macosx15.0}" "-swift-only"
}

dump_to() {
  local out_dir="$1"
  mkdir -p "$out_dir"
  local -a include common
  while IFS= read -r line; do include+=("$line"); done < <(build_and_module_flags)
  read -r -a common <<<"$(digester_common)"
  for module in "${MODULES[@]}"; do
    xcrun swift-api-digester -dump-sdk -module "$module" "${include[@]}" "${common[@]}" -o "$out_dir/$module.json" \
      || die "swift-api-digester could not dump $module"
    echo "wrote $out_dir/$module.json"
  done
}

# The newest api-baselines/<x.y.z> whose major version is $1, or nothing.
newest_baseline_for_major() {
  local major="$1"
  [[ -d "$BASELINES" ]] || return 0
  ls "$BASELINES" | grep -E "^${major}\.[0-9]+\.[0-9]+$" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}

cmd="${1:-}"
version="$(sdk_version)"
[[ -n "$version" ]] || die "cannot read the SDK version from $VERSION_FILE"

case "$cmd" in
  dump)
    [[ -e "$BASELINES/$version" ]] && die "baseline $version already exists; baselines are never regenerated"
    dump_to "$BASELINES/$version"
    ;;
  check)
    base="$(newest_baseline_for_major "$(major_of "$version")")"
    if [[ -z "$base" ]]; then
      echo "api-baseline: no baseline for major version $(major_of "$version") yet; nothing to check"
      exit 0
    fi
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    dump_to "$work/current" >/dev/null
    declare -a include common
    while IFS= read -r line; do include+=("$line"); done < <(build_and_module_flags 2>/dev/null)
    read -r -a common <<<"$(digester_common)"
    status=0
    for module in "${MODULES[@]}"; do
      report="$work/$module.txt"
      xcrun swift-api-digester -diagnose-sdk -module "$module" "${include[@]}" "${common[@]}" \
        -baseline-path "$BASELINES/$base/$module.json" -o "$report" 2>"$work/$module.err" || true
      # The report is a list of empty `/* Section */` headers when nothing broke; any other line is a finding.
      if [[ -s "$report" ]] && grep -qvE '^[[:space:]]*$|^/\*.*\*/[[:space:]]*$' "$report"; then
        echo "api-baseline: $module breaks the $base baseline:" >&2
        cat "$report" >&2
        status=1
      else
        echo "api-baseline: $module is compatible with the $base baseline"
      fi
    done
    exit $status
    ;;
  *)
    die "usage: api-baseline.sh dump|check"
    ;;
esac
