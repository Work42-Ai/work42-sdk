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

Removing the plugin removes the type definition, not session records. Existing sessions resolve through Work42’s generic chat-like fallback.

## Intents

Each `intents/<id>.json` declares `id`, `title`, a same-bundle `type_id`, optional parameter names, and optional action-button visibility:

```json
{"id":"new-my-session","title":"New My Session","type_id":"my-session","params":[],"button":true}
```

## Hooks and MCPs

Use `Sources/Plugin.swift` only for compiled session hooks defined by `Work42PluginKit`. Put MCP-owned declarations beneath `mcp/<id>/` and reference their IDs only from session types in the same plugin. Both are package-owned and disappear on removal; external/user data they wrote is not traversed or deleted.
