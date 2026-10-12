// Work42YAML.swift - YAML coding for plugins and the app, so Yams never
// appears in Work42UI's public interface (it is an `internal import` here).

import Foundation
internal import Yams

/// Decodes, encodes and loads YAML. Errors are Yams' own, surfaced as `any Error`.
public nonisolated enum Work42YAML {

    /// Decodes `yaml` into `type` (a `Decodable`).
    public static func decode<T: Decodable>(_ type: T.Type, from yaml: String) throws -> T {
        try YAMLDecoder().decode(type, from: yaml)
    }

    /// Encodes `value` as a YAML document.
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        try YAMLEncoder().encode(value)
    }

    /// Parses `yaml` into untyped Foundation values (`[String: Any]`, `[Any]`,
    /// `String`, `Int`, ...). Returns `nil` for an empty document.
    public static func load(_ yaml: String) throws -> Any? {
        try Yams.load(yaml: yaml)
    }
}
