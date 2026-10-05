// PersonPalette.swift — curated person-identity colors + stable hashing.
//
// Color belongs to the PERSON (confirmed design, artifact
// speaker-people-redesign v2): the same person always gets the same color,
// across meetings and across every surface that renders them — the People
// widget, the transcript (once a speaker is matched to them), and the
// "Who is this?" selection dialog.
//
// Why a curated palette instead of the hue-from-hash approach
// `speakerColor(for:)` uses: an arbitrary hash-derived hue can land on
// muddy, clashing, or semantically-loaded colors (destructive red, success
// green, the system accent). This palette is hand-picked to read well on
// the app's surfaces at full strength (avatars, name captions) AND at low
// alpha (~0.10 bubble tints), in both light and dark mode — anchored on
// the four colors the confirmed mockup used.
//
// `speakerColor(for:)` (ChatBubble.swift) remains for existing non-person
// call sites; person/speaker surfaces use `personColor(for:)`.

import SwiftUI

/// Curated palette for person-identity colors. Order matters only in that
/// the stable hash indexes into it — the same key maps to the same color
/// forever. Fixed component values (not hue-computed, not appearance-
/// adaptive) so a person's color is identical in light and dark mode.
///
/// Anchors from the confirmed mockup: muted red, teal, purple, amber.
/// Extended with mid-saturation companions chosen to stay distinct from
/// each other and from the app's semantic colors (DT.red destructive,
/// DT.green success, the system accent blue) at a glance.
public let personPalette: [Color] = [
    Color(red: 0.839, green: 0.365, blue: 0.416), // muted red    #D65D6A
    Color(red: 0.247, green: 0.639, blue: 0.588), // teal         #3FA396
    Color(red: 0.541, green: 0.435, blue: 0.820), // purple       #8A6FD1
    Color(red: 0.788, green: 0.541, blue: 0.176), // amber        #C98A2D
    Color(red: 0.353, green: 0.545, blue: 0.812), // slate blue   #5A8BCF
    Color(red: 0.769, green: 0.427, blue: 0.647), // orchid       #C46DA5
    Color(red: 0.427, green: 0.616, blue: 0.353), // moss green   #6D9D5A
    Color(red: 0.812, green: 0.475, blue: 0.318), // terracotta   #CF7951
    Color(red: 0.310, green: 0.604, blue: 0.702), // steel cyan   #4F9AB3
    Color(red: 0.663, green: 0.518, blue: 0.353), // camel        #A9845A
    Color(red: 0.475, green: 0.529, blue: 0.780), // periwinkle   #7987C7
    Color(red: 0.702, green: 0.412, blue: 0.443), // rosewood     #B36971
]

/// Stable person color: FNV-1a 32-bit hash of `key` (person_id preferred;
/// display-name fallback for name-only entries) indexed into the curated
/// palette. Deterministic forever for a given key — the identity guarantee
/// every person surface relies on.
public func personColor(for key: String) -> Color {
    var hash: UInt32 = 2_166_136_261 // FNV offset basis
    for byte in key.utf8 {
        hash ^= UInt32(byte)
        hash &*= 16_777_619 // FNV prime
    }
    return personPalette[Int(hash % UInt32(personPalette.count))]
}
