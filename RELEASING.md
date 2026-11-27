# Releasing the SDK

The SDK is versioned by semantic version, and a plugin runs on a host of the same major version whose minor.patch is at least the
plugin's (`Work42SDKCompatibility.accepts`). Three things keep that promise, and a release does each of them once.

## 1. Bump the version

Set `Work42SDKCompatibility.version` and the app's `SDK_VERSION` to the new release. Update `CHANGELOG.md`. A removed or
changed public declaration is a major version.

## 2. Freeze the public API

```bash
scripts/api-baseline.sh dump
git add api-baselines/<version> && git commit
```

`api-baselines/<version>/` holds `swift-api-digester`'s dump of `Work42UI` and `Work42PluginKit`. It is written once and never
regenerated. `scripts/api-baseline.sh check` diagnoses the working tree against the newest baseline of the same major version
and fails on any removed or changed public declaration; additions pass. The app's `scripts/release.sh` runs it.

## 3. Freeze the compat fixture

Build the Work42 app from this checkout first (the fixture is built against the SDK frameworks embedded in it), then:

```bash
scripts/freeze-compat-fixture.sh /path/to/Work42.app
git add Fixtures/compat/<version> && git commit
```

`Fixtures/compat/<version>/` holds the fixture plugin (a widget, an intent, a background agent and a session hook) as this
release built and signed it. It is never rebuilt. `Work42CompatibilityLoadTests` in the app loads every frozen directory of the
host's major version through the real loaders, renders the view, runs the intent, the agent and the hook, and fails if any of
them stops working. `scripts/release.sh` runs it before it builds the release, so a host change that strands plugins built by
an earlier 3.x SDK never ships.

Freeze a release of a new major version the same way; the older major's directories stay, and the host skips them because it
does not accept them.

## Installer rejection fixtures

Run `scripts/make-bad-artifacts.sh <good-artifact.zip> <out-dir>` on macOS to
create bad-hash, unsigned, wrong-team, and SDK 4 fixtures. The output directory
must not already contain these filenames. Standard output is four JSON lines
with emulator catalog fields; diagnostics go to stderr. Use these only in the
Firestore emulator, never the published catalog.

Set `WORK42_ALT_SIGN_IDENTITY` to choose another team's local identity; otherwise
the script discovers one or creates and deletes a temporary self-signed identity.
The latter may require macOS authorization for temporary code-signing trust;
that certificate's trust entry and keychain are removed at exit.
The SDK 4 fixture uses the original signing identity when available, otherwise
ad-hoc signing. Re-signing invalidates notarization, so Gatekeeper (or signature
validation after the ad-hoc fallback) can reject it before the SDK check.
The catalog SDK values are fixed at 3.2.0 and 4.0.0 for this QA scenario.
