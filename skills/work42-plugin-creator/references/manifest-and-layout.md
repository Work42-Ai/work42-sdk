# Manifest and layout

Every plugin is an ordinary folder or Git repository with `plugin.yaml` at its root. Start with `work42 plugin new`; newly written manifests always use schema v2.

```yaml
manifest_version: 2
name: my-plugin
version: 0.1.0
description: Explain what this plugin contributes
author: Your Name
sdk_version: 3.1.0
global_skills: optional-global-skill
requires: [other-plugin]
```

- `name`: lowercase slug, using letters, digits, and hyphens.
- `version`: semantic plugin version (`major.minor.patch`).
- `sdk_version`: the Work42 SDK release the plugin is built with (`work42 sdk` prints the installed one, and `work42 plugin new` writes it). `work42 plugin build` stamps the built copy with the exact version, so never edit it in a built plugin. The app runs a plugin whose major version matches its own and whose version is the same or older: a plugin built with 3.0.0 runs on 3.2.0, but one built with 3.2.0 does not run on 3.0.0.
- There is no `sdk_abi` field. An older manifest that still has one is read, the field is ignored with a warning, and you should delete it.
- `global_skills`: optional comma-separated skill slugs composed globally. Most skills should instead be scoped from a session type.

- `requires`: optional list of plugin names this plugin depends on (`[a, b]`, `a, b`, or a block list). Install fails until each is installed, nothing is installed automatically, and `work42 plugin remove` refuses to remove a plugin another installed plugin requires. Declare it whenever a session type's `widgets` list names another plugin's widgets.

Legacy manifests without `manifest_version` remain readable, but do not create them. In legacy manifests, integer `version` becomes `N.0.0` and integer `sdk_version` is the old ABI generation, so the plugin counts as built for SDK 2.x and its native code must be rebuilt.

## Folder contract

```text
my-plugin/
├── plugin.yaml
├── Sources/Plugin.swift          # optional compiled session hooks
├── widgets/<slug>/
│   ├── Sources/*.swift           # source build, or a compatible prebuilt dylib
│   └── SKILL.md                  # optional widget-facing agent guidance
├── skills/<slug>/SKILL.md
├── workflows/<slug>.json
├── session-types/<id>.json       # incl. the `widgets` its sessions have
├── mcp/<id>/                     # MCP declaration/configuration owned by plugin
└── intents/<id>.json
```

All contribution folders are optional. Work42 discovers them by convention; do not add redundant contribution lists to `plugin.yaml`.

Run `work42 plugin inspect . --json` after every manifest or contribution-layout change. It validates schemas and cross-references without installing anything.
