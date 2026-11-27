# Extension template (SDK 3.2.0)

What `work42 plugin build` uses to build a plugin with `runtime: extension` in `plugin.yaml`.

A plugin keeps its extension's Swift sources in `extension/Sources/` (one `@main` type conforming to
`Work42PluginExtension`, plus its widgets; `example/` is a starting point). `plugin build` compiles them against the
`Work42Extension`, `Work42PluginKit` and `Work42UI` frameworks embedded in Work42, then assembles and signs
`extension/<Name>.app`:

```
<Name>.app/Contents/
  MacOS/<container executable>          Container/main.swift
  Info.plist                            Container/Info.plist
  Frameworks/                           the SDK frameworks, copied from Work42
  Extensions/<Name>Extension.appex/     Extension/Info.plist, Extension/Extension.entitlements
```

The placeholders (`__EXTENSION_BUNDLE_ID__`, `__POINT_ID__`, `__SDK_VERSION__`, ...) are filled from `plugin.yaml` and the
SDK. Every key in `Extension/Info.plist` is required; WOR-861's results explain why.
