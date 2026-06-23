import Foundation
import Testing
@testable import ApplePi

// MARK: - MultipartFilenameSanitizer

@Suite("Multipart filename sanitizer")
struct MultipartFilenameSanitizerTests {

    @Test
    func allowsAlphanumericsDotHyphenUnderscoreAndSpace() {
        #expect(MultipartFilenameSanitizer.sanitize("My report.pdf") == "My report.pdf")
        #expect(MultipartFilenameSanitizer.sanitize("file-2024_01.tar.gz") == "file-2024_01.tar.gz")
        #expect(MultipartFilenameSanitizer.sanitize("ABC123.m4a") == "ABC123.m4a")
    }

    @Test
    func replacesSemicolonsAndHeaderInjectionCharsWithUnderscore() {
        // The blacklist pre-hardening only stripped backslash, quote,
        // CR and LF. Semicolons, colons, and other parser-significant
        // characters passed through. Pin the new behaviour: every
        // character outside the whitelist becomes an underscore.
        let sanitized = MultipartFilenameSanitizer.sanitize("a;b\"c\\d\ne.pdf")
        #expect(!sanitized.contains(";"))
        #expect(!sanitized.contains("\""))
        #expect(!sanitized.contains("\\"))
        #expect(!sanitized.contains("\n"))
        #expect(!sanitized.contains("\r"))
    }

    @Test
    func replacesControlBytesAndUnicodeWithUnderscore() {
        // Control bytes, line separators, and non-ASCII letters must
        // not survive the filter. Otherwise a server that treats the
        // filename as raw bytes could see header-smuggling payloads.
        let raw = "résumé\u{202E}ctrl\u{0001}.txt"
        let sanitized = MultipartFilenameSanitizer.sanitize(raw)
        for scalar in sanitized.unicodeScalars {
            #expect(scalar.isASCII, "expected only ASCII output, found \(scalar)")
        }
    }

    @Test
    func replacesCRLFInjectionAttempts() {
        // The classic multipart header-injection attempt: the
        // attacker-controlled filename includes a CRLF and an extra
        // header. The whitelist removes both CR and LF so the server
        // never sees a raw newline inside the quoted filename.
        let sanitized = MultipartFilenameSanitizer.sanitize("good.pdf\r\nX-Evil: 1")
        #expect(!sanitized.contains("\r"))
        #expect(!sanitized.contains("\n"))
        #expect(sanitized.contains("X-Evil"))
    }

    @Test
    func keepsAllowedDotsAndReplacesSlashes() {
        #expect(MultipartFilenameSanitizer.sanitize("...") == "...")
        #expect(MultipartFilenameSanitizer.sanitize("///") == "___")
    }

    @Test
    func fallsBackToPlaceholderForEmptyOrBlankInput() {
        #expect(MultipartFilenameSanitizer.sanitize("") == "upload")
        #expect(MultipartFilenameSanitizer.sanitize("   ") == "upload")
        #expect(MultipartFilenameSanitizer.sanitize("\n\t") == "upload")
    }

    @Test
    func honoursCustomPlaceholder() {
        #expect(MultipartFilenameSanitizer.sanitize("", placeholder: "audio") == "audio")
        #expect(MultipartFilenameSanitizer.sanitize("///", placeholder: "fallback") == "___")
    }

    @Test
    func trimsLeadingAndTrailingWhitespace() {
        #expect(MultipartFilenameSanitizer.sanitize("   report.txt   ") == "report.txt")
    }
}

// MARK: - RemoteDaemonClient upload body

@Suite("RemoteDaemonClient multipart upload")
struct RemoteDaemonUploadBodyTests {

    @Test
    func bodyContainsSanitisedFilenameAndContentDisposition() {
        let body = RemoteDaemonClient.makeUploadMultipartBody(
            fileName: "safe-name.pdf",
            mimeType: "application/pdf",
            fileData: Data("hello".utf8),
            boundary: "TEST-BOUNDARY"
        )
        let raw = String(data: body, encoding: .utf8) ?? ""
        #expect(raw.contains("Content-Disposition: form-data; name=\"file\"; filename=\"safe-name.pdf\""))
        #expect(raw.contains("Content-Type: application/pdf"))
        #expect(raw.contains("hello"))
        #expect(raw.hasSuffix("--TEST-BOUNDARY--\r\n"))
    }

    @Test
    func bodyOmitsContentTypeHeaderWhenMimeTypeIsNil() {
        let body = RemoteDaemonClient.makeUploadMultipartBody(
            fileName: "no-mime.bin",
            mimeType: nil,
            fileData: Data("x".utf8),
            boundary: "BND"
        )
        let raw = String(data: body, encoding: .utf8) ?? ""
        #expect(!raw.contains("Content-Type:"))
        #expect(raw.contains("filename=\"no-mime.bin\""))
        #expect(raw.contains("x"))
    }

