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
