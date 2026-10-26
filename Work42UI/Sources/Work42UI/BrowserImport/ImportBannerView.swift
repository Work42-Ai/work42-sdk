// ImportBannerView.swift - the sign-in import banner (WOR-418), as in the confirmed mockup.
//
// One card pinned above the page in every persistent web view. It renders the shared ImportBannerState's phase:
// offer (a blue info card, one button per installed browser, "Don't show again" at the trailing edge), profile pick,
// Full Disk Access (amber), success (green) and failure (red). There is deliberately no "Not now".

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
                offerCard(importing: nil)
            case .importing(let browser):
                offerCard(importing: browser)
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

    /// State 1 (and the importing variant: the same card with a spinner and disabled buttons).
    private func offerCard(importing: ImportableBrowser?) -> some View {
        card(tint: DT.blue) {
            HStack(alignment: .top, spacing: DT.s12) {
                badge("person.badge.key", tint: DT.blue)
                VStack(alignment: .leading, spacing: DT.s4) {
                    Text("Bring your sign-ins to Work42")
                        .font(.system(size: DT.f13, weight: .semibold))
                    Text("Import your cookies from another browser to stay signed in to GitHub, Linear, Google and other sites in every Work42 web widget.")
                        .font(.system(size: DT.f12))
                        .foregroundStyle(DT.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: DT.s12) {
                        WrappingRow(spacing: DT.s8) {
                            ForEach(Array(state.browsers.enumerated()), id: \.element) { index, browser in
                                actionButton(browser.displayName, prominent: index == 0, tint: DT.blue) {
                                    state.choose(browser)
                                }
                            }
                            if importing != nil { ProgressView().controlSize(.small).padding(.horizontal, DT.s4) }
                        }
                        .disabled(importing != nil)
                        Spacer(minLength: DT.s8)
                        textButton("Don't show again", tint: DT.textSecondary) { state.dontShowAgain() }
                            .disabled(importing != nil)
                    }
                    .padding(.top, DT.s8)
                }
            }
        }
    }

    /// State 2: which profile, with the Keychain hint for the Chromium family.
    private func profileCard(browser: ImportableBrowser, profiles: [BrowserProfile]) -> some View {
        card(tint: DT.blue) {
            VStack(alignment: .leading, spacing: DT.s8) {
                Text("Which \(browser.displayName) profile?")
                    .font(.system(size: DT.f13, weight: .semibold))
                WrappingRow(spacing: DT.s8) {
                    ForEach(Array(profiles.enumerated()), id: \.element) { index, profile in
                        actionButton(profile.name, prominent: index == 0, tint: DT.blue) {
                            state.choose(profile: profile)
                        }
                    }
                    textButton("Back", tint: DT.blue) { state.back() }
                }
                if let service = browser.keychainService {
                    Text("macOS will ask to allow access to \u{201C}\(service)\u{201D} in your Keychain. Choose Allow.")
                        .font(.system(size: DT.f11))
                        .foregroundStyle(DT.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// State 3: Safari's cookie folder is protected until the app has Full Disk Access.
    private var fullDiskAccessCard: some View {
        card(tint: DT.amber) {
            VStack(alignment: .leading, spacing: DT.s4) {
                Text("Safari needs Full Disk Access")
                    .font(.system(size: DT.f13, weight: .semibold))
                Text("Safari keeps its cookies in a protected folder. Turn on Work 42 in Full Disk Access, then choose Safari again.")
                    .font(.system(size: DT.f12))
                    .foregroundStyle(DT.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DT.s12) {
                    actionButton("Open System Settings", prominent: true, tint: DT.amber) { state.openFullDiskAccessSettings() }
                    textButton("Back", tint: DT.amber) { state.back() }
                }
                .padding(.top, DT.s8)
            }
        }
    }

    /// State 4: shown for a few seconds, then the banner is gone for good.
    private func successCard(browser: ImportableBrowser, count: Int) -> some View {
        card(tint: DT.green) {
            HStack(alignment: .center, spacing: DT.s12) {
                badge("checkmark", tint: DT.green)
                (Text("Imported \(count.formatted()) cookies from \(browser.displayName).").fontWeight(.semibold)
                    + Text(" Open web widgets were reloaded."))
                    .font(.system(size: DT.f12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// State 5: the banner stays, with the reason.
    private func failureCard(browser: ImportableBrowser, message: String) -> some View {
        card(tint: DT.red) {
            VStack(alignment: .leading, spacing: DT.s4) {
                Text("Couldn\u{2019}t read \(browser.displayName)\u{2019}s cookies")
                    .font(.system(size: DT.f13, weight: .semibold))
                Text(message)
                    .font(.system(size: DT.f12))
                    .foregroundStyle(DT.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DT.s12) {
                    actionButton("Try again", prominent: false, tint: DT.red) { state.retry() }
                    textButton("Pick another browser", tint: DT.red) { state.back() }
                }
                .padding(.top, DT.s8)
            }
        }
    }

    // MARK: Pieces

    private func card<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DT.s12)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: DT.rPanel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DT.rPanel, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }

    private func badge(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: DT.f11, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.16), in: Circle())
    }

    /// The first browser is the prominent glass button; the rest are bordered, like the browser chrome's own buttons.
    private func actionButton(_ title: String, prominent: Bool, tint: Color, action: @escaping @MainActor () -> Void) -> some View {
        Work42ActionButton(treatment: prominent ? .glass(tint: tint) : .bordered, action: action) {
            Text(title).font(.system(size: DT.f12, weight: .medium))
        }
    }

    private func textButton(_ title: String, tint: Color, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: DT.f12, weight: .medium)).foregroundStyle(tint)
        }
        .buttonStyle(.plain)
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
