// ImportBannerView.swift - the sign-in import banner (WOR-418, redesigned in WOR-419).
//
// One card pinned above the page in every persistent web view, drawn as regular Liquid Glass in every state: no
// tint, no colored stroke. The logo on the left is the Work42 app icon on the offer and the chosen browser's own
// app icon afterwards; the outcome is told by a small badge on that logo (green check, amber lock, red mark).
// Every browser button carries that browser's real logo, read from the installed app. There is deliberately no
// "Not now". Behaviour lives in ImportBannerState; this file only draws it.

import AppKit
import SwiftUI

public struct ImportBannerView: View {

    private let state: ImportBannerState

    public init(state: ImportBannerState = .shared) {
        self.state = state
    }

    public var body: some View {
        Group {
            switch state.phase {
            case .offer:
                offerCard
            case .importing(let browser):
                importingCard(browser: browser)
            case .pickProfile(let browser, let profiles):
                profileCard(browser: browser, profiles: profiles)
            case .fullDiskAccess:
                fullDiskAccessCard
            case .succeeded(let browser, let count):
                successCard(browser: browser, count: count)
            case .failed(let browser, let message):
                failureCard(browser: browser, message: message)
            }
        }
        .animation(DT.aMode, value: state.phase)
    }

    // MARK: States

    private static let offerSubtitle = "Import your cookies from another browser to stay signed in to GitHub, Linear, Google and other sites in every Work42 web widget."

