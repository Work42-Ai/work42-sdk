import CoreGraphics
import Testing

@testable import Work42UI

// WOR-807 / N1: the widget's name shows before the address only while the address keeps room; otherwise the mark stands alone.

@Suite("Browser identity prefix (WOR-807)")
@MainActor
struct BrowserIdentityPrefixTests {
    private let browser: CGFloat = 52  // "Browser" at the address font, roughly
    private let specDocument: CGFloat = 95  // "Spec Document", roughly

    @Test("a roomy address capsule shows a short name")
    func roomy() {
        #expect(BrowserChromeRow.showsName(addressWidth: 785, nameWidth: browser))
        #expect(BrowserChromeRow.showsName(addressWidth: 520, nameWidth: specDocument))
    }

    @Test("a narrow one drops to the mark alone, whatever the name")
    func narrow() {
        #expect(!BrowserChromeRow.showsName(addressWidth: 160, nameWidth: browser))
        #expect(!BrowserChromeRow.showsName(addressWidth: 215, nameWidth: browser))
    }

    @Test("a long name drops sooner than a short one, so the address is never left with a few letters (N1)")
    func longName() {
        // The Spec Document tile of the report: the capsule was about 215 pt wide and the address showed "htt".
        #expect(!BrowserChromeRow.showsName(addressWidth: 215, nameWidth: specDocument))
        // A width where "Browser" still fits beside a readable address but "Spec Document" does not.
        let width = BrowserChromeRow.identityOverhead + BrowserChromeRow.minAddressWidth + browser + 5
        #expect(BrowserChromeRow.showsName(addressWidth: width, nameWidth: browser))
        #expect(!BrowserChromeRow.showsName(addressWidth: width, nameWidth: specDocument))
    }

    @Test("the address always keeps its minimum when the name shows")
    func addressKeepsRoom() {
        for width in stride(from: CGFloat(100), through: 900, by: 20) where BrowserChromeRow.showsName(addressWidth: width, nameWidth: specDocument) {
            #expect(width - BrowserChromeRow.identityOverhead - specDocument >= BrowserChromeRow.minAddressWidth)
        }
    }
}
