import Foundation

/// Sanitizes filenames used in `multipart/form-data` `Content-Disposition`
/// headers, where the `filename` parameter is parsed by HTTP servers
/// with varying degrees of strictness.
///
/// The pre-hardening implementations in `RemoteDaemonClient` and
/// `GroqTranscriptionClient` used a small blacklist that replaced
/// backslashes, double quotes, CR, and LF with safe characters. That
/// left a long tail of risky characters (semicolons, control bytes,
/// non-ASCII scalars, line separators, and so on) untouched, which
/// could confuse multipart parsers, smuggle headers, or break servers
/// that treat the value as a `quoted-string` literal.
///
/// This helper uses a strict whitelist instead: the only characters
/// allowed in the sanitized filename are ASCII alphanumerics, dot,
/// hyphen, underscore, and a single space. Anything else is replaced
/// with an underscore, the result is trimmed, and a non-empty fallback
/// is returned if the input would otherwise be empty.
///
/// The helper never throws. Callers can use the result directly in
/// the `filename="…"` parameter of a `Content-Disposition` header.
enum MultipartFilenameSanitizer {
    /// The default placeholder used when the sanitized result would
    /// otherwise be empty. Callers can override per-call if they have
    /// a more meaningful fallback (e.g. an attachment UUID).
    static let defaultPlaceholder = "upload"

    /// Returns a safe version of `name` suitable for embedding in a
    /// `Content-Disposition: form-data; name="file"; filename="…"`
    /// header. Every character outside the whitelist is replaced with
    /// an underscore; the result is trimmed of leading and trailing
    /// whitespace; and an empty result is replaced with `placeholder`.
    static func sanitize(_ name: String, placeholder: String = defaultPlaceholder) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._- "))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let joined = String(scalars)
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? placeholder : trimmed
    }
}
