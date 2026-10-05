// MarkdownTheme.swift - The one Markdown theme every prose surface
// in the app speaks through.
//
// Apply it as `Markdown(body).markdownTheme(.work42)` (or the back-
// compat alias `.flow42`) wherever you render user-authored or agent-
// authored markdown — chat transcripts, spec widgets, QA reports, PR
// bodies. The theme is the single source of truth for:
//
//   - Body type (size + lineSpacing for a comfortable reading rhythm)
//   - Inline code (tinted accent pill, monospaced, mid-weight)
//   - Code blocks (material card on a surface tone, hairline stroke)
//   - Headings (descending size, semibold, breathing padding)
//   - Lists (subtle bullet indent, generous row spacing)
//   - Block quotes (accent left bar, secondary text)
//   - Tables (hairline grid, header tint)
//   - Thematic breaks (a single quiet hairline)
//
// We DO NOT use `MarkdownUI`'s default theme as a starting point.
// Every surface is configured explicitly so the result reads as
// part of the Work42 design system, not a generic markdown blob.
//
// Color philosophy: everything that's an "interactive" hue (links,
// inline code highlight) inherits `Color.accentColor` so the app
// adopts whatever accent the user picked in System Settings →
// Appearance. Neutral chrome (block quote text, thematic breaks,
// code block fill) stays on the semantic primary/secondary scale
// so it reads correctly in both light and dark mode.

import MarkdownUI
import SwiftUI

public extension MarkdownUI.Theme {

    /// The Work42 markdown theme. Use it for any rendered markdown
    /// in the apps; the look is tuned to match the rest of the
    /// design system (spacing, type scale, accent colour) so a spec
    /// widget and a chat bubble read as the same surface family.
    static let work42: MarkdownUI.Theme = {
        var theme = MarkdownUI.Theme()
            // MARK: Body text + paragraph rhythm
            //
            // 16pt sits between the design-system body (DT.f13 == 15)
            // and the emphasis step (DT.f14 == 16). Paired with the
            // 6pt lineSpacing it reads close to Apple Notes / Linear
            // — comfortable for long specs without feeling oversized
            // inside the inspector's narrow column.
            .text {
                FontSize(16)
                ForegroundColor(.primary)
            }
            .paragraph { configuration in
                configuration.label
                    .lineSpacing(6)
                    .padding(.bottom, DT.s12)   // air BETWEEN paragraphs
            }

            // MARK: Inline marks
            .strong { FontWeight(.semibold) }
            .emphasis { FontStyle(.italic) }

            // Inline `code`: monospaced primary text on a faint
            // neutral background — just enough to set code-like
            // tokens apart from prose without colouring them. We
            // deliberately DON'T tint with the accent here: a spec
            // can contain dozens of `inline_code` spans, and tinting
            // every one of them in accent floods the page and
            // dilutes the signal of things that *do* deserve a
            // colour, like links. Accent stays reserved for
            // interactive / focal elements.
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(15)
                BackgroundColor(.primary.opacity(0.08))
            }

            // Links → system accent, underlined. Underline keeps
            // them legible even when the accent is close to the
            // body colour (e.g. high-contrast appearance).
            .link {
                ForegroundColor(DT.systemAccent)
                UnderlineStyle(.single)
            }

            // MARK: Headings
            //
            // Hierarchy in 4pt steps with breathing padding above
            // each. We bias the top padding so a heading is visually
            // grouped with the content that FOLLOWS it, not the one
            // it just left.
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(24)
                    }
                    .padding(.top, DT.s16)
                    .padding(.bottom, DT.s8)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(21)
                    }
                    .padding(.top, DT.s16)
                    .padding(.bottom, DT.s4)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(18)
                    }
                    .padding(.top, DT.s12)
                    .padding(.bottom, DT.s4)
            }
            .heading4 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(16)
                    }
                    .padding(.top, DT.s8)
            }

            // MARK: Code blocks
            //
            // Multi-line fenced blocks get the design-system surface
            // treatment — `DT.surface` fill with a hairline stroke
            // and rounded corners. We DON'T tint them with the
            // accent: inline code uses the accent for emphasis, the
            // block is the "neutral surface" counterpart so they
            // visually divide labour.
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(14)
                        }
                        .padding(DT.s12)
                }
                .background(
                    RoundedRectangle(cornerRadius: DT.rCard, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DT.rCard, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .padding(.vertical, DT.s4)
            }

            // MARK: Lists
            //
            // The default MarkdownUI list rendering is fine; we just
            // want generous row spacing so multi-line bullets don't
            // glue together. The list items themselves inherit the
            // paragraph style (with its 6pt lineSpacing) so a multi-
            // line bullet reads at the same rhythm as body prose.
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: DT.s4, bottom: DT.s4)
            }

            // MARK: Block quotes
            //
            // Accent-tinted left bar + secondary text. Inherits the
            // user's accent so quotes feel cohesive with links and
            // inline code.
            .blockquote { configuration in
                HStack(spacing: DT.s12) {
                    Rectangle()
                        .fill(DT.systemAccent.opacity(0.5))
                        .frame(width: 3)
                    configuration.label
                        .markdownTextStyle { ForegroundColor(.secondary) }
                }
                .padding(.vertical, DT.s4)
            }

            // MARK: Tables
            //
            // Compact data display. Hairline grid in the same opacity
            // family as cards; header row gets a faint accent tint so
            // it reads as "this is the legend".
            .table { configuration in
                configuration.label
                    .markdownTableBorderStyle(
                        .init(color: Color.primary.opacity(0.08))
                    )
                    .markdownTableBackgroundStyle(
                        .alternatingRows(
                            Color.clear,
                            Color.primary.opacity(0.03)
                        )
                    )
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(15)
                    }
                    .padding(.horizontal, DT.s8)
                    .padding(.vertical, DT.s4)
            }

            // MARK: Thematic break
            //
            // `---` in markdown. One quiet hairline; not a heavy
            // divider. Padding above + below so it doesn't kiss the
            // surrounding text.
            .thematicBreak {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 1)
                    .padding(.vertical, DT.s12)
            }

        return theme
    }()

    /// Back-compat alias. Pre-redesign call sites referenced
    /// `.flow42`; the rename to `.work42` reflects that the theme
    /// now lives in the design-system package alongside `DT` and
    /// `Card`. New code should use `.work42`.
    static var flow42: MarkdownUI.Theme { work42 }
}
