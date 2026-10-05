# Troubleshooting

## Manifest rejected

Run `work42 plugin inspect <path> --json`. Confirm schema v2, semantic `version` and `sdk_version`, exact `sdk_abi`, a slug-form `name`, and same-bundle references.

## SDK not found

Install Work42 in `/Applications`, set `WORK42_APP_PATH`, or pass:

```bash
work42 plugin build . --app /path/to/Work42.app
```

The app must contain `Work42UI.framework`, `Work42PluginKit.framework`, their Swift modules, and `Contents/Resources/WidgetSDK-Headers`.

## ABI or SDK mismatch

Use `work42 sdk` to inspect the host. A newer semantic SDK requires updating Work42 or rebuilding against the installed version. A different ABI always requires rebuilding native contributions.

## Build or signing failure

Install Xcode/Swift toolchains, confirm `xcrun --sdk macosx --show-sdk-path`, then retry `work42 plugin build`. Inspect available identities with `security find-identity -v -p codesigning`; personal installs may use ad-hoc signing.

## Update missing

`list --outdated` compares branch installs with remote HEAD and local installs with source content. Tags and commits are deliberately pinned. A moved/missing local path reports unavailable and never uninstalls the active plugin.

## Failed replacement

The prior active plugin should remain installed, and `.staging` should not retain a historical package. Re-run `plugin inspect` and `plugin test` against the candidate. Do not manually delete the active install to “unstick” the transaction.

## Removal expectations

Removal deletes package code and owned contributions. It preserves sessions, session/widget storage, artifacts, transcripts, recordings, files, and independent workflow forks. Reinstalling a compatible plugin may reconnect the richer experience.
