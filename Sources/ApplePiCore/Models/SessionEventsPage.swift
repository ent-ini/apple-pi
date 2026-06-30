import Foundation

package struct SessionEventsPage: Sendable {
    package let events: [SessionEvent]
    package let firstLine: Int?
    package let lastLine: Int?
    package let hasMoreBefore: Bool
    package let hasMoreAfter: Bool

    package init(
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

    package static func fromEvents(_ events: [SessionEvent]) -> SessionEventsPage {
        SessionEventsPage(
            events: events,
            firstLine: events.first?.lineIndex,
            lastLine: events.last?.lineIndex,
            hasMoreBefore: false,
            hasMoreAfter: false
        )
    }
}
