import Foundation

@MainActor
func registerBackupEnumerator(projectStore: ProjectStore, clipStore: ClipStore) {
    CloudBackupService.shared.registerEnumerator { [weak projectStore, weak clipStore] in
        guard let projectStore, let clipStore else { return [] }

        var out: [CloudBackupService.UnhashedLocalClip] = []
        let start = Date.distantPast
        let end   = Date.distantFuture

        for project in projectStore.projects {
            let clips = clipStore.clips(from: start, to: end, in: project)
            for c in clips {
                // Must be a real on-disk URL
                guard let url = clipStore.urlForClip(c) as URL? else { continue }

                // ✅ Clip.id is optional – safely unwrap or synthesize one
                let id        = (c.id ?? UUID()).uuidString

                let created   = c.date ?? Date()
                let journalId = project.id.uuidString
                let ext       = url.pathExtension.lowercased()
                out.append(.init(id: id, fileURL: url, createdAt: created, journalId: journalId, ext: ext))
            }
        }
        // Quick sanity check while testing
        print("[BackupEnumerator] enumerated \(out.count) clips")
        return out
    }
}
