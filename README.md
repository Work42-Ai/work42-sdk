# Work42 SDK

The public SDK for native Work42 plugins.

- `Work42PluginKit` provides plugin entry points, session services, widgets,
  background work, intents, and lifecycle hooks.
- `Work42UI` provides the supported Work42 visual components and design tokens.

The repository intentionally contains two Swift package roots:

- `Work42UI/Package.swift`
- `Work42PluginKit/Package.swift`

Both products are dynamic frameworks. Keeping them in separate packages makes
`Work42PluginKit` dynamically link `Work42UI`; a single Swift package would
statically copy Work42UI into PluginKit and create duplicate Swift runtime
metadata. Plugins must link the copies embedded in the installed Work42 app;
do not statically embed either module in a plugin.

## Compatibility

SDK releases use semantic versions. Binary compatibility is tracked separately
by `Work42SDKCompatibility.abiGeneration`. Release `1.1.0` uses ABI generation
`11`.

## Development

```sh
swift build --package-path Work42UI
swift test --package-path Work42PluginKit
```

Work42 consumes both packages from one path-pinned checkout. App developers can
select the checkout explicitly:

```sh
WORK42_SDK_PATH=/path/to/work42-sdk swift build --package-path app
```

See [Authoring plugins](Documentation/AuthoringPlugins.md), the
[supported public API](Documentation/PublicAPI.md), and the templates in
`Templates/Plugin`.
