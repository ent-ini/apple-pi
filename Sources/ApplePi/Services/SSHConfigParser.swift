import Foundation

/// Lightweight parser for OpenSSH client config files (`~/.ssh/config` and
/// `Include`d fragments).
///
/// Scope: enough for the host picker and to auto-fill `user@host:port` plus
/// the first `IdentityFile` from a config block. This is not a full re-
/// implementation of `ssh_config(5)` — `Match` blocks, tokenisation edge
/// cases, and `ProxyCommand` expansion are intentionally out of scope.
enum SSHConfigParser {
    /// Returns the parsed entries from `~/.ssh/config` plus any `Include`d
    /// files. Wildcard-only `Host *` patterns are filtered out because they
    /// represent defaults, not selectable hosts.
    static func parseUserConfig(homeDirectory: String = NSHomeDirectory()) -> [SSHConfigEntry] {
        let mainPath = "\(homeDirectory)/.ssh/config"
        var seenSources: Set<String> = []
        var rawEntries: [RawEntry] = []
        loadFile(at: mainPath, homeDirectory: homeDirectory, seenSources: &seenSources, into: &rawEntries)
        return collapsed(rawEntries).filter { entry in
            !entry.hostPatterns.isEmpty && !entry.hostPatterns.allSatisfy { isWildcardPattern($0) }
        }
    }

    // MARK: - Private

    private struct RawEntry {
        var hostPatterns: [String] = []
        var directives: [String: String] = [:]
        var booleanDirectives: [String: Bool] = [:]
        var sourcePath: String
    }

    private static func loadFile(
        at path: String,
        homeDirectory: String,
        seenSources: inout Set<String>,
        into rawEntries: inout [RawEntry]
    ) {
        let standardized = (path as NSString).standardizingPath
        guard !seenSources.contains(standardized) else { return }
        seenSources.insert(standardized)

        guard let contents = try? String(contentsOfFile: standardized, encoding: .utf8) else { return }

        var current = RawEntry(sourcePath: standardized)
        var inBlock = false

        for rawLine in contents.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let tokenized = tokenize(line)
            guard let keyword = tokenized.first?.lowercased() else { continue }
            let valueTokens = Array(tokenized.dropFirst())

            if keyword == "host" {
                if inBlock { rawEntries.append(current) }
                current = RawEntry(sourcePath: standardized)
                inBlock = true
                current.hostPatterns = valueTokens
                continue
            }

            guard inBlock else { continue }

            if keyword == "include" {
                // Include can appear inside a Host block per ssh_config(5).
                // We do not commit `current` here: any subsequent directives
                // in the enclosing block continue to accumulate on it.
                for pattern in valueTokens {
                    let expanded = expandPath(pattern, homeDirectory: homeDirectory)
                    for match in expandGlob(pattern: expanded) {
                        loadFile(at: match, homeDirectory: homeDirectory, seenSources: &seenSources, into: &rawEntries)
                    }
                }
                continue
            }

            // Some keywords take boolean toggles. Anything else we treat as a
            // single string value; for repeated keywords the first wins,
            // matching the behaviour `ssh` uses for `IdentityFile`.
            if let boolValue = booleanValue(for: keyword, tokens: valueTokens) {
                current.booleanDirectives[keyword] = boolValue
            } else if let stringValue = valueTokens.first, current.directives[keyword] == nil {
                current.directives[keyword] = stringValue
            }
        }

