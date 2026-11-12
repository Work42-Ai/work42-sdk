import Testing

@testable import Work42UI

@Suite("The follow header (WOR-796)")
struct FollowModeViewTests {
    @Test("the header names the person and the device, and marks the tab in front")
    func header() {
        let model = FollowModeHeaderModel(name: "Alex", device: "iPad", tabs: ["Docs", "Inbox"], selected: 1)
        #expect(model.title == "Following Alex · iPad")
        #expect(model.tabs == ["Docs", "Inbox"] && model.selected == 1)
        #expect(model.acting == nil)
    }

    @Test("a selection outside the tabs marks none")
    func outside() {
        #expect(FollowModeHeaderModel(name: "Alex", device: "Mac", tabs: ["Docs"], selected: 4).selected == nil)
        #expect(FollowModeHeaderModel(name: "Alex", device: "Mac", tabs: [], selected: 0).selected == nil)
    }

    @Test("an agent acting in the followed instance is said in the header")
    func agent() {
        #expect(FollowModeHeaderModel(name: "Alex", device: "Mac", tabs: [], selected: nil, agentActing: "Claude").acting == "Claude is acting")
    }
}
