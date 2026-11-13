# Supported public API

Work42 SDK compatibility covers the plugin-facing contracts in
`Work42PluginKit` and the reusable visual language in `Work42UI`.

## Work42PluginKit

Supported contracts include:

- `Work42Widget`, `Work42WidgetPill`, and `Work42WidgetBackground`
- `SessionServices` and its storage, artifact, command, activity, and tool services
  (`WidgetToolService` calls every Work42 tool in-process; plugin calls are not stage-gated and `session`
  targets another session)
- widget intents, link intents, header labels, and browser-surface hooks
- `PluginEntryPoint`, `Work42SessionHooks`, and the exported entry-point ABI
- `WidgetSDK` and `Work42SDKCompatibility`
- collaboration (2.14.0): `WidgetCollaboration`, `WidgetScopeSpec`, `WidgetAudience`,
  the intent access fields (`requiring`, `forAudience`, `allowingAgents`, `perViewer`),
  `SessionServices.actor` and `collaboration` (`WidgetCollaborator`,
  `WidgetCollaborationService`, `WidgetAnchor`, `WidgetCursorReport`), per-person
  storage, `InstanceKey`, `hostCollaboration`, and `FollowSummary` /
  `Work42Widget.followSummary(services:)`

## Work42UI

Supported UI includes design tokens, theme values, cards, toolbars, loading
states, widget chrome, browser chrome, annotation controls, Markdown views, and
the `WebSection` surface used by plugin widgets.

From 2.14.0 it also includes the collaboration visuals and ids: `WidgetInstanceID`,
`PersonDart` / `PersonDartView`, `FollowModeView` / `FollowModeHeaderModel`, the
shared selections (`SharedSelectionHub`, `SharedSelectionPlace`,
`SharedSelectionTextSurface`, `SharedSelectionTextHost`, `SharedSelectionWebSurface`,
`SharedPageSelections`, `SharedSelectionText`), and `PendingComment.instance` /
`widget` with `PendingCommentsStore.instanceOwner`.

See `Collaboration.md` for how a widget uses them.

App-shell coordination types, Work42 database models, Settings screens,
session navigation, capture/recording services, and process-management types
are intentionally absent from the SDK contract. A public declaration used by
the host to implement one of the supported components is not independently a
compatibility promise unless it is documented above.

Semantic SDK releases may add supported declarations without changing the ABI
generation. Removing or changing an existing binary contract requires a new
ABI generation.
