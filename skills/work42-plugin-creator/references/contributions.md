# Contribution authoring

Load only the sections needed for the plugin being changed.

## Widgets

Place Swift sources in `widgets/<slug>/Sources/` and import `SwiftUI` plus `Work42PluginKit`. Implement `Work42Widget`, return the view from `makeView(services:)`, and export both ABI entry points:

```swift
@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated { result = WidgetEntryPoint.register(MyWidget()) }
    return result
}
```

Use the installed app SDK via `work42 plugin build`, not app-internal modules or copied framework binaries.

## Skills

Each `skills/<slug>/SKILL.md` needs valid skill frontmatter and agent-facing instructions. Scope it from a session type using `session_skills`; use manifest `global_skills` only when it truly applies to every session.

### Prerequisites

A skill for something that needs an external tool or configuration starts, right after its title, with a `## Prerequisites` section. It is how a plugin gets set up: the skill is composed into every session that uses the plugin, so the agent checks it before using the tool. When the install is more than one command, put it in a separate `<plugin>-setup` skill and have the last Prerequisites step say "if that fails, follow the `<plugin>-setup` skill". Write exact, checkable steps:

```markdown
## Prerequisites

1. `command -v mytool` must print a path. If it prints nothing: `brew install owner/tap/mytool`.
2. `mytool whoami` must show a user. If not, ask the user to run `mytool login` themselves (it is interactive).
3. `~/.config/my-plugin/config.json` must exist; if it does not, ask the user for the values, never guess.
```

Install a tool into `~/.work42/bin` when it is not on a package manager: that directory is on `PATH` for agent sessions and widget commands. A widget's own `SKILL.md` composes into any session that has the widget, so give it a short version of the same section.

## Workflows

Each `workflows/<slug>.json` declares a slug, name, description, ordered stages, transitions, and optional stage rules. Minimal shape:

```json
{
  "slug": "my-flow",
  "name": "My Flow",
  "description": "",
  "stages": [
    {"name":"Open","ordinal":0,"is_initial":true,"is_terminal":true,"entry_prompt":null,"entry_gate":null,"icon":null,"color_light":null,"color_dark":null,"model":null,"provider":null}
  ],
  "transitions": [],
  "stage_rules": []
}
```

Stage-rule kinds are `execute`, `edit`, `fetch`, or `mcp`; actions are `allow` or `block`.

## Session types

Each `session-types/<id>.json` declares `id`, display `name`, and a same-bundle `workflow`. Optional arrays `session_skills` and `session_mcps` must name same-bundle folders. `create_intent`, when present, must name a same-bundle intent. Other supported fields are `layout_json`, `icon`, `accent_hex`, `fresh_per_session`, `shows_in_new_session_menu`, `sort_order`, `enforce_capability_gate`, `self_archives`, `list_shape`, `archive_source`, `shows_in_session_list`, and typed `args`.

`widgets` is the explicit list of widget kind ids sessions of this type have: built-in kinds as plain ids (`chat`, `files`, `terminal`) and plugin widgets as `widget:<slug>`. Only these exist in its sessions (the `+ Widget` picker, background work, link handling, the widgets' skills); installing a plugin adds its widgets to the catalog but to no type's list. A `widget:` entry must be one of this plugin's widgets or one of a plugin named in `requires`, or install fails. When `widgets` is absent, the ids found in `layout_json` are used. Keep it in step with the layout.

Removing the plugin deregisters it first: its sessions become plain chat sessions that keep their transcript, artifacts, storage and layout minus the plugin's widgets, and only then are the type and its workflows deleted.

## Intents

Each `intents/<id>.json` declares `id`, `title`, a same-bundle `type_id`, optional parameter names, and optional action-button visibility:

```json
{"id":"new-my-session","title":"New My Session","type_id":"my-session","params":[],"button":true}
```

## Hooks and MCPs

Use `Sources/Plugin.swift` only for compiled session hooks defined by `Work42PluginKit`. Put MCP-owned declarations beneath `mcp/<id>/` and reference their IDs only from session types in the same plugin. Both are package-owned and disappear on removal; external/user data they wrote is not traversed or deleted.
