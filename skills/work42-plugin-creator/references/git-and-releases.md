# Git, signing, and releases

## Create or fork

Use the provider tooling available in the agent environment (`gh`, another provider CLI, or ordinary `git`). Do not require a particular provider and do not direct the user to a Work42 GUI customization action.

For a fork, preserve upstream tracking:

```bash
git clone <fork-url>
cd <repository>
git remote add upstream <upstream-url>
git fetch upstream
```

Decide identity deliberately:

- Preserve `plugin.yaml` `name` to replace the installed upstream package while retaining its content/storage connection.
- Change `name` and internal contribution IDs to install an independent plugin.

## Refs and manual updates

```bash
work42 plugin install <git-url> --ref main       # branch: update checks compare remote HEAD
work42 plugin install <git-url> --ref v1.2.0     # tag: pinned
work42 plugin install <git-url> --ref <sha>      # commit: pinned
work42 plugin list --outdated                    # check only; never downloads
work42 plugin update <name>                      # explicit branch/local update
```

## Local signing

`plugin build`, `test`, and source installation compile against the installed Work42 SDK. Work42 selects an Apple Development identity first, then Developer ID Application, and falls back to ad-hoc signing for personal local use. Do not treat ad-hoc output as publishable marketplace validation.

## Release candidate

Before tagging:

1. Run `work42 plugin inspect . --json`, `build`, and `test`.
2. Update the semantic plugin version.
3. Commit clean sources and tag that exact commit.
4. Package the plugin root, including compatible prebuilt native dylibs when the release is intended for curated installation.
5. Produce SHA-256 for the asset and publish both through the repository’s release mechanism.
6. Attach `work42-plugin-release.json` containing plugin identity/version, SDK version/ABI, asset URL, SHA-256, and contribution summary.

Curated release assets must be publisher-built and validly code signed. Work42’s future public catalogue may add stronger attestation, but the MVP does not require a marketplace account.
