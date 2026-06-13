import Foundation

struct TerminalProcessRequest: Hashable {
    let executable: String
    let arguments: [String]
    let environment: [String]
    let workingDirectory: String?
    let execName: String?
}
