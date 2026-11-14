import Testing

@testable import Work42UI

// WOR-807: the widget's name shows before the address when the capsule has room; short of space only the mark stays.

@Suite("Browser identity prefix (WOR-807)")
@MainActor
struct BrowserIdentityPrefixTests {
    @Test("a roomy address capsule shows the name")
    func roomy() {
        #expect(BrowserChromeRow.showsName(addressWidth: 520))
        #expect(BrowserChromeRow.showsName(addressWidth: BrowserChromeRow.namePrefixMinWidth))
    }

    @Test("a narrow one drops to the mark alone")
    func narrow() {
        #expect(!BrowserChromeRow.showsName(addressWidth: BrowserChromeRow.namePrefixMinWidth - 1))
        #expect(!BrowserChromeRow.showsName(addressWidth: 160))
    }
}
