import Foundation

/// One Server-Sent Event frame as delivered by the daemon. Apple Pi only
/// needs the event name and the joined data payload — the catalog stream
/// is fire-and-forget: each snapshot replaces the previous one and we
/// never replay missed events.
struct SSECatalogEvent: Sendable {
    let event: String
    let data: String
}

/// Line-oriented parser for Server-Sent Events. Implements the slice of
/// the WHATWG SSE spec the daemon's `/sessions/stream` endpoint relies on:
///
/// * `event: <name>` sets the current event name (default `message`).
/// * `data: <text>` lines are accumulated; consecutive `data:` lines are
///   joined with `\n`, matching the spec.
/// * Lines starting with `:` are comments and ignored (the daemon uses
///   them as keep-alives).
/// * A blank line dispatches the buffered event, or is a no-op when no
///   data was collected.
/// * Unknown fields and the `id:` / `retry:` hints are intentionally
///   dropped — Apple Pi owns its own reconnect cadence via the consumer's
///   backoff loop.
///
/// Malformed frames are dropped, not fatal. A single bad event from the
/// daemon must never tear down the live subscription.
final class SSECatalogEventParser {
    private var currentEvent: String = "message"
    private var currentDataBuffer: [String] = []

    func feed(_ rawLine: String) -> SSECatalogEvent? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

        // Empty / blank line terminates the current event.
        if line.isEmpty {
            return dispatch()
        }

        // Comment / keep-alive line (per spec, lines starting with ":").
        if line.first == ":" {
            return nil
        }

        // Field name + ": " + value. The single leading space is optional
        // per the spec, and a line with no colon is treated as
        // `<field>:` with an empty value.
        let field: String
        let value: String
        if let colonIndex = line.firstIndex(of: ":") {
            field = String(line[..<colonIndex])
            var valueStart = line.index(after: colonIndex)
            if valueStart < line.endIndex, line[valueStart] == " " {
                valueStart = line.index(after: valueStart)
            }
            value = String(line[valueStart...])
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event":
            currentEvent = value.isEmpty ? "message" : value
        case "data":
            currentDataBuffer.append(value)
        case "id", "retry":
            // Server-side replay hints aren't used; we reconnect from
            // scratch on every (re)connect and the consumer handles
            // backoff.
            break
        default:
            break
        }
        return nil
    }

    private func dispatch() -> SSECatalogEvent? {
        defer {
            currentEvent = "message"
            currentDataBuffer.removeAll(keepingCapacity: true)
        }
        guard !currentDataBuffer.isEmpty else { return nil }
        return SSECatalogEvent(
            event: currentEvent,
            data: currentDataBuffer.joined(separator: "\n")
        )
    }
}
