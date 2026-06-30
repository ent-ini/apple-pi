import Foundation

public struct SessionEventsPage: Sendable {
    public let events: [SessionEvent]
    public let firstLine: Int?
    public let lastLine: Int?
    public let hasMoreBefore: Bool
    public let hasMoreAfter: Bool

    public init(
        events: [SessionEvent],
        firstLine: Int?,
        lastLine: Int?,
        hasMoreBefore: Bool,
        hasMoreAfter: Bool
    ) {
        self.events = events
        self.firstLine = firstLine
        self.lastLine = lastLine
        self.hasMoreBefore = hasMoreBefore
        self.hasMoreAfter = hasMoreAfter
    }

    public static func fromEvents(_ events: [SessionEvent]) -> SessionEventsPage {
        SessionEventsPage(
            events: events,
            firstLine: events.first?.lineIndex,
            lastLine: events.last?.lineIndex,
            hasMoreBefore: false,
            hasMoreAfter: false
        )
    }
}
