#!/bin/bash
# freeze-compat-fixture.sh <app> — freeze the compat fixture plugin for the current SDK version (WOR-856).
#
# Builds Fixtures/compat/Sources against the SDK frameworks embedded in <app> (a Work42.app built from this SDK, the
# same inputs `work42 plugin build` uses on a user's Mac) and commits the signed dylibs and manifests to
# Fixtures/compat/<version>/. Run it once per 3.x release, right after the version bump and the app build, and commit the
# result. A frozen directory is never rebuilt: Work42CompatibilityLoadTests loads every one of them with the current host.
#
#   scripts/freeze-compat-fixture.sh /path/to/Work42.app

set -euo pipefail

SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$SDK_ROOT/Fixtures/compat"
VERSION_FILE="$SDK_ROOT/Work42UI/Sources/Work42UI/Work42SDKCompatibility.swift"

die() { echo "freeze-compat-fixture: $*" >&2; exit 1; }

APP="${1:-}"
[[ -n "$APP" && -d "$APP/Contents/Frameworks" ]] || die "usage: freeze-compat-fixture.sh <path to Work42.app>"
FRAMEWORKS="$APP/Contents/Frameworks"
for framework in Work42UI Work42PluginKit; do
  [[ -d "$FRAMEWORKS/$framework.framework" ]] || die "$FRAMEWORKS/$framework.framework is missing"
done

version="$(sed -n 's/.*static let version = "\([0-9][0-9.]*[^"]*\)".*/\1/p' "$VERSION_FILE" | head -1)"
[[ -n "$version" ]] || die "cannot read the SDK version from $VERSION_FILE"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "freeze a release version, not '$version'"

# The app must have been built from this SDK, or the fixture would be frozen against some other release.
app_sdk="$("$APP/Contents/MacOS/work42" sdk --version-only 2>/dev/null || true)"
[[ "$app_sdk" == "$version" ]] || die "the app hosts SDK '${app_sdk:-unknown}', this checkout is $version; build the app from this checkout first"

OUT="$FIXTURE/$version"
[[ -e "$OUT" ]] && die "$OUT already exists; a frozen fixture is never rebuilt"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CACHE="$(mktemp -d)"
trap 'rm -rf "$CACHE"' EXIT

# The flags `PluginSwiftCompiler.arguments` passes, so the fixture is built exactly as a user's plugin is.
compile() {
  local module="$1" output="$2"
  shift 2
  xcrun swiftc -emit-library -o "$output" -module-name "$module" \
    -sdk "$SDK_PATH" -target arm64-apple-macosx15.0 -swift-version 6 -disable-sandbox \
    -enable-upcoming-feature ExistentialAny -Xfrontend -default-isolation -Xfrontend MainActor \
    -F "$FRAMEWORKS" -framework Work42UI -framework Work42PluginKit \
    -module-cache-path "$CACHE" -Xlinker -rpath -Xlinker "$FRAMEWORKS" "$@"
}

sign() { codesign --force --sign "${CODESIGN_IDENTITY:--}" "$1"; }

mkdir -p "$OUT/widget" "$OUT/plugin"

widget_dylib="compat-fixture-frozen.dylib"
compile CompatFixtureWidget "$OUT/widget/$widget_dylib" "$FIXTURE"/Sources/Widget/*.swift
sign "$OUT/widget/$widget_dylib"
printf 'dylib: %s\nsdk_version: %s\n' "$widget_dylib" "$version" > "$OUT/widget/widget.yaml"

compile CompatFixturePlugin "$OUT/plugin/compat-fixture-plugin.dylib" "$FIXTURE"/Sources/Plugin/*.swift
sign "$OUT/plugin/compat-fixture-plugin.dylib"

# plugin.yaml as `plugin build` stamps it: the SDK this native code was compiled against.
cat > "$OUT/plugin.yaml" <<YAML
manifest_version: 2
name: compat-fixture
version: 1.0.0
description: Frozen SDK $version fixture for the binary compatibility tests.
author: work42
sdk_version: $version
requires: []
YAML

echo "froze $OUT"
echo "commit it: git add Fixtures/compat/$version"
