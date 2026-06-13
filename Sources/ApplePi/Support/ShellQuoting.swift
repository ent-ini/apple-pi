import Foundation

extension String {
    var shellQuoted: String {
        if isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-./:=@")
        if unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return self
        }
        return "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
