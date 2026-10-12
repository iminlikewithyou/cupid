import Foundation

/// A minimal argument parser: `command [positionals] [--flag] [--option value | --option=value]`.
struct Arguments {
    var command: String?
    var positionals: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    struct UsageError: Error, CustomStringConvertible { let description: String }

    /// `valued`: options that take a value. `allowedFlags`: every accepted flag.
    init(_ argv: [String], valued: Set<String>, allowedFlags: Set<String>) throws {
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            if arg == "--" { positionals += argv[(i + 1)...]; break }
            if arg.hasPrefix("--") || (arg.hasPrefix("-") && arg.count == 2 && arg != "-") {
                var name = arg.hasPrefix("--") ? String(arg.dropFirst(2)) : String(arg.dropFirst())
                if name == "h" { name = "help" }
                if name == "y" { name = "yes" }
                var value: String?
                if let eq = name.firstIndex(of: "=") { value = String(name[name.index(after: eq)...]); name = String(name[..<eq]) }
                if valued.contains(name) {
                    if value == nil {
                        i += 1
                        guard i < argv.count else { throw UsageError(description: "--\(name) needs a value") }
                        value = argv[i]
                    }
                    options[name] = value
                } else if allowedFlags.contains(name), value == nil {
                    flags.insert(name)
                } else {
                    throw UsageError(description: "unknown option: \(arg)")
                }
            } else if command == nil {
                command = arg
            } else {
                positionals.append(arg)
            }
            i += 1
        }
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }
}
