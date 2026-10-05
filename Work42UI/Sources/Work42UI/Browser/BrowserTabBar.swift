// BrowserTabBar.swift — Safari-style segmented tab bar for the embedded-browser
// chrome (humble-harbor.6).
//
// Moved from Work42App/Browser/ to Work42UI
// (browser-widgets-not-extending-from-browser.1).
//
// Reuses the GlassTabStrip / TerminalTabStrip visual language: a rounded
// container holds tab pills, a sliding accent capsule highlights the active
// tab via matchedGeometryEffect, each tab shows an optional icon + title with
// an × close affordance, and a + add button sits outside the pill container.
//
// Rendered BELOW BrowserChromeRow when the model has more than one tab.
// Hidden by the caller (BrowserChromeRow) when tabs.count <= 1, so widgets
// with a single tab (Browser, Jira, Canvas) look exactly as they did before.
//
// Prior art: TerminalTabStrip.swift — this view follows the same structure.

import SwiftUI

// MARK: - BrowserTabBar

/// A Safari-style segmented tab bar that renders below the browser chrome row.
/// Shown only when the model has more than one tab (hidden by `BrowserChromeRow`
/// when `model.showsTabBar` is false).
@MainActor
public struct BrowserTabBar: View {

    /// The ordered tab list. Passed directly rather than binding to the model
    /// so this view stays a pure function of its inputs.
    public let tabs: [BrowserTab]

    /// The currently-active tab id, or nil when tabs is empty.
    public let activeTabId: UUID?

    /// Called when the user taps a tab to select it.
    public let onSelect: (UUID) -> Void

    /// Called when the user taps the × button on a tab.
    public let onClose: (UUID) -> Void

    @Namespace private var pill

    public init(
        tabs: [BrowserTab],
        activeTabId: UUID?,
        onSelect: @escaping (UUID) -> Void,
        onClose: @escaping (UUID) -> Void
    ) {
        self.tabs = tabs
        self.activeTabId = activeTabId
        self.onSelect = onSelect
        self.onClose = onClose
    }

    public var body: some View {
        // Tabs expand to fill the full width and share it equally; each tab
        // shrinks as more are added (Safari-style). No "+" here — the new-tab
        // affordance is the single `+` in BrowserChromeRow's trailing controls.
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                tabButton(tab)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.04), lineWidth: 0.5))
        .padding(.horizontal, DT.s8)
        .padding(.vertical, 5)
    }

    // MARK: - Tab button

    @ViewBuilder
    private func tabButton(_ tab: BrowserTab) -> some View {
        let isActive = tab.id == activeTabId

        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                onSelect(tab.id)
            }
        } label: {
            HStack(spacing: 5) {
                // Optional icon/favicon
                if let icon = tab.icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isActive ? DT.systemAccent : Color.secondary)
                }

                // Title — flexes within the tab and truncates as tabs shrink.
                Text(tab.title)
                    .font(.system(size: DT.f12, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? DT.systemAccent : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // × close button
                Button {
                    onClose(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Close \(tab.title)")
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(activeBackground(for: tab, isActive: isActive))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Active background (sliding accent pill)

    @ViewBuilder
    private func activeBackground(for tab: BrowserTab, isActive: Bool) -> some View {
        if isActive {
            Capsule(style: .continuous)
                .fill(DT.systemAccent.opacity(0.16))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(DT.systemAccent.opacity(0.32), lineWidth: 0.5)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .fill(Color.clear)
                        .shadow(color: Color.black.opacity(0.08), radius: 2, x: 0, y: 1)
                )
                .matchedGeometryEffect(id: "browserTabPill", in: pill)
        }
    }
}
