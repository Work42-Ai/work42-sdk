// WidgetInstanceID.swift — the one id an agent and a person use for a widget instance (WOR-798).
//
// A session's widgets come in three kinds (`WidgetCollaboration` in Work42PluginKit). A shared widget (a file, a plan, a board) is one
// state for everyone, and a hosted one (a simulator, a terminal) runs on the session owner's Mac alone: each is one instance, and its id
// is the widget's own, `w_<kind>`. A personal widget (the Browser, a plugin built on one) is one instance per person per device, each
// with its own tabs and sign-ins, so its id names whose and where: `w_<kind>_<person>_<device>`. The id does not change while the
// session lasts, whoever else joins.
//
// Everything that names an instance makes the id here: the device and widget tools, the comments a person sends from one, the
// agent's pointer on it. So the id a comment carries is always one the tools take.

import Foundation

public nonisolated enum WidgetInstanceID {
    /// Whose a personal widget's instance is, and on what device.
    public nonisolated struct Owner: Hashable, Sendable, Codable {
        /// The person's name as the session shows it (`Yan Rodriguez`).
        public var person: String
        /// The device, as the session names it (`Mac`, `iPad`); a person's second device of the same kind adds a number (`iPad-2`).
        public var device: String

        public init(person: String, device: String) {
            self.person = person
            self.device = device
        }
    }

    /// The prefix every widget id starts with.
    public static let prefix = "w_"

    /// The id of a widget of kind `kindID` (`browser`, `iosSimulator`, a plugin's `widget:<slug>`): `w_<kind>` for a shared or hosted
    /// widget (no owner), `w_<kind>_<person>_<device>` for one person's instance of a personal widget.
    public static func runtimeID(kindID: String, owner: Owner? = nil) -> String {
        let widget = prefix + kindID.replacingOccurrences(of: ":", with: "_")
        guard let owner else { return widget }
        return "\(widget)_\(slug(owner.person))_\(slug(owner.device))"
    }

    /// Whether `id` names an instance of the widget whose own id is `widgetID`: the widget itself, or one person's instance of it.
    public static func names(_ id: String, instanceOf widgetID: String) -> Bool {
        let id = id.lowercased(), widget = widgetID.lowercased()
        return id == widget || id.hasPrefix(widget + "_")
    }

    /// A name as an id part: lower case, letters and digits, anything else one `-` (`Ana María` is `ana-maría`).
    public static func slug(_ text: String) -> String {
        var out = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
            } else if !out.isEmpty, out.last != "-" {
                out.append("-")
            }
        }
        while out.last == "-" { out.removeLast() }
        return out.isEmpty ? "someone" : out
    }
}
