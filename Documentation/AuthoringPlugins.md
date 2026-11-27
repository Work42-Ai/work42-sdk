# Authoring Work42 plugins

A Work42 plugin is an ordinary Git repository containing a versioned manifest
and any session, workflow, widget, or skill contributions it provides. Build
native sources against `Work42PluginKit.framework` and `Work42UI.framework`
inside the installed Work42 app so the host and plugin share one runtime copy.

The current public contract is SDK `2.15.0`, ABI `16`. A plugin package must
declare both values. ABI mismatches are rejected before a Swift entry point is
called, so a plugin built for an older ABI must be rebuilt. A plugin built for
SDK `2.13.0` or `2.14.0` has the same ABI and keeps loading; only a widget that
adopts `Work42ItemWidget` (item kinds, `2.15.0`) needs a host that has them to
get item tiles.

Every widget is collaborative: a session can hold several people, on several
devices, and agents. A widget that declares nothing is shared. See
`Collaboration.md` for the three kinds of widget, scopes, who may press an
intent, per-person storage, instance ids, follow mode and shared highlights.

Use the `work42 plugin` commands to scaffold, inspect, build, test, install, and
remove plugins. The complete agent workflow is delivered by the
`work42-plugin-creator` skill in this repository.

## Distribution, dependencies and setup

Work42 ships with **no plugins** and installs none at launch. A user adds a plugin with
`work42 plugin install <git-url|path> [--ref <ref>] [--path <subdir>]` (or Settings → Plugins);
`--path` installs a plugin that lives in a folder of a larger repository, such as a command-line tool that
also ships its Work42 plugin.

- **`requires`** in `plugin.yaml` lists plugins this one depends on. Install fails, naming the missing plugin,
  until they are installed; nothing is installed automatically. `work42 plugin remove` refuses to remove a
  plugin another installed plugin requires.
- **`widgets`** in a session type lists the widget kind ids its sessions have (`chat`, `files`,
  `widget:<slug>`). Only those exist in its sessions. A `widget:` entry must belong to this plugin or to a
  plugin in `requires`. Installing a plugin never adds its widgets to any session type that does not name them.
- **A plugin ships no command-line tool.** An extension plugin reaches the Mac through Work42's services
  (`services.calendar`, `audio`, `speech`, `diskRead`, `automation`, `permissions`) and offers agents MCP tools
  written in Swift (`widget.yaml` `mcps`, or `session_mcps` on a session type; see the plugin-creator skill). On an
  iPad a widget runs its own plugin's tools on the paired Mac with `services.pluginTools`. The person is asked for
  what the plugin needs through Work42's permission pill, declared in `plugin.yaml` `permissions`.
- **`## Prerequisites`** in a skill is for configuration, not installation: exact, checkable steps the agent can
  verify; the skill is composed into every session that uses the plugin.
- **Removal** deregisters first: the plugin's sessions become plain chat sessions (transcript, artifacts,
  storage and layout kept, minus the plugin's widgets), its widgets leave every session, and only then are its
  session types, workflows, widgets and skills deleted.