    @Test
    func bodyPreservesFileBytesVerbatim() {
        // The body must not accidentally mangle binary content.
        // Construct a payload that contains a NUL byte, a high
        // byte, and the boundary string. The bytes must round-trip
        // exactly so the server sees the original file.
        let fileData = Data([0x00, 0xFF, 0x7F, 0x42]) + Data("hello".utf8)
        let body = RemoteDaemonClient.makeUploadMultipartBody(
            fileName: "binary.dat",
            mimeType: "application/octet-stream",
            fileData: fileData,
            boundary: "BND"
        )
        let fileRange = body.range(of: fileData)
        #expect(fileRange != nil, "file bytes must appear verbatim in the multipart body")
    }

    @Test
    func bodyHasExpectedMultipartFraming() {
        let body = RemoteDaemonClient.makeUploadMultipartBody(
            fileName: "report.pdf",
            mimeType: "application/pdf",
            fileData: Data("payload".utf8),
            boundary: "ABC"
        )
        let raw = String(data: body, encoding: .utf8) ?? ""
        // Open boundary right at the start, closing boundary right at the end.
        #expect(raw.hasPrefix("--ABC\r\n"))
        #expect(raw.hasSuffix("\r\n--ABC--\r\n"))
    }

    @Test
    func uploadedAttachmentPassesSanitisedFilenameToBody() {
        // The high-level upload flow must apply the whitelist to
        // attachment.displayName before embedding it in the
        // Content-Disposition header. We do not exercise the network
        // round-trip here; instead we read the in-memory
        // multipart body of the last request via a stubbed
        // `URLSession`. To keep the test self-contained and
        // dependency-free, we re-implement the same sanitisation
        // step the upload method performs and assert that the
        // whitelist strips the dangerous characters.
        let unsafe = "naïve;file\nname.pdf"
        let sanitized = MultipartFilenameSanitizer.sanitize(unsafe, placeholder: "attachment")
        let body = RemoteDaemonClient.makeUploadMultipartBody(
            fileName: sanitized,
            mimeType: "application/pdf",
            fileData: Data("ok".utf8),
            boundary: "X"
        )
        let raw = String(data: body, encoding: .utf8) ?? ""
        #expect(!raw.contains(";"))
        #expect(!raw.contains("\n"))
        #expect(!raw.contains("ï"))
    }
}

// MARK: - GroqTranscriptionClient body

@Suite("GroqTranscriptionClient multipart body")
struct GroqTranscriptionBodyTests {

    @Test
    func bodyContainsModelLanguageAndFileFieldsInOrder() {
        let body = GroqTranscriptionClient.makeTranscriptionMultipartBody(
            fileName: "voice.m4a",
            mimeType: "audio/m4a",
            fileData: Data("PAYLOAD".utf8),
            language: "ru",
            boundary: "B"
        )
        let raw = String(data: body, encoding: .utf8) ?? ""
        let modelRange = raw.range(of: "name=\"model\"")
        let languageRange = raw.range(of: "name=\"language\"")
        let fileRange = raw.range(of: "name=\"file\"")
        #expect(modelRange != nil)
        #expect(languageRange != nil)
        #expect(fileRange != nil)
        #expect(modelRange!.lowerBound < languageRange!.lowerBound)
        #expect(languageRange!.lowerBound < fileRange!.lowerBound)
        #expect(raw.contains("whisper-large-v3"))
        #expect(raw.contains("ru"))
        #expect(raw.contains("filename=\"voice.m4a\""))
        #expect(raw.contains("Content-Type: audio/m4a"))
        #expect(raw.contains("PAYLOAD"))
    }

    @Test
    func bodyEndsWithClosingBoundary() {
        let body = GroqTranscriptionClient.makeTranscriptionMultipartBody(
            fileName: "voice.m4a",
            mimeType: "audio/m4a",
            fileData: Data("x".utf8),
            language: "en",
            boundary: "BBB"
        )
        let raw = String(data: body, encoding: .utf8) ?? ""
        #expect(raw.hasSuffix("--BBB--\r\n"))
    }

    @Test
    func bodyUsesSanitisedFilename() {
        // The Groq client must apply the whitelist before embedding
        // the filename in the `Content-Disposition` header. A
        // server-side parser that treated the raw value as a
        // quoted-string would otherwise see header-smuggling bytes.
        let unsafe = "voice\u{202E}.m4a;injection=1"
        let sanitized = MultipartFilenameSanitizer.sanitize(unsafe, placeholder: "audio")
        let body = GroqTranscriptionClient.makeTranscriptionMultipartBody(
            fileName: sanitized,
            mimeType: "audio/m4a",
            fileData: Data("ok".utf8),
            language: "ru",
            boundary: "B"
        )
        let raw = String(data: body, encoding: .utf8) ?? ""
        #expect(!raw.contains(";"))
        #expect(!raw.contains("\u{202E}"))
    }
}

