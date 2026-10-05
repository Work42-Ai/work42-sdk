// ThinkingIndicator.swift - Generic "agent is thinking" pulse.
//
// One indicator, every provider. We don't say "Claude is thinking"
// because the app is not Claude — it's a host for *some* agent (the
// user might be pointed at Codex, Gemini, GPT, or any other model
// that speaks the protocol). Instead we cycle through a roster of
// playful single-word verbs (Pondering, Comboluting, Marinating…)
// in the spirit of Claude Code's status line.
//
// Visuals (intentionally cheap):
//   - The animated 42-mark loader (`Loader42`) in brand colors at its
//     minimum size (26pt). It runs entirely as Core Animation keyframe
//     animations on mask layers — **zero per-frame body re-eval**, same
//     budget as the pulsing dots it replaced.
//   - The verb rotates every ~2.2 s with a content transition.
//
// Why so plain: the previous design used `TimelineView(.animation)`
// to drive a gradient shimmer and `.symbolEffect(.variableColor)` on
// an SF Symbol. Both forced SwiftUI to flush its transaction graph at
// ~60 Hz; with multiple text-selection-bearing widgets visible (chat +
// spec + log + qa + …), every flush re-ran `SelectionOverlay.updateNSView`
// across the entire visible tree, walking `NSViewGetTransformToAncestor`
// O(N) per view → O(N²) total. That pegged the main thread the moment
// the indicator was on screen. Dot-opacity animations don't pump the
// graph at all.
//
// Drop into any chat / agent UI:
//
//     ThinkingIndicator()                       // accent-tinted
//     ThinkingIndicator(tint: DT.magentaMid)    // custom tint
//     ThinkingIndicator(verbs: ["Rendering", "Painting"])
//

import SwiftUI

public struct ThinkingIndicator: View {
    /// Master verb roster. Mostly real words for clarity; a handful
    /// of made-up ones ("Comboluting", "Recursing", "Hyperthinking")
    /// keep the indicator from feeling like a status enum.
    public static let defaultVerbs: [String] = [
        "Thinking", "Pondering", "Cogitating", "Musing",
        "Ruminating", "Reflecting", "Brainstorming", "Wondering",
        "Synthesizing", "Reasoning", "Deducing", "Untangling",
        "Decoding", "Percolating", "Marinating", "Stewing",
        "Conjuring", "Weaving", "Distilling", "Refining",
        "Composing", "Plotting", "Scheming", "Tinkering",
        "Calibrating", "Discerning", "Wrangling", "Whirring",
        "Computing", "Calculating", "Imagining", "Speculating",
        "Postulating", "Theorizing", "Vibing", "Comboluting",
        "Recursing", "Hyperthinking", "Noodling", "Quibbling",
        "Architecting", "Crystallizing"
    ]

    private let verbs: [String]
    private let tint: Color

    @State private var verb: String

    public init(
        verbs: [String]? = nil,
        // `iconName` retained for API back-compat with the old SF-symbol
        // form; ignored now that the indicator is dots-only.
        iconName: String = "sparkles",
        tint: Color = DT.systemAccent
    ) {
        _ = iconName
        let roster = verbs ?? Self.defaultVerbs
        self.verbs = roster
        self.tint = tint
        _verb = State(initialValue: roster.randomElement() ?? "Thinking")
    }

    public var body: some View {
        HStack(spacing: 10) {
            Loader42()
                .frame(width: 39, height: 39)
            ShimmerText(verb, font: .system(size: 16, weight: .semibold))
                .contentTransition(.opacity)
                .id(verb)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        // `.task` (not a Timer property): it survives parent body re-evals —
        // a `let Timer.publish` gets recreated on every re-render, so its
        // countdown can restart forever and the verb never rotates.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                withAnimation(.easeInOut(duration: 0.35)) {
                    var next = verbs.randomElement() ?? verb
                    if next == verb, verbs.count > 1 {
                        next = verbs.randomElement() ?? verb
                    }
                    verb = next
                }
            }
        }
    }
}

// MARK: - Shimmer text

/// Text in the light tertiary color with a bright band sweeping through it —
/// the "thinking" shimmer. The band is a masked gradient whose offset runs a
/// single `.linear.repeatForever` layer animation: zero per-frame body
/// re-eval, same budget discipline as the loader itself.
public struct ShimmerText: View {
    private let text: String
    private let font: Font

    @State private var sweep = false

    public init(_ text: String, font: Font) {
        self.text = text
        self.font = font
    }

    public var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(DT.textTertiary)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: DT.textPrimary, location: 0.5),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.7)
                    .offset(x: sweep ? geo.size.width : -geo.size.width * 0.7)
                    .animation(
                        .linear(duration: 1.8).repeatForever(autoreverses: false),
                        value: sweep
                    )
                }
                .mask(Text(text).font(font))
            }
            .onAppear { sweep = true }
    }
}
