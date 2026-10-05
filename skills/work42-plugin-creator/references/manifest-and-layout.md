# Manifest and layout

Every plugin is an ordinary folder or Git repository with `plugin.yaml` at its root. Start with `work42 plugin new`; newly written manifests always use schema v2.

```yaml
manifest_version: 2
name: my-plugin
version: 0.1.0
description: Explain what this plugin contributes
author: Your Name
sdk_version: 1.0.0
sdk_abi: 11
global_skills: optional-global-skill
```

- `name`: lowercase slug, using letters, digits, and hyphens.
- `version`: semantic plugin version (`major.minor.patch`).
- `sdk_version`: semantic Work42 SDK release used to author the plugin. It must not be newer than the installed app SDK.
- `sdk_abi`: exact native ABI generation. It must equal the app ABI.
- `global_skills`: optional comma-separated skill slugs composed globally. Most skills should instead be scoped from a session type.

Legacy manifests without `manifest_version` remain readable, but do not create them. In legacy manifests, integer `version` becomes `N.0.0` and integer `sdk_version` is interpreted as the ABI.

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
├── session-types/<id>.json
├── mcp/<id>/                     # MCP declaration/configuration owned by plugin
└── intents/<id>.json
```

All contribution folders are optional. Work42 discovers them by convention; do not add redundant contribution lists to `plugin.yaml`.

Run `work42 plugin inspect . --json` after every manifest or contribution-layout change. It validates schemas and cross-references without installing anything.
