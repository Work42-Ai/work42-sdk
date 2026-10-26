// ImportBannerStateTests.swift - WOR-418: the shared state behind every sign-in import banner.
//
// The profile lookup, the importer, the delay and the "open System Settings" call are injected, so every transition
// runs without a browser, the Keychain or a six-second wait. UserDefaults is a throwaway suite.

import Foundation
import Testing
@testable import Work42UI

@MainActor
private final class Harness {
    let suiteName = "work42.import-banner-tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    var profiles: [ImportableBrowser: [BrowserProfile]] = [:]
    var profileError: Error?
    var importResult: Result<Int, Error> = .success(1_284)
    var imports: [(ImportableBrowser, BrowserProfile)] = []
    var openedURLs: [URL] = []

    init() { defaults = UserDefaults(suiteName: suiteName)! }

    deinit { UserDefaults().removePersistentDomain(forName: suiteName) }

    static func profile(_ name: String) -> BrowserProfile {
        BrowserProfile(id: name, name: name, cookiesURL: URL(fileURLWithPath: "/tmp/\(name)/Cookies"))
    }

    func state(browsers: [ImportableBrowser] = [.chrome, .safari], delay: Duration = .milliseconds(5)) -> ImportBannerState {
        ImportBannerState(
            defaults: defaults,
            browsers: browsers,
            profiles: { [unowned self] browser in
                if let profileError { throw profileError }
                return profiles[browser] ?? []
            },
            importer: { [unowned self] browser, profile in
                imports.append((browser, profile))
                return try importResult.get()
            },
            resolveDelay: delay,
            openURL: { [unowned self] url in openedURLs.append(url) }
        )
    }
}

struct ImportBannerStateTests {

    private let work = Harness.profile("Work")
    private let personal = Harness.profile("Personal")

    @Test func startsOnTheOfferAndUnresolved() {
        let harness = Harness()
        let state = harness.state()
        #expect(state.phase == .offer)
        #expect(!state.resolved)
        #expect(state.browsers == [.chrome, .safari])
    }

    @Test func aBrowserWithOneProfileImportsStraightAway() async {
        let harness = Harness()
        harness.profiles[.chrome] = [work]
        let state = harness.state(delay: .seconds(60))
        state.choose(.chrome)
        #expect(state.phase == .importing(.chrome))
        await state.waitForImport()
        #expect(state.phase == .succeeded(.chrome, 1_284))
        #expect(harness.imports.count == 1)
        #expect(harness.imports.first?.1 == work)
        #expect(!state.resolved)                 // still showing the success message
    }

    @Test func successResolvesAfterTheDelayAndIsRemembered() async {
        let harness = Harness()
        harness.profiles[.chrome] = [work]
        let state = harness.state()
        state.choose(.chrome)
        await state.waitUntilIdle()
        #expect(state.resolved)
        #expect(harness.defaults.bool(forKey: ImportBannerState.resolvedKey))
        // A new launch (a new state over the same defaults) starts resolved.
        #expect(harness.state().resolved)
    }

    @Test func aBrowserWithSeveralProfilesAsksWhich() async {
        let harness = Harness()
        harness.profiles[.chrome] = [work, personal]
        let state = harness.state()
        state.choose(.chrome)
        #expect(state.phase == .pickProfile(.chrome, [work, personal]))
        #expect(harness.imports.isEmpty)
        state.choose(profile: personal)
        #expect(state.phase == .importing(.chrome))
        await state.waitForImport()
        #expect(harness.imports.first?.1 == personal)
        #expect(state.phase == .succeeded(.chrome, 1_284))
    }

    @Test func choosingAProfileOutsideThePickerDoesNothing() {
        let harness = Harness()
        let state = harness.state()
        state.choose(profile: work)
        #expect(state.phase == .offer)
        #expect(harness.imports.isEmpty)
    }

    @Test func aBrowserWithNoProfileFails() {
        let harness = Harness()
        let state = harness.state()
        state.choose(.chrome)
        #expect(state.phase == .failed(.chrome, "No Chrome profile found"))
        #expect(!state.resolved)
    }

