//
//  ProjectStore.swift
//  Memoir
//
//  Created by Ryan Zheng on 7/29/25.
//



import SwiftUI
import CoreData


enum JournalCreationError: LocalizedError {
    case limitReached

    var errorDescription: String? {
        switch self {
        case .limitReached:
            return "The Free plan includes one journal."
        }
    }
}

@MainActor
final class ProjectStore: ObservableObject {

    /// Published list for SwiftUI
    @Published private(set) var projects: [Project] = []

    // MARK: Persistence (JSON in Documents/Projects.json)
    private let url: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask).first!
        return docs.appendingPathComponent("Projects.json")
    }()

    @MainActor
    init() {
        // ✅ Synchronous hydrate so ProjectsView has data on the first frame.
        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode([Project].self, from: data) {
            self.projects = loaded
        } else {
            self.projects = []
        }

        // (Optional) Revalidate on a background queue; no-op if unchanged.
        Task.detached(priority: .utility) { [weak self, url] in
            guard let self = self else { return }
            let fresh: [Project] =
                (try? Data(contentsOf: url))
                .flatMap { try? JSONDecoder().decode([Project].self, from: $0) }
                ?? []
            if await self.projects != fresh {
                await MainActor.run { self.projects = fresh }
            }
        }
    }


    // CRUD -----------------------------------------------------------
    @discardableResult
        func createProject(name: String, entitlements: Entitlements, type: ProjectType = .dailyJournal) throws -> Project {
//            // Centralized, non-bypassable gate
//            let gate = ProAccessManager.canUse(
//                .multipleJournals,
//                entitlements: entitlements,
//                contextCount: projects.count
//            )
//            guard gate.allowed else { throw JournalCreationError.limitReached }
//
//            // Reuse your existing helper
            return add(name: name, type: type)
        }

    func add(name: String, type: ProjectType = .dailyJournal) -> Project {
        let project = Project(name: name, type: type)
        projects.append(project)
        save()
        Task { await CloudBackupService.shared.syncActiveJournalSnapshotIfNeeded() }
        return project
    }

    @discardableResult
    func ensureOnboardingDefaultProject(named name: String = "My First Project") -> (project: Project, created: Bool) {
        if let savedID = UserDefaults.standard.string(forKey: "lastOpenedProjectID"),
           let uuid = UUID(uuidString: savedID),
           let savedProject = projects.first(where: { $0.id == uuid }) {
            return (savedProject, false)
        }

        if let existing = projects.sorted(by: { $0.created < $1.created }).first {
            UserDefaults.standard.set(existing.id.uuidString, forKey: "lastOpenedProjectID")
            return (existing, false)
        }

        let project = add(name: name, type: .dailyJournal)
        UserDefaults.standard.set(project.id.uuidString, forKey: "lastOpenedProjectID")
        return (project, true)
    }

    func delete(at offsets: IndexSet) {
        projects.remove(atOffsets: offsets)
        save()
        Task { await CloudBackupService.shared.syncActiveJournalSnapshotIfNeeded() }
    }

    func delete(ids: Set<UUID>) {
        print("🔸 clip count BEFORE", ClipStore.shared.clips.count)

        ClipStore.shared.delete(projectIDs: ids)

        projects.removeAll { ids.contains($0.id) }
        save()
        Task { await CloudBackupService.shared.syncActiveJournalSnapshotIfNeeded() }

        print("🔸 clip count AFTER ", ClipStore.shared.clips.count)
    }

    func rename(id: Project.ID, to newName: String) {
            guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
            projects[i].name = newName
            // Reassign to trigger @Published and any SwiftUI views bound to it
            projects = projects
            save()
            Task { await CloudBackupService.shared.syncActiveJournalSnapshotIfNeeded() }
        }

    /// Get a project by ID
    func project(withID id: UUID) -> Project? {
        projects.first(where: { $0.id == id })
    }

    // MARK: JSON helpers
    private func load() { /* no-op; loaded in init() via detached task */ }

    private func save() {
        let snapshot = projects
        let url = self.url
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Replace the entire journals list (and persist it). Call from restore.
    func replaceAll(with newProjects: [Project]) {
        self.projects = newProjects
        save()
    }

    @discardableResult
    func recoverMissingProjectsFromClips() -> Int {
        let existingIDs = Set(projects.map(\.id))
        let clips = ClipStore.shared.fetchAllClips()

        let orphanBuckets = Dictionary(grouping: clips.compactMap { clip -> (UUID, Clip)? in
            guard let projectID = clip.projectID, !existingIDs.contains(projectID) else { return nil }
            return (projectID, clip)
        }, by: \.0)

        guard !orphanBuckets.isEmpty else { return 0 }

        let recovered = orphanBuckets
            .map { projectID, bucket -> Project in
                let earliestDate =
                    bucket
                    .map(\.1)
                    .compactMap { $0.createdAt ?? $0.date }
                    .min()
                    ?? Date(timeIntervalSince1970: 0)

                return Project(
                    id: projectID,
                    name: "Restored Journal",
                    created: earliestDate,
                    type: .dailyJournal
                )
            }
            .sorted {
                if $0.created != $1.created { return $0.created < $1.created }
                return $0.id.uuidString < $1.id.uuidString
            }
            .enumerated()
            .map { index, project in
                Project(
                    id: project.id,
                    name: "Restored Journal \(index + 1)",
                    created: project.created,
                    type: project.type
                )
            }

        projects.append(contentsOf: recovered)
        save()
        Task { await CloudBackupService.shared.syncActiveJournalSnapshotIfNeeded() }
        print("⚠️ Recovered \(recovered.count) orphaned journals from local clips.")
        return recovered.count
    }

}
