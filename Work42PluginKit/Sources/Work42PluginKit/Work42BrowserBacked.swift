// Work42BrowserBacked.swift - a widget whose content is a `BrowserSurface`, said so the host can read it without a view (WOR-644).
//
// A widget built on `BrowserSurface` keeps its tabs in a model that only exists once the surface is on screen. A device that opens
// such a tab, one the Mac never showed, therefore got nothing: the model was not there to read. A widget that conforms to
// `Work42BrowserBacked` declares its surface, and the host builds the model from the declaration while a device watches the
// session (`BrowserSurface.resolveHeadless`), drawing nothing on the Mac:
//
// ```swift
// final class MyWidget: Work42BrowserBacked {
//     var browserSurface: BrowserSurfaceDeclaration? {
//         BrowserSurfaceDeclaration(spec: spec, cacheKey: id, configure: { model in self.wire(model) })
//     }
//     func makeView(services: SessionServices) -> AnyView { AnyView(BrowserSurface(browserSurface!)) }
// }
// ```
//
// The protocol is discovered by cast, like `Work42WidgetPill` and `Work42WidgetBackground`: a widget that does not conform loads and
// behaves exactly as before, so the ABI generation does not change.

import Foundation

public protocol Work42BrowserBacked: Work42Widget {

    /// The widget's surface, or nil when it has none right now (it shows something else, or has not got what it needs yet). The
    /// widget's view and the host's headless resolve are both made from this.
    var browserSurface: BrowserSurfaceDeclaration? { get }
}
