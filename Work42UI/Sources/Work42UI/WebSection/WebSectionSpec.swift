// WebSectionSpec.swift - Value type that drives the reusable WebSectionView.
//
// A WebSectionSpec is the entire configuration for embedding one
// section of a real web app as a native widget. The shared
// WebSectionView is web-app-agnostic: it knows how to load a URL in a
// persistent WKWebView and (in later subtasks) crop it to a single CSS
// selector. Adding a new web-app integration is therefore a matter of
// constructing a new WebSectionSpec value — NOT writing new WebKit
// code. Jira is the first consumer, but nothing here is Jira-specific.
//
// Subtask boundaries (T-005):
//   .1 (this) — the value type + load the URL.
//   .2/.3/.4  — `selector` isolation, navigation handling, and the
//               JS->Swift message-handler seam consume these fields.

import Foundation

/// Immutable description of one embedded web section.
///
/// Everything `WebSectionView` needs is captured here so the same
/// component can power any web-app integration. Web-app-agnostic by
/// design — callers (e.g. a Jira widget) build a spec; the component
/// never branches on the specific site.
public struct WebSectionSpec: Hashable, Sendable {

    /// The page to load. The web app authenticates inside the webview
    /// (see `dataStoreKey`); the component only needs the URL.
    public var url: URL

    /// CSS selector for the single element to isolate and pin to fill
    /// the viewport (e.g. `[data-vc="issue-body-container"]` for Jira).
    ///
    /// Not consumed in subtask .1 — `WebSectionView` only loads the URL
    /// here. Selector isolation (hiding ancestor-chain siblings and
    /// pinning the target) arrives in subtask .2 via an injected
    /// `WKUserScript`. Carried now so the spec is complete and callers
    /// can be written against the final shape.
    public var selector: String

    /// Identity of the persistent `WKWebsiteDataStore` backing the
    /// webview. Sessions (cookies, local storage, login) are scoped to
    /// this key and survive app restarts, so the user authenticates
    /// once per integration. Distinct keys isolate distinct web apps;
    /// a shared key lets sibling sections share one logged-in session.
    public var dataStoreKey: String

    /// Optional human-facing title for the section (widget header, empty
    /// state, accessibility). Web-app-agnostic; purely presentational.
    public var title: String?

    /// When `true`, back the webview with a NON-persistent
    /// (`WKWebsiteDataStore.nonPersistent()`) store — no cookies, local
    /// storage, or login survive the webview's lifetime, and
    /// `dataStoreKey` does not map to any on-disk identity.
    ///
    /// Default `false` so the established integrations (Jira, GitHub) keep
    /// their persistent, login-surviving stores keyed by `dataStoreKey`.
    /// The agent canvas opts in (`WebAppCatalog.canvas`): it serves
    /// app-authored local content over loopback and needs no persisted
    /// auth, so an ephemeral store is correct (spec Decision 5). This stays
    /// web-app-agnostic — `WebSectionView` only branches on this flag, not
    /// on any specific site.
    public var ephemeral: Bool

    public init(
        url: URL,
        selector: String,
        dataStoreKey: String,
        title: String? = nil,
        ephemeral: Bool = false
    ) {
        self.url = url
        self.selector = selector
        self.dataStoreKey = dataStoreKey
        self.title = title
        self.ephemeral = ephemeral
    }
}

/// A JS->Swift signal posted from inside the embedded webview (subtask
/// T-005.4). The injected signal script (see
/// `WebSectionScript.signal(selector:handlerName:)`) posts one of these
/// whenever the isolated section first appears or the document title
/// changes, letting a consumer (e.g. the Jira widget) react — e.g. show the
/// real issue title once Jira has loaded — without scraping the DOM
/// Swift-side.
///
/// The seam is OPTIONAL: a `WebSectionView` with a nil `onSignal` registers
/// no message handler at all, so the JS post is a guarded no-op.
public struct WebSectionSignal: Equatable, Sendable {

    /// The kind of signal. Mirrors the `type` field of the JS payload.
    public enum Kind: String, Equatable, Sendable {
        /// The target section matched by `selector` is present in the DOM.
        case loaded
        /// The document title changed (e.g. SPA navigation to a new issue).
        case title
    }

    /// What happened inside the webview.
    public var kind: Kind

    /// The document title at the time of the signal, when available.
    public var title: String?

    public init(kind: Kind, title: String?) {
        self.kind = kind
        self.title = title
    }
}
