// SharedSelectionWebSurface.swift — a web view's part in sharing highlights (WOR-773 §6).
//
// The web sibling of `SharedSelectionTextSurface`: a page (an artifact, a Markdown preview, a plugin's page) reports the person's
// highlight to `SharedSelectionHub` and draws the others' that are in it, through the page script (`SharedPageSelections`). The page
// is read on a short beat rather than trusted to report, so a deselect is mirrored even when no event says so.

import Foundation
import WebKit

@MainActor
public final class SharedSelectionWebSurface {
    /// How often the page's highlight is read.
    public static let pollInterval: Duration = .milliseconds(150)

    private let hub: SharedSelectionHub
    private var page: SharedPageSelections?
    private var loop: Task<Void, Never>?
    private var reported: PageSelectionReport?
    /// Where the page is: nothing is shared without one.
    public var place: SharedSelectionPlace? {
        didSet {
            guard place != oldValue else { return }
            if place == nil {
                reported = nil
                hub.report(nil, from: self)
            }
            redraw()
        }
    }

    public init(webView: WKWebView, place: SharedSelectionPlace?, hub: SharedSelectionHub = .shared) {
        self.hub = hub
        self.place = place
        page = SharedPageSelections(webView: webView) { [weak self] report in self?.local(report) }
        hub.observe(self) { [weak self] in self?.redraw() }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
        redraw()
    }

    private func tick() async {
        guard place != nil, let now = await page?.currentSelection() else { return }
        switch now {
        case .selected(let report): local(report)
        case .nothing: local(nil)
        case .unknown: break
        }
    }

    private func local(_ report: PageSelectionReport?) {
        guard report != reported else { return }
        reported = report
        guard let place, let report else {
            hub.report(nil, from: self)
            return
        }
        hub.report(SharedSelectionLocal(place: place, start: report.start, end: report.end, backward: report.backward ?? false), from: self)
    }

    private func redraw() {
        let others = place.map { hub.remote(in: $0).map(\.page) } ?? []
        Task { @MainActor [weak self] in await self?.page?.show(others) }
    }

    /// The page went away: its highlight goes for everyone, and nothing more is drawn.
    public func detach() {
        loop?.cancel()
        loop = nil
        hub.report(nil, from: self)
        hub.stopObserving(self)
        page?.detach()
        page = nil
    }
}
