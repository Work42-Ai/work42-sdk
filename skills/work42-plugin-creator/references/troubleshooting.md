# Troubleshooting

## Manifest rejected

Run `work42 plugin inspect <path> --json`. Confirm schema v2, semantic `version` and `sdk_version`, exact `sdk_abi`, a slug-form `name`, and same-bundle references.

## Install fails: requires a plugin that is not installed

`error: plugin 'X' requires 'Y', which is not installed.` Install `Y` first (`work42 plugin install <source>`), then `X`. Nothing is installed for you. If `Y` lives in a subfolder of a repository, pass `--path <subdir>`.

## Install fails: a session type lists a widget nobody provides

`session type 'T' lists widget 'widget:W', which is not provided by …`. `W` must be a widget folder of this plugin or of a plugin in `requires`; fix the id or add the `requires` entry.

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

Removal deregisters the plugin, then deletes package code and owned contributions. The plugin's sessions become plain chat sessions; they keep their transcript, session/widget storage, artifacts, recordings, files and their own layout minus the plugin's widgets, and independent workflow forks are untouched. Removal is refused while another installed plugin `requires` it. Reinstalling does not turn those sessions back into the plugin's session type.
