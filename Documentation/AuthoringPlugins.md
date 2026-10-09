# Authoring Work42 plugins

A Work42 plugin is an ordinary Git repository containing a versioned manifest
and any session, workflow, widget, or skill contributions it provides. Build
native sources against `Work42PluginKit.framework` and `Work42UI.framework`
inside the installed Work42 app so the host and plugin share one runtime copy.

The current public contract is SDK `1.2.0`, ABI `11`. A plugin package must
declare both values. ABI mismatches are rejected before a Swift entry point is
called.

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
- **`## Prerequisites`** in a skill is how a plugin gets set up. A skill for something that needs a CLI or
  configuration starts with exact, checkable steps; the skill is composed into every session that uses the
  plugin, and `work42 plugin setup <name>` opens a chat that follows it. Tools a plugin installs go in
  `~/.work42/bin`, which is on `PATH` for agent sessions and widget commands.
- **Removal** deregisters first: the plugin's sessions become plain chat sessions (transcript, artifacts,
  storage and layout kept, minus the plugin's widgets), its widgets leave every session, and only then are its
  session types, workflows, widgets and skills deleted.
