# Collaboration (SDK 2.14.0, ABI 16)

A Work42 session can have several people in it, each on one or more devices
(a Mac, an iPad), and several agents. A widget is the same widget for all of
them. Collaboration is part of the SDK: a widget that declares nothing is a
**shared** widget with one state, last write wins, no cursors, one scope
(`use`), and intents that every person in the session may press and agents may
not. Plugins built for ABI 15 or older must be rebuilt; no source changes are
needed, because every addition has a default.

## The three kinds of widget

`Work42Widget.collaboration` says which kind a widget is:

| Kind | What it is | Examples |
|------|------------|----------|
| `.shared(conflict:cursors:)` | One state for the whole session. `conflict` is `.lastWriteWins` or `.rejectStale`; `cursors` is `.none`, `.pointer`, `.text` or `.page`. | a file, a plan, a board |
| `.personal(agentControl:)` | One instance per person per device, with its own tabs and sign-ins. Others see it only by following that device. `agentControl` is `.never` or `.withPermission`. | the Browser, a plugin built on `BrowserSurface` |
| `.hosted(input:)` | It runs on the session owner's Mac; others see its live picture and, with `.withPermission`, send it input. | a simulator |

`Work42Widget.hostCollaboration` is what the host actually treats the widget
as: what it declares, except that a browser-backed widget that declares
nothing is personal (`.personal(agentControl: .withPermission)`).
`WidgetCollaboration.isPersonal` answers whether each person has their own.

## Instances and their ids

`InstanceKey` names one instance: a session, a widget and, for a personal
widget, a device. Its `cacheKey` is what the SDK's caches use, so two
instances never share tabs, history, scroll or page state. Only the website
data store underneath (cookies and logins, named by `dataStoreKey`) may be
shared between instances.

`WidgetInstanceID` makes the one id agents and people use for an instance.
Every tool, comment and pointer uses it, so an id a comment carries is
always one the `widget_*` and `device_*` tools take:

- `w_<kind>` for a shared or hosted widget (`w_files`, `w_iosSimulator`).
- `w_<kind>_<person>_<device>` for one device's instance of a personal widget
  (`w_browser_yan-rodriguez_mac`, `w_widget_github_yan-rodriguez_ipad`). The id
  does not change while the session lasts, whoever else joins. The device
  part always appears, so the same person's Mac and iPad have different ids.

`WidgetInstanceID.runtimeID(kindID:owner:)` builds it, `names(_:instanceOf:)`
tells whether an id is the widget or one of its instances, and `slug(_:)` turns
a name into an id part. `InstanceKey.runtimeID(owner:)` is the same id for a
key.

## Scopes

`Work42Widget.scopes` lists what a collaborator can be allowed to do in the
widget (`WidgetScopeSpec(id:title:)`; for a browser: `view`, `navigate`, `act`).
The default is one `use` scope. An owner holds every scope; a member holds `use`
until the owner grants more. A device's own scopes can only narrow what its
person holds.

## Who may press an intent

```swift
WidgetIntentSpec(name: "approvePlan", title: "Approve Plan", icon: "checkmark.seal.fill", isEnabled: nil, isConfirmed: nil,
                 performWithServices: { services in /* services.actor is whoever pressed */ })
    .forAudience(WidgetAudience([.owners, .role("reviewer")]))   // .owners, .members, .role("x"), .primaryDeviceOnly
    .requiring("approve")                                        // a scope from `scopes`
    .allowingAgents()                                            // agents cannot press an intent unless it says so
    .perViewer(title: { who in … }, isEnabled: { who in … }, isConfirmed: { who in … })
```

One check runs for every press, whether it comes from the palette, a button on
this device, another person's device, `services.intents.execute` or an agent:
membership, the device's scopes, the audience, the scope the intent requires,
and for an agent the intent's `allowingAgents()` and the workflow stage. A
refusal comes with a code and a sentence. `permits(_:)`, `title(for:)`,
`isEnabled(for:)` and `isConfirmed(for:)` read the same rules, so a button
reads differently for each person.

## Who is acting, and who is here

`services.actor` is the `WidgetCollaborator` that pressed: `id` (the person's
account, the same on every device of theirs, or `agent:…`), `displayName`,
`kind` (`.person`, `.agent`), `role` (`.owner`, `.member`), `workflowRoles`,
`isPrimaryDevice` and `colorKey`.