    @Test func aProfileListThatCannotBeReadFailsWithItsReason() {
        let harness = Harness()
        harness.profileError = CookieImportError.unreadable("The profile list (Local State) could not be read.")
        let state = harness.state()
        state.choose(.chrome)
        #expect(state.phase == .failed(.chrome, "The profile list (Local State) could not be read."))
    }

    @Test(arguments: [
        (CookieImportError.keychainDenied, ImportBannerState.Phase.failed(.chrome, "Keychain access was denied. Nothing was imported.")),
        (CookieImportError.fullDiskAccessRequired, ImportBannerState.Phase.fullDiskAccess),
        (CookieImportError.unreadable("The cookie database is damaged."), ImportBannerState.Phase.failed(.chrome, "The cookie database is damaged.")),
        (CookieImportError.noCookies, ImportBannerState.Phase.failed(.chrome, "No cookies were found in Chrome.")),
    ])
    func importErrorsMapToTheirStateAndNeverResolve(error: CookieImportError, expected: ImportBannerState.Phase) async {
        let harness = Harness()
        harness.profiles[.chrome] = [work]
        harness.importResult = .failure(error)
        let state = harness.state()
        state.choose(.chrome)
        await state.waitUntilIdle()
        #expect(state.phase == expected)
        #expect(!state.resolved)
        #expect(!harness.defaults.bool(forKey: ImportBannerState.resolvedKey))
    }

    @Test func anUnexpectedErrorFailsWithItsDescription() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let harness = Harness()
        harness.profiles[.chrome] = [work]
        harness.importResult = .failure(Boom())
        let state = harness.state()
        state.choose(.chrome)
        await state.waitUntilIdle()
        #expect(state.phase == .failed(.chrome, "boom"))
    }

    @Test func tryAgainRepeatsTheLastChoiceAndCanThenSucceed() async {
        let harness = Harness()
        harness.profiles[.chrome] = [work]
        harness.importResult = .failure(CookieImportError.keychainDenied)
        let state = harness.state(delay: .seconds(60))
        state.choose(.chrome)
        await state.waitForImport()
        #expect(harness.imports.count == 1)

        harness.importResult = .success(10)
        state.retry()
        await state.waitForImport()
        #expect(harness.imports.count == 2)
        #expect(harness.imports.last?.1 == work)
        #expect(state.phase == .succeeded(.chrome, 10))
    }

    @Test func tryAgainAfterAPickedProfileReusesThatProfile() async {
        let harness = Harness()
        harness.profiles[.chrome] = [work, personal]
        harness.importResult = .failure(CookieImportError.keychainDenied)
        let state = harness.state()
        state.choose(.chrome)
        state.choose(profile: personal)
        await state.waitForImport()
        state.retry()
        await state.waitForImport()
        #expect(harness.imports.map(\.1) == [personal, personal])
    }

    @Test func backReturnsToTheOffer() async {
        let harness = Harness()
        harness.importResult = .failure(CookieImportError.noCookies)
        harness.profiles[.chrome] = [work]
        let state = harness.state()
        state.choose(.chrome)
        await state.waitForImport()
        state.back()
        #expect(state.phase == .offer)

        harness.profiles[.chrome] = [work, personal]
        state.choose(.chrome)
        state.back()
        #expect(state.phase == .offer)
    }

    @Test func dontShowAgainResolvesAtOnceAndPersists() {
        let harness = Harness()
        let state = harness.state()
        state.dontShowAgain()
        #expect(state.resolved)
        #expect(harness.defaults.bool(forKey: ImportBannerState.resolvedKey))
        #expect(harness.state().resolved)
    }

    @Test func theFullDiskAccessButtonOpensThePrivacyPane() {
        let harness = Harness()
        let state = harness.state()
        state.openFullDiskAccessSettings()
        #expect(harness.openedURLs.map(\.absoluteString) == ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"])
    }

    @Test func theResolvedKeyIsStable() {
        #expect(ImportBannerState.resolvedKey == "work42.browserImport.resolved")
    }
}
