import Foundation

public struct HeartportError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public enum Kind: Sendable {
        case runtimeMissing, runtimeInvalid, prefixMissing, sessionAlive, gameNotInstalled
        case launcherNotInstalled, download, installerChanged, process, timeout, io, usage, cancelled, rosetta
    }
    public let kind: Kind
    public let message: String
    public init(_ kind: Kind, _ message: String) { self.kind = kind; self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}
