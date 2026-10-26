// ImportBannerState.swift - the one shared state behind every sign-in import banner (WOR-418).
//
// A single @Observable instance drives the banner in every persistent web view, so all of them show the same
// step and hiding it is immediate everywhere. `resolved` (an import succeeded, or "Don't show again") is stored
// in UserDefaults and survives relaunch. A failed or cancelled import never sets it: the banner stays up.

import AppKit
import Foundation
import Observation

@Observable
@MainActor
public final class ImportBannerState {

    public static let shared = ImportBannerState()
    public static let resolvedKey = "work42.browserImport.resolved"

    /// The step the banner is showing.
    public enum Phase: Equatable, Sendable {
        case offer
        case pickProfile(ImportableBrowser, [BrowserProfile])
        case importing(ImportableBrowser)
        case fullDiskAccess
        case failed(ImportableBrowser, String)
        case succeeded(ImportableBrowser, Int)
    }

    /// True once an import succeeded or the user opted out. The banner is hidden everywhere while this holds.
    public private(set) var resolved: Bool
    public private(set) var phase: Phase = .offer
    /// The browsers installed on this Mac, worked out once.
    public let browsers: [ImportableBrowser]

    /// What "Try again" repeats.
    private enum Choice {
        case browser(ImportableBrowser)
        case profile(ImportableBrowser, BrowserProfile)
    }

    private let defaults: UserDefaults
    private let profilesFor: @MainActor (ImportableBrowser) throws -> [BrowserProfile]
    private let importer: @MainActor (ImportableBrowser, BrowserProfile) async throws -> Int
    private let openURL: @MainActor (URL) -> Void
    private let resolveDelay: Duration

    @ObservationIgnored private var lastChoice: Choice?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var resolveTask: Task<Void, Never>?

    /// The collaborators are injectable so tests can drive every transition without a browser, the Keychain or a
    /// six-second wait.
    public init(
        defaults: UserDefaults = .standard,
        browsers: [ImportableBrowser] = ImportableBrowser.installed(),
        profiles: @escaping @MainActor (ImportableBrowser) throws -> [BrowserProfile] = { try BrowserProfile.profiles(for: $0) },
        importer: @escaping @MainActor (ImportableBrowser, BrowserProfile) async throws -> Int = {
            try await CookieImporter.importCookies(from: $0, profile: $1)
        },
        resolveDelay: Duration = .seconds(6),
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.defaults = defaults
        self.browsers = browsers
        self.profilesFor = profiles
        self.importer = importer
        self.resolveDelay = resolveDelay
        self.openURL = openURL
        self.resolved = defaults.bool(forKey: Self.resolvedKey)
    }

    // MARK: Actions

    /// The user picked a browser: import straight away when it has one profile, ask which when it has several.
    public func choose(_ browser: ImportableBrowser) {
        guard !isImporting else { return }
        lastChoice = .browser(browser)
        do {
            let profiles = try profilesFor(browser)
            switch profiles.count {
            case 0: phase = .failed(browser, "No \(browser.displayName) profile found")
            case 1: start(browser, profiles[0])
            default: phase = .pickProfile(browser, profiles)
            }
        } catch {
            phase = failure(error, browser)
        }
    }

    /// The user picked one of the profiles offered by `.pickProfile`.
    public func choose(profile: BrowserProfile) {
        guard !isImporting, case .pickProfile(let browser, _) = phase else { return }
        start(browser, profile)
    }

    /// "Try again" after a failure: repeats the last choice.
    public func retry() {
        guard !isImporting, let lastChoice else { return }
        switch lastChoice {
        case .browser(let browser): choose(browser)
        case .profile(let browser, let profile): start(browser, profile)
        }
    }

    /// Back to the browser list ("Back", "Pick another browser").
    public func back() {
        guard !isImporting else { return }
        phase = .offer
    }

    /// "Don't show again": hides the banner in every web view, for good.
    public func dontShowAgain() {
        markResolved()
    }

    /// The Full Disk Access state's button.
    public func openFullDiskAccessSettings() {
        openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    // MARK: Import

    private var isImporting: Bool {
        if case .importing = phase { return true }
        return false
    }

    private func start(_ browser: ImportableBrowser, _ profile: BrowserProfile) {
        lastChoice = .profile(browser, profile)
        phase = .importing(browser)
        importTask = Task { [weak self] in
            guard let self else { return }
            do {
                let count = try await importer(browser, profile)
                phase = .succeeded(browser, count)
                scheduleResolve()
            } catch {
                phase = failure(error, browser)
            }
        }
    }

    /// The success message stays for a while, then the banner is gone for good.
    private func scheduleResolve() {
        resolveTask?.cancel()
        resolveTask = Task { [weak self, resolveDelay] in
            try? await Task.sleep(for: resolveDelay)
            guard !Task.isCancelled else { return }
            self?.markResolved()
        }
    }

    private func markResolved() {
        resolveTask?.cancel()
        defaults.set(true, forKey: Self.resolvedKey)
        resolved = true
    }

    private func failure(_ error: Error, _ browser: ImportableBrowser) -> Phase {
        switch error as? CookieImportError {
        case .keychainDenied: .failed(browser, "Keychain access was denied. Nothing was imported.")
        case .fullDiskAccessRequired: .fullDiskAccess
        case .unreadable(let message): .failed(browser, message)
        case .noCookies: .failed(browser, "No cookies were found in \(browser.displayName).")
        case nil: .failed(browser, error.localizedDescription)
        }
    }

    /// Waits for the import in flight, not for the success countdown. Tests only.
    func waitForImport() async {
        await importTask?.value
    }

    /// Waits for the import and the success countdown to finish. Tests only.
    func waitUntilIdle() async {
        await importTask?.value
        await resolveTask?.value
    }
}
