import Foundation

/// The public Work42 SDK release and binary compatibility contract.
///
/// API releases follow semantic versioning. `abiGeneration` changes only when
/// a binary layout or symbol contract used by an already-built plugin becomes
/// incompatible. The host, CLI, loader, templates, and release packages all
/// read these values rather than maintaining their own mirrors.
public enum Work42SDKCompatibility {
    nonisolated public static let version = "1.2.0"
    nonisolated public static let abiGeneration: Int32 = 11
}
