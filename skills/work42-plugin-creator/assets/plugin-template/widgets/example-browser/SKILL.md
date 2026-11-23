---
name: widget-example-browser
description: Use the example browser widget contributed by example-plugin when that widget is open in the current Work42 session.
---

# Example browser widget

A browser-based widget: a page in a tab bar. Keep this guidance synchronized with the widget's behavior.

It shows https://example.com and answers the tab bar's "+" with an empty tab. A widget like this declares its surface once
(`BrowserSurfaceDeclaration(spec:cacheKey:)`) and drives its tabs with `services.browser`; it never touches
`BrowserWidgetModel`.
