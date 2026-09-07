import Foundation

struct CalendarLaunchSnapshot: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let day: Date
        let clipCount: Int
        let thumbData: Data?
        let rotationDegrees: Double
    }

    let projectID: UUID
    let generatedAt: Date
    let monthCount: Int
    let entries: [Entry]
}

@MainActor
final class CalendarLaunchSnapshotStore: ObservableObject {
    @Published private(set) var current: CalendarLaunchSnapshot?

    private var pendingRefreshTask: Task<Void, Never>?

    init() {
        current = Self.loadSnapshotMatchingLastOpenedProject()
    }

    func snapshot(for projectID: UUID) -> CalendarLaunchSnapshot? {
        guard current?.projectID == projectID else { return nil }
        return current
    }

    func entry(forDayKey day: Date, projectID: UUID) -> CalendarLaunchSnapshot.Entry? {
        guard let snapshot = snapshot(for: projectID) else { return nil }
        return snapshot.entries.first { $0.day == day }
    }

    func scheduleRefresh(from store: ClipStore, project: Project, monthCount: Int = 3) {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshIfPossible(from: store, project: project, monthCount: monthCount)
        }
    }

    func refreshIfPossible(from store: ClipStore, project: Project, monthCount: Int = 3) {
        guard store.isLoaded else { return }
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        let snapshot = Self.buildSnapshot(from: store, project: project, monthCount: monthCount)
        current = snapshot
        persist(snapshot)
    }

    func refreshLastOpenedProjectIfPossible(projectStore: ProjectStore, clipStore: ClipStore, monthCount: Int = 3) {
        guard
            clipStore.isLoaded,
            let saved = UserDefaults.standard.string(forKey: "lastOpenedProjectID"),
            let id = UUID(uuidString: saved),
            let project = projectStore.project(withID: id),
            project.type != .collections
        else { return }

        refreshIfPossible(from: clipStore, project: project, monthCount: monthCount)
    }

    private func persist(_ snapshot: CalendarLaunchSnapshot?) {
        let url = Self.snapshotURL

        Task.detached(priority: .utility) {
            let fm = FileManager.default

            if let snapshot {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                let dir = url.deletingLastPathComponent()
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            } else if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
    }

    private static func buildSnapshot(from store: ClipStore, project: Project, monthCount: Int) -> CalendarLaunchSnapshot {
        let calendar = Calendar.current
        let today = store.dayKey(Date())
        let currentMonthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: today)
        ) ?? today
        let earliestMonthStart = calendar.date(byAdding: .month, value: -(monthCount - 1), to: currentMonthStart) ?? currentMonthStart
        let nextMonthStart = calendar.date(byAdding: .month, value: 1, to: currentMonthStart) ?? today

        let counts = store.countByProjectDay[project.id] ?? [:]
        let thumbs = store.thumbByProjectDay[project.id] ?? [:]

        let relevantDays = Set(counts.keys.filter { $0 >= earliestMonthStart && $0 < nextMonthStart && $0 <= today })
            .union(thumbs.keys.filter { $0 >= earliestMonthStart && $0 < nextMonthStart && $0 <= today })
            .sorted()

        let entries = relevantDays.map { day in
            CalendarLaunchSnapshot.Entry(
                day: day,
                clipCount: counts[day] ?? 0,
                thumbData: thumbs[day],
                rotationDegrees: store.firstClipRotation(forDayKey: day, project: project)
            )
        }

        return CalendarLaunchSnapshot(
            projectID: project.id,
            generatedAt: Date(),
            monthCount: monthCount,
            entries: entries
        )
    }

    private static func loadSnapshotMatchingLastOpenedProject() -> CalendarLaunchSnapshot? {
        guard
            let saved = UserDefaults.standard.string(forKey: "lastOpenedProjectID"),
            let id = UUID(uuidString: saved),
            let data = try? Data(contentsOf: snapshotURL),
            let snapshot = try? JSONDecoder().decode(CalendarLaunchSnapshot.self, from: data),
            snapshot.projectID == id
        else { return nil }

        return snapshot
    }

    private static var snapshotURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("LaunchSnapshots", isDirectory: true)
            .appendingPathComponent("calendar-last-opened.json")
    }
}
