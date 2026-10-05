---
name: work42-plugin-creator
description: Create, fork, modify, build, test, install, update, troubleshoot, or publish Work42 plugins using the public Work42 SDK and the `work42 plugin` CLI. Use for plugin manifests, widgets, session types, workflows, skills, MCP declarations, intents, hooks, Git-based customization, local signing, and release packaging. Do not use a GUI customization flow or require a marketplace account.
---

# Work42 plugin creator

Build plugins as ordinary Git repositories. Use whatever Git-provider tools are already available to clone, fork, create repositories, push branches, tag releases, or publish assets. Keep Work42-specific work in the public manifest and CLI; never invent a marketplace account or a GUI “Customize a Copy” flow.

## Choose the path

- New plugin: run `work42 plugin new <slug> [--path <directory>]`.
- Existing local plugin: inspect the repository before changing its identity or contributions.
- Remote customization: fork or clone with the available provider tooling, preserve the upstream remote, then install the fork explicitly.
- Installed plugin: use `work42 plugin list --json` to recover provenance. Tags and commits are pinned; branches can report manual updates.

Read [references/manifest-and-layout.md](references/manifest-and-layout.md) before creating or changing `plugin.yaml`. Read [references/contributions.md](references/contributions.md) only for the contribution types involved. For Git/release work, read [references/git-and-releases.md](references/git-and-releases.md). For failures, read [references/troubleshooting.md](references/troubleshooting.md).

## Authoring workflow

1. Confirm the installed tools and compatibility contract:

   ```bash
   work42 sdk
   work42 plugin --help
   ```

2. Create or acquire the repository. For a new plugin:

   ```bash
   work42 plugin new my-plugin --path ./my-plugin
   cd ./my-plugin
   git init
   ```

   To start from the bundled example instead, copy `assets/plugin-template/` and replace every `example-plugin` identifier.

3. Add only the contribution folders needed. Keep cross-references self-contained: a plugin session type may refer only to workflows, skills, MCPs, and intents in the same bundle.

4. Validate before building:

   ```bash
   work42 plugin inspect . --json
   ```

5. Build and test against the SDK embedded in the installed Work42 app:

   ```bash
   work42 plugin build .
   work42 plugin test .
   ```

   If Work42 is not in its standard application location, pass `--app /path/to/Work42.app`. Local native code uses the first usable Apple Development or Developer ID identity and otherwise falls back to ad-hoc signing.

6. Install only after validation succeeds:

   ```bash
   work42 plugin install .
   # or
   work42 plugin install https://github.com/OWNER/REPOSITORY.git --ref main
   ```

   Installing the same plugin identity replaces its package-owned definitions. Work42 preserves existing sessions, storage, artifacts, transcripts, recordings, and files.

7. Inspect update state and apply updates explicitly:

   ```bash
   work42 plugin list --outdated
   work42 plugin update my-plugin
   ```

   Never enable automatic plugin updates. To move a pinned tag or commit, run `plugin install` again with the new `--ref`.

8. Before removal, tell the user that package contributions disappear while previously written content remains:

   ```bash
   work42 plugin remove my-plugin
   ```

## Guardrails

- Keep `manifest_version: 2`, semantic plugin/SDK versions, and the exact integer SDK ABI.
- Do not copy private Work42 app types into a plugin. Import `Work42PluginKit` and supported `Work42UI` APIs only.
- Treat native plugin code as full local access. Do not claim granular sandbox permissions.
- Do not change plugin identity accidentally when customizing a fork. Same identity means replacement; a new identity installs separately.
- Do not delete user/session storage during update or removal.
- Do not retain or promise rollback packages; replacement is transactional, but only the active version remains after success.
