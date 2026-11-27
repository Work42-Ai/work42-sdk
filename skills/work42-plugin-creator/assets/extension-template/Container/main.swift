// The container app of a Work42 plugin extension. It only carries the extension inside Contents/Extensions; Work42
// discovers and runs the extension itself. Opened by hand, it says so and quits.
import AppKit

let alert = NSAlert()
alert.messageText = "This app holds a Work42 plugin."
alert.informativeText = "Work42 runs it. Turn it on in Work42 → Settings → Plugins."
alert.runModal()
