// WebSectionStatus.swift — navigation status shared by the macOS and iPadOS web views.

import Foundation

// MARK: - WebSectionStatus

/// Navigation lifecycle status for an embedded web section.
///
/// Published by `WebSectionLiveView.status` and set from the `Coordinator`'s
/// `WKNavigationDelegate` callbacks so consumers (e.g. `CachedWebSectionView`,
/// `BrowserChromeRow`) can show a loading indicator or an error+Retry state
/// without any per-site branching. (Decision 6, lanky-pine.3)
public enum WebSectionStatus: Equatable {
    /// A navigation is in progress (provisional navigation started but not
    /// yet finished or failed).
    case loading
    /// The last navigation finished successfully.
    case loaded
    /// The last navigation failed.
    ///
    /// - Parameter description: `error.localizedDescription` from the failing
    ///   `WKNavigationDelegate` callback. Shown verbatim in the error view.
    case failed(description: String)
}
