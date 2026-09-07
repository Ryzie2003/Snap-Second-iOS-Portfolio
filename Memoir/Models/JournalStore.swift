import Foundation
import Combine

/// Simple persistence for day-level journal text (per project).
/// This is intentionally lightweight so it plugs into your existing infra immediately.
final class JournalStore: ObservableObject {
    static let shared = JournalStore()
    private init() {}

    @Published private(set) var revision = 0  // bump to refresh views if needed

    private let defaults = UserDefaults.standard
    private let cal = Calendar.current

    private func key(projectID: UUID, date: Date) -> String {
        let day = cal.startOfDay(for: date).timeIntervalSince1970
        return "com.memoir.journal.\(projectID.uuidString).\(Int(day))"
    }

    func text(projectID: UUID, date: Date) -> String {
        defaults.string(forKey: key(projectID: projectID, date: date)) ?? ""
    }

    func setText(_ text: String, projectID: UUID, date: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = key(projectID: projectID, date: date)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: k)
        } else {
            defaults.set(trimmed, forKey: k)
        }
        revision &+= 1
        objectWillChange.send()
    }

    func hasEntry(projectID: UUID, date: Date) -> Bool {
        !text(projectID: projectID, date: date).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
