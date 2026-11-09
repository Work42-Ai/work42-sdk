// ViewerContext.swift — whose page a widget's button is worked out from (WOR-680).
//
// A browser widget's action-area buttons (Start Linear Session, a PR's actions) decide whether they are enabled, and what they act
// on, from the page the widget shows. With a session shared by several devices, each one has its own page in front, so the Mac works
// the buttons out once per device and runs one with that device's page. It does that by setting `frontURL` around the evaluation
// or the run: a plugin reads `BrowserWidgetModel.currentAddress`, which is the viewer's page when one is set and the Mac's own
// address otherwise, so a widget needs nothing else to answer for the right person.

import Foundation

public enum ViewerContext {
    /// The address of the page the person asking has in front, or nil to mean this Mac's own.
    @TaskLocal public static var frontURL: String?
}

public extension BrowserWidgetModel {
    /// The address a button reads: the viewer's page when the Mac is working a button out for a device, else the page this Mac shows.
    var currentAddress: String { ViewerContext.frontURL ?? urlDraft }
}