    /// One row on a wide tile; on a narrow one the buttons wrap under the text.
    private var offerCard: some View {
        card {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DT.s12) {
                    BannerLogo(image: NSApplication.shared.applicationIconImage)
                    VStack(alignment: .leading, spacing: 2) {
                        titleText("Bring your sign-ins to Work42")
                        subtitleText(Self.offerSubtitle).lineLimit(1)
                            .frame(minWidth: 0, idealWidth: 240, maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: DT.s8) { browserButtons }
                    quietButton("Don\u{2019}t show again") { state.dontShowAgain() }
                }
                VStack(alignment: .leading, spacing: DT.s8) {
                    HStack(alignment: .top, spacing: DT.s12) {
                        BannerLogo(image: NSApplication.shared.applicationIconImage)
                        VStack(alignment: .leading, spacing: 2) {
                            titleText("Bring your sign-ins to Work42")
                            subtitleText(Self.offerSubtitle)
                        }
                    }
                    HStack(alignment: .top, spacing: DT.s8) {
                        WrappingRow(spacing: DT.s8) { browserButtons }
                        Spacer(minLength: DT.s8)
                        quietButton("Don\u{2019}t show again") { state.dontShowAgain() }
                    }
                    .padding(.leading, 38 + DT.s12)
                }
            }
        }
    }

    @ViewBuilder
    private var browserButtons: some View {
        ForEach(state.browsers, id: \.self) { browser in
            chip(browser.displayName, icon: browser.appIcon) { state.choose(browser) }
        }
    }

    /// Its own card while the Keychain prompt and the read run.
    private func importingCard(browser: ImportableBrowser) -> some View {
        card {
            HStack(spacing: DT.s12) {
                BannerLogo(image: browser.appIcon)
                VStack(alignment: .leading, spacing: 2) {
                    titleText("Importing from \(browser.displayName)\u{2026}")
                    if let service = browser.keychainService {
                        subtitleText("Choose Allow when macOS asks for \u{201C}\(service)\u{201D}.")
                    }
                }
                Spacer(minLength: DT.s8)
                ProgressView().controlSize(.small)
            }
        }
    }

    private func profileCard(browser: ImportableBrowser, profiles: [BrowserProfile]) -> some View {
        card {
            HStack(alignment: .top, spacing: DT.s12) {
                BannerLogo(image: browser.appIcon)
                VStack(alignment: .leading, spacing: DT.s8) {
                    titleText("Which \(browser.displayName) profile?")
                    WrappingRow(spacing: DT.s8) {
                        ForEach(profiles) { profile in
                            chip(profile.name, icon: nil) { state.choose(profile: profile) }
                        }
                    }
                    if let service = browser.keychainService {
                        subtitleText("macOS will ask to allow access to \u{201C}\(service)\u{201D} in your Keychain. Choose Allow.")
                    }
                }
                Spacer(minLength: DT.s8)
                quietButton("Back") { state.back() }
            }
        }
    }

    /// Safari's cookie folder is protected until the app has Full Disk Access.
    private var fullDiskAccessCard: some View {
        card {
            HStack(spacing: DT.s12) {
                BannerLogo(image: ImportableBrowser.safari.appIcon, badge: .accessNeeded)
                VStack(alignment: .leading, spacing: 2) {
                    titleText("Safari needs Full Disk Access")
                    subtitleText("Turn on Work 42 in Full Disk Access, then choose Safari again.")
                }
                Spacer(minLength: DT.s8)
                chip("Open Settings", icon: nil) { state.openFullDiskAccessSettings() }
                quietButton("Back") { state.back() }
            }
        }
    }

    /// Shown for a few seconds, then the banner is gone for good.
    private func successCard(browser: ImportableBrowser, count: Int) -> some View {
        card {
            HStack(spacing: DT.s12) {
                BannerLogo(image: browser.appIcon, badge: .success)
                VStack(alignment: .leading, spacing: 2) {
                    titleText("Imported \(count.formatted()) cookies from \(browser.displayName)")
                    subtitleText("Open web widgets were reloaded.")
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The banner stays, with the reason.
    private func failureCard(browser: ImportableBrowser, message: String) -> some View {
        card {
            HStack(spacing: DT.s12) {
                BannerLogo(image: browser.appIcon, badge: .failure)
                VStack(alignment: .leading, spacing: 2) {
                    titleText("Couldn\u{2019}t read \(browser.displayName)\u{2019}s cookies")
                    subtitleText(message)
                }
                Spacer(minLength: DT.s8)
                chip("Try again", icon: nil) { state.retry() }
                quietButton("Pick another browser") { state.back() }
            }
        }
    }

    // MARK: Pieces

    /// Regular Liquid Glass, the same in every state.
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, DT.s12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCardSurface(cornerRadius: 18)
    }

    private func titleText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: DT.f12, weight: .semibold))
            .foregroundStyle(.primary)
    }

    private func subtitleText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: DT.f11))
            .foregroundStyle(DT.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A glass capsule; with an icon it shows that browser's logo before its name.
    private func chip(_ title: String, icon: NSImage?, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 20, height: 20)
                }
                Text(title).font(.system(size: DT.f12, weight: .medium))
            }
        }
        .modifier(GlassChipStyle())
    }

    /// "Don't show again", "Back", "Pick another browser": present, never loud.
    private func quietButton(_ title: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: DT.f11)).foregroundStyle(DT.textTertiary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Logo with a state badge

private struct BannerLogo: View {
    enum Badge {
        case success, accessNeeded, failure

        var symbol: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .accessNeeded: "lock.fill"
            case .failure: "exclamationmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .success: DT.green
            case .accessNeeded: DT.amber
            case .failure: DT.red
            }
        }
    }

    let image: NSImage?
    var badge: Badge?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    Image(systemName: "globe").resizable().scaledToFit().padding(6).foregroundStyle(.secondary)
                }
            }
            .frame(width: 38, height: 38)
            .shadow(color: .black.opacity(0.16), radius: 3, y: 2)

            if let badge {
                Image(systemName: badge.symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(badge.color)
                    .background(Circle().fill(.background).padding(1))
                    .offset(x: 4, y: 4)
            }
        }
        .frame(width: 38, height: 38)
    }
}

// MARK: - Glass capsule button

/// The macOS 26 glass button as a capsule; a bordered capsule before it.
private struct GlassChipStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.regular)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.regular)
        }
    }
}

// MARK: - Wrapping row

/// Lays its children out left to right and wraps to a new line when the width runs out, so seven browsers still
/// fit in a narrow tile.
private struct WrappingRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, arrangement.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), origins)
    }
}
