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

   `plugin new` writes an extension plugin, the only kind Work42 installs. `assets/plugin-template/` is a legacy in-process example kept for its widget code; Work42 refuses to install it as it is, so use it to read widget code and start new plugins with `plugin new`.

3. Add only the contribution folders needed. Keep cross-references self-contained: a plugin session type may refer only to workflows, skills, MCPs, and intents in the same bundle. Two things cross the bundle boundary on purpose: a session type's `widgets` list may name another plugin's widgets, and then the manifest must say `requires: [that-plugin]`. If the plugin needs a command-line tool or configuration, its skill says so in a `## Prerequisites` section (see `references/contributions.md`).

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
   # a plugin kept in a subfolder of a larger (tool) repository:
   work42 plugin install https://github.com/OWNER/TOOL.git --path work42-plugin
   ```

   A built package also installs from an https link: `work42 plugin install https://example.com/my-plugin-1.0.0.zip` (Settings → Plugins → Install from URL). Only extension plugins (`runtime: extension`) install; a `runtime: inprocess` plugin is refused from every source, and one already installed keeps loading with a "Deprecated runtime" badge. A first-party id from a link must be signed by Work42's team and notarized. `work42 plugin deactivate <name>` stops an extension plugin without removing it and `work42 plugin activate <name>` starts it again.

   Install fails, naming the plugin, when anything listed in `requires` is not installed yet; install that first. Nothing is installed automatically, and Work42 itself ships with no plugins. A new plugin's widgets are in the catalog but on no session type's widget list until the plugin's own session types (or the user, in Session Lab) name them.

   Installing the same plugin identity replaces its package-owned definitions. Work42 preserves existing sessions, storage, artifacts, transcripts, recordings, and files.

7. Inspect update state and apply updates explicitly:

   ```bash
   work42 plugin list --outdated
   work42 plugin update my-plugin
   ```

   Never enable automatic plugin updates. To move a pinned tag or commit, run `plugin install` again with the new `--ref`.

8. Before removal, tell the user what will happen: the plugin is deregistered first, then deleted. Its sessions become plain chat sessions (keeping transcript, artifacts, storage and their own layout minus the plugin's widgets); its widgets leave every session; its session types, workflows, widgets and skills are deleted. Removal is refused while another installed plugin `requires` it.

   ```bash
   work42 plugin remove my-plugin
   ```

9. If the plugin needs a CLI or configuration, give it a `my-plugin-setup` skill with the exact install steps, and end every other skill's `## Prerequisites` with "if that fails, follow the `my-plugin-setup` skill". The agent runs it when something is missing; there is no Set up button.

## Browser-based widgets

A widget that shows web pages in tabs (SDK 3.1.0 and later) uses two things and nothing else: a declaration of its surface, and `services.browser` for its tabs. `assets/plugin-template/widgets/example-browser/` is a complete example; copy it.

```swift
final class MyBrowserWidget: Work42BrowserBacked {
    // ... id, title, icon, linkIntents ...
    var browserSurface: BrowserSurfaceDeclaration? {
        BrowserSurfaceDeclaration(spec: BrowserSurfaceSpec(url: url, dataStoreKey: "my-plugin", title: "My page"), cacheKey: id)
    }
    func makeView(services: SessionServices) -> AnyView {
        AnyView(BrowserSurface(spec: browserSurface!.spec, cacheKey: id, services: services))
    }
}

try await services.browser.setTabs([BrowserTab(url: url, title: "Page")])   // show these tabs
try await services.browser.selectTab(tab.id)                                // bring one to the front
for await event in services.browser.events { /* .newTabRequested (+), .tabClosed(id) (x) */ }
```

`services.browser` is already scoped to this widget in this session; it takes no widget id, and a widget cannot reach another widget's tabs. Switch over `BrowserEvent` with `@unknown default`, because a later 3.x release may add events. The plugin's `sdk_version` must be 3.1.0 or newer if it calls `services.browser` (`work42 plugin build` stamps it).

**Do not use `configure:` or `BrowserWidgetModel`** (and not `BrowserSurface.model(forKey:)`): they are deprecated and compile with a warning that names the replacement call.

## Guardrails

- Keep `manifest_version: 2` and semantic plugin and SDK versions. There is no `sdk_abi`; do not write one.
- Do not copy private Work42 app types into a plugin. Import `Work42PluginKit` and supported `Work42UI` APIs only.
- Write new plugins with `runtime: extension` (the default of `work42 plugin new`); Work42 no longer installs in-process plugins. An extension runs in its own sandboxed process and reaches only what `plugin.yaml` declares (`file_access`, `app_groups`, `permissions`). Privacy permissions are held by Work42, which asks macOS the first time the plugin needs one; handle `PluginPermissionError`.
- Treat an in-process (legacy) plugin's native code as full local access. Do not claim granular sandbox permissions for it.
- Do not change plugin identity accidentally when customizing a fork. Same identity means replacement; a new identity installs separately.
- Do not delete user/session storage during update or removal.
- Do not retain or promise rollback packages; replacement is transactional, but only the active version remains after success.
