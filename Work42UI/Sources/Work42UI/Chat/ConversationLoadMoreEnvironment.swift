// ConversationLoadMoreEnvironment.swift - how a host hands `ConversationView` its remote history (WOR-642).
//
// It is an environment value and a modifier, not a `ConversationView` parameter. `ConversationView` is a public struct a plugin builds
// in its own code, and the SDK is not built with library evolution: a new stored property or a changed init would break every plugin
// built against the SDK that shipped before (the layout and the init's symbol are compiled into the plugin). The environment is read in
// a nested view (`ConversationLoadMoreReader`), which changes nothing the plugin has compiled in.

import SwiftUI

private struct ConversationLoadMoreKey: EnvironmentKey {
    static var defaultValue: ConversationLoadMore? { nil }
}

extension EnvironmentValues {
    var conversationLoadMore: ConversationLoadMore? {
        get { self[ConversationLoadMoreKey.self] }
        set { self[ConversationLoadMoreKey.self] = newValue }
    }
}

extension View {
    /// Tells a `ConversationView` inside this view that older messages are kept by the host (the iPad's, where the Mac holds them):
    /// reaching the top with nothing older left in `items` calls `loadMore.load`, and the page arrives as items added at the FRONT
    /// of `items` with the reader keeping their place. Nil (the default) for a conversation that holds all of its history.
    public func conversationLoadMore(_ loadMore: ConversationLoadMore?) -> some View {
        environment(\.conversationLoadMore, loadMore)
    }
}

/// Reads the environment value and hands it to `build`.
struct ConversationLoadMoreReader<Content: View>: View {
    @Environment(\.conversationLoadMore) private var loadMore
    let build: (ConversationLoadMore?) -> Content

    var body: some View { build(loadMore) }
}
