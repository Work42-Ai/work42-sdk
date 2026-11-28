// ExtensionLog.swift — os.Logger for the extension bridge, so `log show --predicate 'subsystem == "com.work42.extension"'` finds it.
//
// One line per event, `key=value` pairs. Metadata only: ids, counts, reasons and error text; never transcript text or audio.

import Foundation
import os

nonisolated enum ExtensionLog {
    static let subsystem = "com.work42.extension"
    /// Streams on the host side: opened, ended, cancelled, failed.
    static let host = Logger(subsystem: subsystem, category: "host-stream")
    /// Streams on the extension side: registered, delivered end, consumer cancelled, connection lost.
    static let channel = Logger(subsystem: subsystem, category: "channel")
    /// The speech and audio proxies: decoding errors and the errors a stream ended with.
    static let proxy = Logger(subsystem: subsystem, category: "proxy")

    /// `id` shortened to its first 8 characters, enough to follow one stream through a log without the noise.
    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }
}
