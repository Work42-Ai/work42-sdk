# Supported public API

Work42 SDK compatibility covers the plugin-facing contracts in
`Work42PluginKit` and the reusable visual language in `Work42UI`.

## Work42PluginKit

Supported contracts include:

- `Work42Widget`, `Work42WidgetPill`, and `Work42WidgetBackground`
- `SessionServices` and its storage, artifact, command, and activity services
- widget intents, link intents, header labels, and browser-surface hooks
- `PluginEntryPoint`, `Work42SessionHooks`, and the exported entry-point ABI
- `WidgetSDK` and `Work42SDKCompatibility`

## Work42UI

Supported UI includes design tokens, theme values, cards, toolbars, loading
states, widget chrome, browser chrome, annotation controls, Markdown views, and
the `WebSection` surface used by plugin widgets.

### Loader42 playback (2.5.0)

`Loader42(style:playback:)` takes `Loader42.Playback`: `.loop` (the default, as before) or
`.manual(progress:)`. Manual playback shows only the paint lap, frozen at `progress` (0 to 1, clamped); it never
erases and never loops, and updating `progress` just moves the frozen clock, so it is cheap to set every frame.
`Loader42.fourCompleteProgress` is the progress at which the 4 is fully painted and the 2 has not started.
`Loader42View.playback` is the AppKit equivalent. Reduced motion shows the fully painted mark in both modes.

App-shell coordination types, Work42 database models, Settings screens,
session navigation, capture/recording services, and process-management types
are intentionally absent from the SDK contract. A public declaration used by
the host to implement one of the supported components is not independently a
compatibility promise unless it is documented above.

Semantic SDK releases may add supported declarations without changing the ABI
generation. Removing or changing an existing binary contract requires a new
ABI generation.