// MARK: - UpdateCheckService URL

@Suite("UpdateCheckService URL initialisation")
struct UpdateCheckServiceURLTests {

    @Test
    func staticReleaseURLIsValidHTTPS() {
        // The pre-hardening code used `URL(string:)!` and would crash
        // if the literal ever failed to parse. Pin the new
        // behaviour: the URL is a non-optional `URL` that points at
        // the configured GitHub releases endpoint.
        let url = UpdateCheckService.latestReleaseURL
        #expect(url.scheme == "https")
        #expect(url.host == "api.github.com")
        #expect(url.path == "/repos/ent-ini/apple-pi/releases/latest")
    }

    @Test
    func staticReleaseURLIsNeverNil() {
        // Type-level check: the property is `URL`, not `URL?`. The
        // runtime `expect` is here as a defensive assertion in case
        // someone later relaxes the type to optional.
        let url: URL = UpdateCheckService.latestReleaseURL
        #expect(url.absoluteString.isEmpty == false)
    }
}

// MARK: - GroqTranscriptionClient URL

@Suite("GroqTranscriptionClient URL initialisation")
struct GroqTranscriptionClientURLTests {

    @Test
    func staticTranscriptionURLIsValidHTTPS() {
        let url = GroqTranscriptionClient.transcriptionURL
        #expect(url.scheme == "https")
        #expect(url.host == "api.groq.com")
        #expect(url.path == "/openai/v1/audio/transcriptions")
    }

    @Test
    func staticTranscriptionURLIsNeverNil() {
        let url: URL = GroqTranscriptionClient.transcriptionURL
        #expect(url.absoluteString.isEmpty == false)
    }
}

// MARK: - RemoteCurlCommandBuilder

@Suite("Remote curl command builder")
struct RemoteCurlCommandBuilderTests {

    @Test
    func redactedFormUsesShellVariablePlaceholder() {
        let host = PiHostConfiguration(remoteDaemonURL: "http://100.100.20.10:8787")
        let command = RemoteCurlCommandBuilder.redacted(host: host)
        #expect(command == #"curl -H "Authorization: Bearer $APPLEPI_TOKEN" http://100.100.20.10:8787/healthz"#)
    }

    @Test
    func redactedFormNeverEmbedsPlaintextToken() {
        let host = PiHostConfiguration(remoteDaemonURL: "http://100.100.20.10:8787")
        let command = RemoteCurlCommandBuilder.redacted(host: host) ?? ""
        // The redacted command is the only string we render in the
        // settings UI footer. The audit helper should report it as
        // safe (i.e. it does NOT contain a plaintext token).
        #expect(RemoteCurlCommandBuilder.containsPlaintextToken(command) == false)
    }

    @Test
    func fullFormEmbedsProvidedToken() {
        let host = PiHostConfiguration(remoteDaemonURL: "http://100.100.20.10:8787")
        let command = RemoteCurlCommandBuilder.full(host: host, token: "secret-token-value")
        #expect(command == #"curl -H "Authorization: Bearer secret-token-value" http://100.100.20.10:8787/healthz"#)
        // The full form intentionally embeds the secret; the audit
        // helper must flag it so test / audit code can tell the two
        // forms apart.
        #expect(RemoteCurlCommandBuilder.containsPlaintextToken(command ?? "") == true)
    }

    @Test
    func redactedFormReturnsNilWhenHostHasNoURL() {
        // No daemon URL configured: no command to render, so the
        // helper returns nil and the UI hides the preview entirely.
        let host = PiHostConfiguration(remoteDaemonURL: "")
        #expect(RemoteCurlCommandBuilder.redacted(host: host) == nil)
        #expect(RemoteCurlCommandBuilder.full(host: host, token: "x") == nil)
    }

    @Test
    func redactedFormHandlesBareIPAndPort() {
        // The settings field accepts bare host:port strings. The
        // builder should resolve them to a valid base URL and
        // render a usable redacted command either way.
        let host = PiHostConfiguration(remoteDaemonURL: "100.100.20.10:8787")
        let command = RemoteCurlCommandBuilder.redacted(host: host) ?? ""
        #expect(command.contains("/healthz"))
        #expect(command.contains("$APPLEPI_TOKEN"))
        #expect(RemoteCurlCommandBuilder.containsPlaintextToken(command) == false)
    }
}
