import Foundation
import Combine
import EventKit

struct CalendarEventRow: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let isAllDay: Bool
}

@MainActor
final class CalendarManager: ObservableObject {
    @Published var isAuthorized: Bool = false
    @Published var upcoming: [CalendarEventRow] = []

    private let store = EKEventStore()

    func requestAccessAndFetch() {
        let status = EKEventStore.authorizationStatus(for: .event)

        switch status {
        case .authorized:
            isAuthorized = true
            fetchUpcoming()
        case .notDetermined:
            store.requestFullAccessToEvents { [weak self] granted, _ in
                guard let self else { return }
                Task { @MainActor in
                    self.isAuthorized = granted
                    if granted { self.fetchUpcoming() }
                }
            }
        default:
            isAuthorized = false
            upcoming = []
        }
    }

    func fetchUpcoming(days: Int = 7, limit: Int = 8) {
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(7*24*3600)

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted(by: { $0.startDate < $1.startDate })
            .prefix(limit)

        self.upcoming = events.map {
            CalendarEventRow(
                id: $0.eventIdentifier ?? UUID().uuidString,
                title: $0.title ?? "(Sin título)",
                startDate: $0.startDate,
                endDate: $0.endDate,
                location: $0.location,
                isAllDay: $0.isAllDay
            )
        }
    }
}