        if inBlock { rawEntries.append(current) }
    }

    private static func collapsed(_ rawEntries: [RawEntry]) -> [SSHConfigEntry] {
        rawEntries.compactMap { raw in
            guard !raw.hostPatterns.isEmpty else { return nil }
            let id = raw.hostPatterns.joined(separator: ",")
            let port = raw.directives["port"].flatMap(Int.init)
            return SSHConfigEntry(
                id: id,
                hostPatterns: raw.hostPatterns,
                hostName: raw.directives["hostname"],
                user: raw.directives["user"],
                port: port,
                identityFile: raw.directives["identityfile"].map(expandTildeInPath(_:)),
                preferredAuthentications: raw.directives["preferredauthentications"],
                identitiesOnly: raw.booleanDirectives["identitiesonly"],
                sourcePath: raw.sourcePath
            )
        }
    }

    /// Splits a config line into tokens, respecting single and double quotes.
    private static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for character in line {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func booleanValue(for keyword: String, tokens: [String]) -> Bool? {
        guard SSHBooleanDirective(rawValue: keyword) != nil else { return nil }
        return SSHBooleanDirective.parse(tokens.first ?? "")
    }

    private static func expandTildeInPath(_ path: String) -> String {
        return (path as NSString).expandingTildeInPath
    }

    private static func expandPath(_ pattern: String, homeDirectory: String) -> String {
        return (pattern as NSString).expandingTildeInPath
    }

    private static func expandGlob(pattern: String) -> [String] {
        let fileManager = Foundation.FileManager()
        if pattern.contains("*") || pattern.contains("?") || pattern.contains("[") {
            let directory = URL(fileURLWithPath: pattern).deletingLastPathComponent().path
            let name = URL(fileURLWithPath: pattern).lastPathComponent
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }
            let matcher = globToRegex(name)
            return contents
                .filter { contentsEntry in
                    matcher?.firstMatch(in: contentsEntry, range: NSRange(location: 0, length: contentsEntry.utf16.count)) != nil
                }
                .map { "\(directory)/\($0)" }
        }
        return fileManager.fileExists(atPath: pattern) ? [pattern] : []
    }

    private static func globToRegex(_ glob: String) -> NSRegularExpression? {
        var pattern = "^"
        for character in glob {
            switch character {
            case "*": pattern += ".*"
            case "?": pattern += "."
            case "[": pattern += "["
            case "]": pattern += "]"
            case ".", "+", "(", ")", "|", "^", "$", "{", "}", "\\":
                pattern += "\\\(character)"
            default:
                pattern += String(character)
            }
        }
        pattern += "$"
        return try? NSRegularExpression(pattern: pattern, options: [])
    }

    private static func isWildcardPattern(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?")
    }
}

/// Keywords in `ssh_config(5)` that take a yes/no value.
private enum SSHBooleanDirective: String {
    case batchMode
    case canonicalizeFallbackLocal
    case challengeResponseAuthentication
    case compression
    case forwardAgent
    case forwardX11
    case gatewayPorts
    case gssApiAuthentication
    case gssApiDelegateCredentials
    case hashKnownHosts
    case hostbasedAuthentication
    case identitiesOnly
    case kbdInteractiveAuthentication
    case noHostAuthenticationForLocalhost
    case passwordAuthentication
    case pubkeyAuthentication

    case requestTTY
    case rsaAuthentication
    case tcpKeepAlive
    case useKeychain

    static func parse(_ token: String) -> Bool? {
        switch token.lowercased() {
        case "yes", "true": return true
        case "no", "false": return false
        default: return nil
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "batchmode": self = .batchMode
        case "canonicalizefallbacklocal": self = .canonicalizeFallbackLocal
        case "challengeresponseauthentication": self = .challengeResponseAuthentication
        case "compression": self = .compression
        case "forwardagent": self = .forwardAgent
        case "forwardx11": self = .forwardX11
        case "gatewayports": self = .gatewayPorts
        case "gssapiauthentication": self = .gssApiAuthentication
        case "gssapidelegatecredentials": self = .gssApiDelegateCredentials
        case "hashknownhosts": self = .hashKnownHosts
        case "hostbasedauthentication": self = .hostbasedAuthentication
        case "identitiesonly": self = .identitiesOnly
        case "kbdinteractiveauthentication": self = .kbdInteractiveAuthentication
        case "nohostauthenticationforlocalhost": self = .noHostAuthenticationForLocalhost
        case "passwordauthentication": self = .passwordAuthentication
        case "pubkeyauthentication": self = .pubkeyAuthentication
        case "requesttty": self = .requestTTY
        case "rsaauthentication": self = .rsaAuthentication
        case "tcpkeepalive": self = .tcpKeepAlive
        case "usekeychain": self = .useKeychain
        default: return nil
        }
    }
}