`services.collaboration` (`WidgetCollaborationService`) gives:

- `members()`: everyone in the session, one entry per person.
- `cursors()`: the others' cursors in this widget, as `WidgetCursor`s.
- `report(_:)`: this person's own cursor (`WidgetCursorReport`), or nil when
  they leave the widget.

Positions are `WidgetAnchor`s: `.point(x:y:)`, `.text(path:version:line:column:)`
and `.page(quote:prefix:suffix:elementPath:)`. The cursors stream is lossy on
purpose: at most 20 reports a second, forgotten 5 seconds after the last, never
replayed.

## Per-person storage

`services.storage.person(key:)`, `setPerson(key:value:)` and
`deletePerson(key:)` keep a value for the acting person only; `people(key:)`
reads everyone's. A workflow gate can count these rows ("two reviewers
approved").

## Follow mode

A device can follow another device of the session (its person approves it,
for the whole session). While it follows, the followed device's personal
widgets show on it read-only: their live picture with the darts over it,
under a fixed header drawn by `FollowModeView` from a `FollowModeHeaderModel`
("Following <name> · <device>", their tabs with the one in front marked, and
"<agent> is acting" while an agent acts there). The host draws all of it; a
widget only says what its tabs are, through
`Work42Widget.followSummary(services:)` returning a `FollowSummary(tabs:selected:)`
(the default is `.none`).

## Pointers and shared highlights

Every person's pointer and the end of their highlight is drawn with
`PersonDart` (`PersonDartView` in SwiftUI): the filled dart in their colour with
their name, and typing dots while they write or dictate a comment. Agents and
QA recordings use the same dart.

Everyone's highlight is shown to everyone in the session, in the same widget.
`SharedSelectionHub.shared` is the one place highlights go through. A surface
reports this person's highlight (`report(_:from:)`, `setActivity(_:)`) and
draws the others' (`remote(in:)`, `observe(_:_:)`); the host connects each
session to its transport (`connect`, `update`). A highlight travels as its
quote with a little text either side, so it is found again in anyone's copy at
their width and scroll (`SharedSelectionText`). Which widget a surface is in
comes from `EnvironmentValues.sharedSelectionPlace`, which the widget's tile
sets.

The library's selectable views share highlights on their own:
`SharedSelectionTextSurface` for a text (anything that conforms to
`SharedSelectionTextHost`) and `SharedSelectionWebSurface` for a page (through
`SharedPageSelections`). A widget built from them needs no code of its own.

## Agents

An agent in a session (Claude, Codex) looks the same wherever it is drawn, because who it is is defined once, in
`SupportedAgents`. `SupportedAgents.identity(for: "claude")` gives an `AgentIdentity`: its `name`, its brand `color` (avatar, chips,
glow), its `pointer` colour (the dart and its tag), its `markAsset` and whether the mark keeps its colours (`markKeepsColor`), a
fallback `symbol`, and the `markTile` it sits on when shown large. An id the SDK does not define reads as a generic "Agent" with no
mark, so a provider added later still has a name and a colour.

A widget that meets an agent as a collaborator reads `WidgetCollaborator.agent` (nil for a person) and draws it with the SDK:

```swift
if let agent = collaborator.agent {
    AgentAvatarView(agent, size: 22, acting: isActing)   // its mark in its colour, ringed while it acts
    AgentMark(agent, size: 14)                            // the mark alone
    Text(agent.name).foregroundStyle(agent.tint)
}
```

Do not write an agent's colour, name or logo into a widget: ask the catalog, so the widget follows the app when an agent is added.

## Comments name their instance

A comment made in a widget carries the instance it came from:
`PendingComment.instance` (whose instance, on what device) and
`PendingComment.widget` (the widget kind, when the source alone does not say,
such as a page highlighted in a plugin built on a browser). `widgetId` is then
the instance's `WidgetInstanceID`. The host fills these in when the comment is
added (`PendingCommentsStore.instanceOwner`, `defaultInstanceOwner`).

## Trust

Installing a plugin means trusting it: a widget runs in the app's process and
can use everything the app can. The checks above govern people and agents
pressing buttons, not what a plugin may do.
