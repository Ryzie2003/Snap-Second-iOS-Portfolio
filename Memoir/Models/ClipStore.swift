
//
//  ClipStore.swift  — Optimized
//  Snap Second
//
//  Notes:
//  - Incremental in-memory updates (no full reloads after each mutation)
//  - O(1) indices for day/project counts to keep views fast
//  - Background fetch + single publish at startup
//  - Binary-search insertion to maintain sorted order (date, createdAt)
//

import Foundation
import CoreData
import UIKit
import AVFoundation

// MARK: - ClipMediaType

/// Represents the original source type of a clip before conversion to video
enum ClipMediaType: Int16 {
    case video = 0
    case livePhoto = 1
    case photo = 2
}

// MARK: - ClipStore

@MainActor
final class ClipStore: ObservableObject {

    static let shared = ClipStore()


    // Core Data stack
    let container: NSPersistentContainer
    var context: NSManagedObjectContext { container.viewContext }

    // Primary model exposed to views (kept sorted by date, then createdAt)
    @Published var clips: [Clip] = []
    @Published private(set) var isLoaded = false

    // Fast, view-friendly indices
    @Published private(set) var countByProject: [UUID: Int] = [:]     // projectID → count
    @Published private(set) var countByDay: [Date: Int] = [:]         // startOfDay → count

    // Background queue for disk/encoding work
    private let io = DispatchQueue(label: "ClipStore.IO", qos: .userInitiated)
    private var loadTask: Task<Void, Never>?

    // Directory in Documents/Clips where we persist media files
    lazy var clipsDirectory: URL = {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir  = docs.appendingPathComponent("Clips", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    // Tracks one in-flight orphan cleanup per (project, month). Main-actor only.
    @MainActor
    var pendingOrphanJobs = Set<PendingCleanupKey>()

    @MainActor
    struct PendingCleanupKey: Hashable {
        let projectID: UUID
        let monthStart: Date  // normalized to first of month (00:00)
    }

    // Fast per-project/per-day count and a sample thumb
    @Published private(set) var countByProjectDay: [UUID: [Date: Int]] = [:]
    @Published var thumbByProjectDay: [UUID: [Date: Data]] = [:]
    @Published private(set) var rotationByProjectDay: [UUID: [Date: Double]] = [:]

    func dayKey(_ d: Date) -> Date { Calendar.current.startOfDay(for: d) }


    // MARK: Init

    private init() {
        // Note: Keeping "MemoirModel" for backward compatibility with existing user data
        container = NSPersistentContainer(name: "MemoirModel")
        if let description = container.persistentStoreDescriptions.first {
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
        }

        container.loadPersistentStores { _, error in
            if let error { fatalError("Core Data load error: \(error)") }
        }

        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        // Clip hydration is kicked off after the first app frame so launch routing
        // never waits on a full Core Data snapshot.
    }

    // MARK: Public: one-time loader (safe to call from views)

    /// Ensure the store is hydrated exactly once (no-ops if already loaded).
    func loadOnceIfNeeded() {
        guard !isLoaded else { return }
        loadClips()
    }

    /// Await the first full snapshot for callers that need populated clip indices.
    func ensureLoaded() async {
        if isLoaded { return }
        if loadTask == nil {
            loadClips()
        }
        await loadTask?.value
    }

    /// Predecode the thumbnails CalendarView will ask for on its first frame.
    func predecodeInitialCalendarThumbs(for project: Project, monthCount: Int = 3) async {
        let calendar = Calendar.current
        let today = dayKey(Date())
        guard let currentMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: today)
        ) else { return }
        guard let thumbsByDay = thumbByProjectDay[project.id] else { return }

        var items: [(data: Data, key: String)] = []
        for offset in 0..<monthCount {
            guard
                let monthStart = calendar.date(byAdding: .month, value: -offset, to: currentMonth),
                let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart)
            else { continue }

            for (day, data) in thumbsByDay where day >= monthStart && day < nextMonth && day <= today {
                let key = "day-\(project.id.uuidString)-\(day.timeIntervalSince1970)-v\(data.count)"
                items.append((data, key))
            }
        }

        await ThumbCache.shared.predecode(items)
    }

    // MARK: Load (background fetch → single publish)

    /// Fetches every Clip sorted by (date ASC, orderIndex ASC, createdAt ASC),
    /// builds indices, and publishes once.
    private func loadClips() {
        if let loadTask, !loadTask.isCancelled {
            return
        }

        // Fetch on a background context to avoid blocking the main thread
        loadTask = Task { [weak self] in
            guard let self else { return }
            let ids = await Self.fetchSortedClipObjectIDs(in: container)
            guard !Task.isCancelled else { return }

            var resolved: [Clip] = []
            resolved.reserveCapacity(ids.count)
            for oid in ids {
                if let obj = try? self.context.existingObject(with: oid) as? Clip {
                    resolved.append(obj)
                }
            }

            print("📊 [ClipStore] loadClips fetched \(ids.count) clips from Core Data")
            print("📊 [ClipStore] Resolved \(resolved.count) clips for in-memory store")

            // Group by project for debugging
            let byProject = Dictionary(grouping: resolved) { $0.projectID }
            for (projID, clips) in byProject {
                print("  - Project \(projID?.uuidString.prefix(8) ?? "nil"): \(clips.count) clips")
            }

            self.setSnapshot(resolved) // builds indices + publishes
        }
    }

    private static func fetchSortedClipObjectIDs(in container: NSPersistentContainer) async -> [NSManagedObjectID] {
        await withCheckedContinuation { continuation in
            container.performBackgroundTask { bgCtx in
                let req: NSFetchRequest<Clip> = Clip.fetchRequest()
                req.sortDescriptors = [
                    NSSortDescriptor(key: "date",       ascending: true),
                    NSSortDescriptor(key: "orderIndex", ascending: true),
                    NSSortDescriptor(key: "createdAt",  ascending: true)
                ]

                let rows = (try? bgCtx.fetch(req)) ?? []
                continuation.resume(returning: rows.map(\.objectID))
            }
        }
    }


    // Public one-shot refresh for bulk imports (e.g., after restore completes).
    @MainActor
    public func reloadAfterBulkRestore() {
        loadTask?.cancel()
        loadTask = nil
        isLoaded = false
        loadClips()   // private method; re-fetches on a bg context and publishes once
    }

    // Replace entire in-memory snapshot (single publish); keeps arrays sorted and indices built.
    private func setSnapshot(_ newClips: [Clip]) {
        clips = newClips
        rebuildIndices()
        isLoaded = true
    }

    // MARK: Indices

    func rebuildIndices() {
        print("📊 [ClipStore] rebuildIndices() starting with \(clips.count) clips")

        var byProject: [UUID: Int] = [:]
        var byDay: [Date: Int] = [:]
        var byProjDay: [UUID: [Date: Int]] = [:]
        var thumbProjDay: [UUID: [Date: Data]] = [:]
        var rotationProjDay: [UUID: [Date: Double]] = [:]

        for c in clips {
            guard let pid = c.projectID else {
                print("  ⚠️ Clip \(c.id?.uuidString.prefix(8) ?? "nil") has nil projectID")
                continue
            }
            let d = (c.date.map(dayKey)) ?? .distantPast

            byProject[pid, default: 0] += 1
            byDay[d, default: 0] += 1
            byProjDay[pid, default: [:]][d, default: 0] += 1

            // Capture first thumbnail for the day
            if let data = c.thumbnailData {
                var thumbs = thumbProjDay[pid] ?? [:]
                var rotations = rotationProjDay[pid] ?? [:]
                if thumbs[d] == nil {
                    thumbs[d] = data
                    rotations[d] = c.rotationDegrees
                }
                thumbProjDay[pid] = thumbs
                rotationProjDay[pid] = rotations
            }
        }

        countByProject = byProject
        countByDay = byDay
        countByProjectDay = byProjDay
        thumbByProjectDay = thumbProjDay
        rotationByProjectDay = rotationProjDay

        print("📊 [ClipStore] rebuildIndices() complete:")
        for (pid, count) in byProject {
            print("  - Project \(pid.uuidString.prefix(8)): \(count) clips")
        }
    }


    @MainActor private func indexAdd(_ c: Clip) {
        guard let pid = c.projectID else { return }
        let d = c.date.map(dayKey) ?? .distantPast

        countByProject[pid, default: 0] += 1
        countByDay[d, default: 0] += 1

        var map = countByProjectDay[pid] ?? [:]
        map[d, default: 0] += 1
        countByProjectDay[pid] = map

        if let data = c.thumbnailData {
            var thumbs = thumbByProjectDay[pid] ?? [:]
            var rotations = rotationByProjectDay[pid] ?? [:]
            if thumbs[d] == nil {
                thumbs[d] = data
                rotations[d] = c.rotationDegrees
            }
            thumbByProjectDay[pid] = thumbs
            rotationByProjectDay[pid] = rotations
        }
    }

    @MainActor
    func indexRemove(projectID pid: UUID, day d: Date) {
        // ---- per-project/day (existing code) ----
        var byDay = countByProjectDay[pid] ?? [:]
        let remaining = max(0, (byDay[d] ?? 0) - 1)
        if remaining == 0 { byDay.removeValue(forKey: d) } else { byDay[d] = remaining }
        countByProjectDay[pid] = byDay.isEmpty ? nil : byDay

        // thumbs (existing)
        var thumbs = thumbByProjectDay[pid] ?? [:]
        if remaining == 0 {
            thumbs.removeValue(forKey: d)
            thumbByProjectDay[pid] = thumbs.isEmpty ? nil : thumbs
            var rotations = rotationByProjectDay[pid] ?? [:]
            rotations.removeValue(forKey: d)
            rotationByProjectDay[pid] = rotations.isEmpty ? nil : rotations
        } else {
            refreshDayPresentation(projectID: pid, day: d)
        }

        // ---- NEW: project-level decrement ----
        if let current = countByProject[pid] {
            let newVal = max(0, current - 1)
            if newVal == 0 { countByProject.removeValue(forKey: pid) }
            else { countByProject[pid] = newVal }
        }

        // ---- NEW: global per-day decrement ----
        let dayKey = d
        if let currentDay = countByDay[dayKey] {
            let newDayVal = max(0, currentDay - 1)
            if newDayVal == 0 { countByDay.removeValue(forKey: dayKey) }
            else { countByDay[dayKey] = newDayVal }
        }

        // Force-publish nested dict mutations so SwiftUI observes changes
        countByProjectDay = countByProjectDay
        thumbByProjectDay = thumbByProjectDay
        rotationByProjectDay = rotationByProjectDay
        countByProject = countByProject          // ← ensure views (like ProjectsView) refresh
        countByDay = countByDay
    }


    // MARK: - Per-clip caption (text-only)

    @MainActor
    func setCaptionText(_ text: String?, for clip: Clip) {
        guard let ctx = clip.managedObjectContext else { return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        clip.captionText = (trimmed?.isEmpty == false) ? trimmed : nil
        try? ctx.save()
        objectWillChange.send()
    }

    @MainActor
    func clearCaptionText(for clip: Clip) {
        setCaptionText(nil, for: clip)
    }




    @MainActor
    private func refreshDayPresentation(projectID: UUID, day: Date) {
        let firstThumbClip = clips.first(where: {
            $0.projectID == projectID &&
            Calendar.current.startOfDay(for: $0.date ?? .distantPast) == day &&
            $0.thumbnailData != nil
        })

        var thumbs = thumbByProjectDay[projectID] ?? [:]
        var rotations = rotationByProjectDay[projectID] ?? [:]

        if let firstThumbClip, let newData = firstThumbClip.thumbnailData {
            thumbs[day] = newData
            rotations[day] = firstThumbClip.rotationDegrees
        } else {
            thumbs.removeValue(forKey: day)
            rotations.removeValue(forKey: day)
        }

        thumbByProjectDay[projectID] = thumbs.isEmpty ? nil : thumbs
        rotationByProjectDay[projectID] = rotations.isEmpty ? nil : rotations
    }


    // MARK: Sorted insertion / reposition

    /// Binary-search insertion by (date, createdAt) to preserve the sort invariant.
    private func insertionIndex(for clip: Clip) -> Int {
        let dateA   = clip.date ?? .distantPast
        let indexA  = clip.orderIndex
        let createdA = clip.createdAt ?? .distantPast

        var lo = 0
        var hi = clips.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let m = clips[mid]
            let dateB   = m.date ?? .distantPast
            let indexB  = m.orderIndex
            let createdB = m.createdAt ?? .distantPast

            if dateA != dateB {
                if dateA <= dateB { hi = mid } else { lo = mid + 1 }
            } else if indexA != indexB {
                if indexA <= indexB { hi = mid } else { lo = mid + 1 }
            } else {
                if createdA <= createdB { hi = mid } else { lo = mid + 1 }
            }
        }
        return lo
    }

    /// Remove-and-reinsert if the clip's ordering keys changed.
    private func repositionIfNeeded(_ clip: Clip) {
        // Find current index
        guard let idx = clips.firstIndex(where: { $0.objectID == clip.objectID }) else { return }
        // Check neighbors; if still in order, skip the work
        let prevOK: Bool = {
            guard idx > 0 else { return true }
            return compare(clips[idx - 1], clips[idx]) <= 0
        }()
        let nextOK: Bool = {
            guard idx + 1 < clips.count else { return true }
            return compare(clips[idx], clips[idx + 1]) <= 0
        }()
        if prevOK && nextOK { return }

        let item = clips.remove(at: idx)
        let j = insertionIndex(for: item)
        clips.insert(item, at: j)
    }

    /// Lexicographic comparator by (date ASC, then createdAt ASC).
    /// Returns -1 if a<b, 0 if equal, +1 if a>b.
    private func compare(_ a: Clip, _ b: Clip) -> Int {
        let da = a.date ?? .distantPast
        let db = b.date ?? .distantPast
        if da != db { return da < db ? -1 : 1 }

        let ca = a.createdAt ?? .distantPast
        let cb = b.createdAt ?? .distantPast
        if ca == cb { return 0 }
        return ca < cb ? -1 : 1
    }


    // MARK: Queries (unchanged signatues; use indices when possible)

    /// Fast count via index (falls back to Core Data if not yet loaded).
    func clipCount(for date: Date, in project: Project) -> Int {
        let day = dayKey(date)
        return countByProjectDay[project.id]?[day] ?? 0
    }

    /// Looks up a clip by its UUID
    func clip(byID id: UUID) -> Clip? {
        return clips.first { $0.id == id }
    }


    // MARK: Mutations — Incremental (no full reloads)

    func addClip(
        for date: Date,
        project: Project,
        fromURL tmpURL: URL,
        thumb: UIImage,
        duration: TimeInterval,
        isSmartFill: Bool,
        start: Double = 0,
        sourceLocalID: String? = nil,
        rotationDegrees: Double = 0,
        previewFillRaw: String? = nil,
        zoomScale: Double = 1.0,
        panOffset: CGPoint = .zero,
        mediaType: ClipMediaType = .video
    ) {
        // ✅ Validate date is reasonable before proceeding
        guard date <= Date() else {
            print("❌ [ClipStore] Rejecting clip with future date: \(date)")
            return
        }

        // Clips older than 100 years are probably corrupted timestamps
        let hundredYearsAgo = Date(timeIntervalSinceNow: -100 * 365 * 24 * 60 * 60)
        guard date >= hundredYearsAgo else {
            print("❌ [ClipStore] Rejecting clip with ancient date: \(date)")
            return
        }

        let fm = FileManager.default
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let base = df.string(from: date)
        let uniq = String(UUID().uuidString.prefix(8))
        let filename = "\(base)_\(uniq).mp4"
        let destURL  = clipsDirectory.appendingPathComponent(filename)

        do { try fm.copyItem(at: tmpURL, to: destURL) }
        catch {
            print("[ClipStore] addClip copy error:", error); return
        }

        // ✅ Verify file was actually copied before creating database record
        guard fm.fileExists(atPath: destURL.path) else {
            print("❌ [ClipStore] File copy failed - file doesn't exist at destination")
            return
        }

        let clip = Clip(context: context)
        let day = dayKey(date)

        clip.id            = UUID()
        clip.date          = day
        clip.createdAt     = Date()
        clip.projectID     = project.id
        clip.assetURL      = destURL.lastPathComponent
        clip.thumbnailData = squareThumbnail(thumb).pngData()
        clip.duration      = duration
        clip.isSmartFill   = isSmartFill
        clip.snippetStart  = start
        clip.sourceLocalID = sourceLocalID
        clip.rotationDegrees = rotationDegrees  // ✅ Store rotation
        clip.previewFillRaw = previewFillRaw ?? ClipDefaults.orientationRaw
        clip.mediaType = mediaType.rawValue    // ✅ Store original media type

        // ✅ NEW: Store zoom/crop values
        clip.zoomScale = max(1.0, min(3.0, zoomScale))  // Clamp to safe range
        clip.panOffsetX = max(-1.0, min(1.0, panOffset.x))
        clip.panOffsetY = max(-1.0, min(1.0, panOffset.y))

        // NEW: assign orderIndex at the end of the strip for this (project, day)
        let existingForDay = clips.filter { existing in
            guard let pid = existing.projectID, let d = existing.date else { return false }
            return pid == project.id && Calendar.current.startOfDay(for: d) == day
        }
        let nextIndex = (existingForDay.map { Int($0.orderIndex) }.max() ?? -1) + 1
        clip.orderIndex = Int32(nextIndex)

        do {
            try context.save()
            // Incremental in-memory update
            let idx = insertionIndex(for: clip)
            clips.insert(clip, at: idx)
            indexAdd(clip)

            // Track clip added for review prompt
            ReviewManager.shared.recordClipAdded()
        } catch {
            print("[ClipStore] addClip save error:", error)
        }


        CloudBackupService.shared.onLocalClipAdded(
            id: clip.id?.uuidString ?? UUID().uuidString,
            fileURL: urlForClip(clip),
            createdAt: clip.date ?? Date(),
            journalId: project.id.uuidString,
            ext: urlForClip(clip).pathExtension.lowercased()
        )
    }

    @MainActor
    func deleteClip(_ clip: Clip) {
        // 1) Snapshot BEFORE deletion to avoid faults / instance mismatches
        let pid = clip.projectID
        let day = clip.date.map { Calendar.current.startOfDay(for: $0) }

        // 2) Remove file + row
        try? FileManager.default.removeItem(at: urlForClip(clip))
        context.delete(clip)
        CloudBackupService.shared.onLocalClipDeleted(
            id: clip.id?.uuidString ?? "<missing>",
            ext: urlForClip(clip).pathExtension.lowercased()
        )

        do {
            try context.save()

            // 3) Best-effort removal from in-memory snapshot (not required for indexing)
            if let i = clips.firstIndex(where: { $0.objectID == clip.objectID || $0.id == clip.id }) {
                clips.remove(at: i)
            }

            // 4) Update day indices from stable snapshots (ALWAYS)
            if let pid, let day {
                indexRemove(projectID: pid, day: day)
            }
        } catch {
            print("[ClipStore] deleteClip error:", error)
        }
    }



    /// Delete any saved clip for that day (exact start-of-day match).
    func deleteClip(for date: Date, in project: Project) {
        guard let found = clip(for: date, in: project) else { return }
        deleteClip(found)
    }

    /// Replace the file + metadata in place, preserving createdAt and sort.
    func updateClip(_ clip: Clip,
                    withFile newFileURL: URL,
                    thumbnail: UIImage,
                    duration: TimeInterval,
                    snippetStart: Double,
                    sourceLocalID: String? = nil,
                    rotationDegrees: Double? = nil,
                    previewFillRaw: String? = nil,
                    zoomScale: Double? = nil,
                    panOffset: (x: Double, y: Double)? = nil) {
        let fm = FileManager.default
        let dest = urlForClip(clip)
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: newFileURL, to: dest)
        } catch {
            print("[ClipStore] updateClip copy error:", error)
            return
        }

        clip.thumbnailData = squareThumbnail(thumbnail).pngData()
        clip.duration      = duration
        clip.snippetStart  = snippetStart
        if let sourceLocalID { clip.sourceLocalID = sourceLocalID }
        if let rotationDegrees { clip.rotationDegrees = rotationDegrees }  // ✅ Update rotation if provided
        if let previewFillRaw { clip.previewFillRaw = previewFillRaw }
        if let zoomScale { clip.zoomScale = zoomScale }  // ✅ Update zoom if provided
        if let panOffset {  // ✅ Update pan offset if provided
            clip.panOffsetX = panOffset.x
            clip.panOffsetY = panOffset.y
        }

        do {
            try context.save()
            repositionIfNeeded(clip)
            if let pid = clip.projectID, let day = clip.date.map(dayKey) {
                refreshDayPresentation(projectID: pid, day: day)
            }
        } catch {
            print("[ClipStore] updateClip save error:", error)
        }
    }

    // MARK: - Move Clip

    /// Move a saved clip to a different day, updating indices and file naming.
    @MainActor
    func moveClip(_ clip: Clip, to newDate: Date) {
        guard let pid = clip.projectID else { return }

        let targetDay = dayKey(newDate)
        let oldDay = clip.date.map(dayKey) ?? targetDay
        guard oldDay != targetDay else { return }

        // Validate date is reasonable before proceeding
        guard newDate <= Date() else {
            print("❌ [ClipStore] Rejecting move to future date: \(newDate)")
            return
        }
        let hundredYearsAgo = Date(timeIntervalSinceNow: -100 * 365 * 24 * 60 * 60)
        guard newDate >= hundredYearsAgo else {
            print("❌ [ClipStore] Rejecting move to ancient date: \(newDate)")
            return
        }

        // Assign orderIndex at end of target day for this project
        let existingForDay = clips.filter { existing in
            guard let existingPid = existing.projectID, let d = existing.date else { return false }
            return existingPid == pid && Calendar.current.startOfDay(for: d) == targetDay
        }
        let nextIndex = (existingForDay.map { Int($0.orderIndex) }.max() ?? -1) + 1

        let fm = FileManager.default
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let base = df.string(from: targetDay)
        let uniq = String((clip.id ?? UUID()).uuidString.prefix(8))
        let filename = "\(base)_\(uniq).mp4"
        let oldURL = urlForClip(clip)
        let destURL = clipsDirectory.appendingPathComponent(filename)
        var movedURL: URL? = nil

        if oldURL != destURL {
            try? fm.removeItem(at: destURL)
            do {
                try fm.moveItem(at: oldURL, to: destURL)
                movedURL = destURL
            } catch {
                print("[ClipStore] moveClip file move error:", error)
            }
        }

        clip.date = targetDay
        clip.orderIndex = Int32(nextIndex)
        if let movedURL {
            clip.assetURL = movedURL.lastPathComponent
        }

        do {
            try context.save()
            indexRemove(projectID: pid, day: oldDay)
            indexAdd(clip)
            repositionIfNeeded(clip)
        } catch {
            context.rollback()
            if let movedURL {
                try? fm.moveItem(at: movedURL, to: oldURL)
            }
            print("[ClipStore] moveClip save error:", error)
        }
    }

    // MARK: - Split Clip

    /// Splits a clip at the specified time position, creating two clips from one.
    /// - Parameters:
    ///   - clip: The clip to split
    ///   - splitTime: The time (in seconds from the beginning of the clip's visible portion) at which to split
    ///   - project: The project the clip belongs to
    /// - Returns: The newly created second clip, or nil if split failed
    @MainActor
    @discardableResult
    func splitClip(_ clip: Clip, at splitTime: TimeInterval, in project: Project) -> Clip? {
        // Validate split time is within clip bounds
        let minSplitDuration: TimeInterval = 0.1 // Minimum clip duration after split
        guard splitTime >= minSplitDuration,
              splitTime <= clip.duration - minSplitDuration else {
            print("[ClipStore] splitClip: Invalid split time \(splitTime) for clip duration \(clip.duration)")
            return nil
        }

        // Calculate new durations
        let firstClipDuration = splitTime
        let secondClipDuration = clip.duration - splitTime
        let secondClipSnippetStart = clip.snippetStart + splitTime

        // Create the second clip
        let newClip = Clip(context: context)
        newClip.id = UUID()
        newClip.date = clip.date
        newClip.createdAt = Date()
        newClip.projectID = clip.projectID
        newClip.assetURL = clip.assetURL // Same source file
        newClip.duration = secondClipDuration
        newClip.snippetStart = secondClipSnippetStart
        newClip.isSmartFill = clip.isSmartFill
        newClip.sourceLocalID = clip.sourceLocalID
        newClip.rotationDegrees = clip.rotationDegrees
        newClip.previewFillRaw = clip.previewFillRaw
        newClip.zoomScale = clip.zoomScale
        newClip.panOffsetX = clip.panOffsetX
        newClip.panOffsetY = clip.panOffsetY
        newClip.captionText = nil // Don't copy caption to second clip
        newClip.mediaType = clip.mediaType

        // Set order index: insert after the original clip
        let originalIndex = clip.orderIndex
        newClip.orderIndex = originalIndex + 1

        // Shift subsequent clips' orderIndex for the same day
        let day = clip.date.map { dayKey($0) } ?? .distantPast
        let clipsOnSameDay = clips.filter { c in
            guard let pid = c.projectID, let d = c.date else { return false }
            return pid == project.id && Calendar.current.startOfDay(for: d) == day && c.orderIndex > originalIndex
        }
        for c in clipsOnSameDay {
            c.orderIndex += 1
        }

        // Update the original clip's duration
        clip.duration = firstClipDuration

        // Generate thumbnail for the new clip (at its snippetStart)
        generateThumbnail(for: newClip)

        // Save changes
        do {
            try context.save()

            // Update in-memory cache
            let idx = insertionIndex(for: newClip)
            clips.insert(newClip, at: idx)
            indexAdd(newClip)

            // Re-sort to maintain order after orderIndex changes
            clips.sort { a, b in
                let da = a.date ?? .distantPast
                let db = b.date ?? .distantPast
                if da != db { return da < db }

                let ia = a.orderIndex
                let ib = b.orderIndex
                if ia != ib { return ia < ib }

                let ca = a.createdAt ?? .distantPast
                let cb = b.createdAt ?? .distantPast
                return ca < cb
            }

            print("[ClipStore] splitClip: Successfully split clip at \(splitTime)s")
            print("  Original: duration=\(firstClipDuration)s, snippetStart=\(clip.snippetStart)s")
            print("  New clip: duration=\(secondClipDuration)s, snippetStart=\(secondClipSnippetStart)s")

            return newClip
        } catch {
            print("[ClipStore] splitClip save error:", error)
            context.rollback()
            return nil
        }
    }

    /// Generates a thumbnail for a clip at its snippetStart position
    private func generateThumbnail(for clip: Clip) {
        let url = urlForClip(clip)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)

        let time = CMTime(seconds: clip.snippetStart, preferredTimescale: 600)

        do {
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            let uiImage = UIImage(cgImage: cgImage)
            clip.thumbnailData = squareThumbnail(uiImage).pngData()
        } catch {
            print("[ClipStore] generateThumbnail error:", error)
            // Keep existing thumbnail if generation fails
        }
    }

    /// Upsert a clip for the given day; useful for "replace if exists" flows.
    func addOrReplaceClip(
        for date: Date,
        project: Project,
        fromURL tmpURL: URL,
        thumb: UIImage,
        duration: TimeInterval,
        isSmartFill: Bool,
        start: Double = 0,
        previewFillRaw: String? = nil
    ) {
        let fm = FileManager.default
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"

        let startDay = dayKey(date)
        // Upsert (fetch existing by exact day in this project)
        let existing = clip(for: startDay, in: project)
        let row = existing ?? Clip(context: context)
        if row.id == nil { row.id = UUID() }
        let wasNew = (existing == nil)

        // If replacing existing clip, delete its old file first
        if let existing = existing {
            let oldURL = urlForClip(existing)
            try? fm.removeItem(at: oldURL)
        }

        // Use consistent naming: {date}_{uuid}.mp4 (matches addClip)
        let base = df.string(from: date)
        let uniq = String((row.id ?? UUID()).uuidString.prefix(8))
        let filename = "\(base)_\(uniq).mp4"
        let destURL = clipsDirectory.appendingPathComponent(filename)

        // Remove destination if it somehow exists
        try? fm.removeItem(at: destURL)
        do { try fm.copyItem(at: tmpURL, to: destURL) }
        catch { print("[ClipStore] copyItem error:", error); return }

        // Update fields
        row.date          = startDay
        row.createdAt     = row.createdAt ?? Date()
        row.projectID     = project.id
        row.assetURL      = destURL.lastPathComponent
        let squaredThumb = squareThumbnail(thumb)
        let thumbData = squaredThumb.pngData()
        row.thumbnailData = thumbData
        row.duration      = duration
        row.isSmartFill   = isSmartFill
        row.snippetStart  = start
        if let previewFillRaw {
            row.previewFillRaw = previewFillRaw
        } else if row.previewFillRaw == nil {
            row.previewFillRaw = ClipDefaults.orientationRaw
        }

        // Ensure zoomScale is set to 1.0 (Core Data defaults to 0.0, which makes thumbnails invisible)
        if row.zoomScale == 0.0 {
            row.zoomScale = 1.0
        }

        // Debug: Check thumbnail generation
        print("🖼️ [ClipStore] addOrReplaceClip thumbnail: input=\(thumb.size), squared=\(squaredThumb.size), dataSize=\(thumbData?.count ?? 0) bytes")

        do {
            try context.save()
            if wasNew {
                let idx = insertionIndex(for: row)
                clips.insert(row, at: idx)
                indexAdd(row)
            } else {
                repositionIfNeeded(row)
                if let pid = row.projectID {
                    refreshDayPresentation(projectID: pid, day: dayKey(startDay))
                }
            }
        } catch {
            print("[ClipStore] addOrReplaceClip save error:", error)
        }

        CloudBackupService.shared.onLocalClipAdded(
            id: row.id?.uuidString ?? UUID().uuidString,
            fileURL: urlForClip(row),
            createdAt: row.date ?? Date(),
            journalId: project.id.uuidString,
            ext: urlForClip(row).pathExtension.lowercased()
        )
    }

    // MARK: - Per-day reordering

    @MainActor
    func reorderClips(for date: Date, in project: Project, to newOrder: [Clip]) {
        let day = dayKey(date)

        // Ensure we're only reordering clips for this (project, day)
        let filtered = newOrder.filter { clip in
            guard let pid = clip.projectID, let d = clip.date else { return false }
            return pid == project.id && Calendar.current.startOfDay(for: d) == day
        }

        // 1) Update orderIndex on each clip
        for (idx, clip) in filtered.enumerated() {
            clip.orderIndex = Int32(idx)
        }

        // 2) Save to Core Data
        do {
            try context.save()
        } catch {
            print("[ClipStore] reorderClips save error:", error)
        }

        // 3) Re-sort the global in-memory snapshot so Montage & others see the new order
        clips.sort { a, b in
            let da = a.date ?? .distantPast
            let db = b.date ?? .distantPast
            if da != db { return da < db }

            let ia = a.orderIndex
            let ib = b.orderIndex
            if ia != ib { return ia < ib }

            let ca = a.createdAt ?? .distantPast
            let cb = b.createdAt ?? .distantPast
            return ca < cb
        }

        refreshDayPresentation(projectID: project.id, day: day)
    }


    // MARK: Cloud restore (bulk changes) — keep as single reload for simplicity

    /// Move a restored file into place and upsert Core Data row by UUID.
    /// This path may process many rows; we coalesce by calling `loadClips()` once at the end.
    func importRestoredFile(idString: String,
                            tempURL: URL,
                            createdAt: Date,
                            journalId: String?,
                            ext: String) throws {
        // ✅ VALIDATION 1: Validate date before proceeding
        guard createdAt <= Date() else {
            print("❌ [Restore] Rejecting clip with future date: \(createdAt)")
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        let hundredYearsAgo = Date(timeIntervalSinceNow: -100 * 365 * 24 * 60 * 60)
        guard createdAt >= hundredYearsAgo else {
            print("❌ [Restore] Rejecting clip with ancient date: \(createdAt)")
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        // ✅ VALIDATION 2: Verify project exists if journalId provided
        // Note: Project validation should be done by the caller since ProjectStore is @MainActor
        // and this method runs on a background context. For now, we'll trust the journalId.
        var validProjectID: UUID? = nil
        if let jid = journalId, let pid = UUID(uuidString: jid) {
            validProjectID = pid
        } else {
            print("⚠️ [Restore] No valid journalId for clip \(idString); skipping")
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        let dest = clipsDirectory.appendingPathComponent("\(idString).\(ext)")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tempURL, to: dest)

        // ✅ VALIDATION 3: Verify file was actually moved
        guard FileManager.default.fileExists(atPath: dest.path) else {
            print("❌ [Restore] File move failed for \(idString)")
            return
        }

        // Upsert by UUID on the main context for simplicity
        let req: NSFetchRequest<Clip> = Clip.fetchRequest()
        if let uuid = UUID(uuidString: idString) {
            req.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            req.fetchLimit = 1
        } else {
            req.predicate = NSPredicate(value: false)
            req.fetchLimit = 1
        }

        let existing = try? context.fetch(req).first
        let clip = existing ?? Clip(context: context)

        if clip.id == nil, let uuid = UUID(uuidString: idString) { clip.id = uuid }
        clip.assetURL  = dest.lastPathComponent
        clip.createdAt = createdAt
        clip.date      = dayKey(createdAt)
        clip.projectID = validProjectID  // ✅ Only set validated project ID

        // Derive thumbnail/duration (video only for now)
        let lowerExt = ext.lowercased()
        if ["mp4","mov","m4v"].contains(lowerExt) {
            let asset = AVURLAsset(url: dest)
            if asset.duration.isNumeric { clip.duration = asset.duration.seconds }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
                clip.thumbnailData = squareThumbnail(UIImage(cgImage: cg)).pngData()
            }
        } else {
            if let img = UIImage(contentsOfFile: dest.path) {
                clip.thumbnailData = squareThumbnail(img).pngData()
            }
        }

        if context.hasChanges { try context.save() }
        // Bulk paths call loadClips() once after the whole batch finishes (from caller).
    }

    // MARK: Maintenance & Utilities (carried forward)


    func urlForDay(_ day: Date, full: Bool = false) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let base = df.string(from: day)
        let name = full ? "\(base)_full.mp4" : "\(base).mp4"
        return clipsDirectory.appendingPathComponent(name)
    }



    func urlForClip(_ clip: Clip) -> URL {
        let fm   = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = docs.appendingPathComponent("Clips")
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if let stored = clip.assetURL {
            if stored.hasPrefix("file://"), let full = URL(string: stored) { return full }
            return folder.appendingPathComponent(stored)
        }
        let base: String
        if let uuid = clip.id?.uuidString { base = uuid }
        else if let d = clip.date {
            let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]
            base = fmt.string(from: d)
        } else { base = UUID().uuidString }
        return folder.appendingPathComponent(base + ".mp4")
    }

    // MARK: - Restore helpers

    /// Build the canonical destination URL for a restored clip file,
    /// given its server/backup id string and file extension.
    /// - Parameters:
    ///   - id:  The clip UUID string coming from backup/restore.
    ///   - ext: The lower/upper/mixed-case extension from the backup payload.
    /// - Returns: A URL inside the app's "Clips" directory like  <Documents>/Clips/<id>.<ext>
    func urlForClipIdString(_ id: String, ext: String) -> URL {
        // Ensure the Clips folder exists (clipsDirectory lazily creates it too, but this is cheap)
        let fm = FileManager.default
        let dir = clipsDirectory
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Normalize extension (fallback to mp4 if empty)
        let normalizedExt = ext.trimmingCharacters(in: .whitespacesAndNewlines)
                                 .lowercased()
        let safeExt = normalizedExt.isEmpty ? "mp4" : normalizedExt

        return dir.appendingPathComponent("\(id).\(safeExt)")
    }


    func squareThumbnail(_ img: UIImage, maxSide: CGFloat = 512) -> UIImage {
        // ✅ Start with properly oriented image
        let oriented = img.fixOrientation()

        let sz = oriented.size
        let side = min(sz.width, sz.height)
        let origin = CGPoint(x: (sz.width - side) / 2, y: (sz.height - side) / 2)
        let crop = CGRect(origin: origin, size: CGSize(width: side, height: side)).integral

        let outSide = min(maxSide, side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = oriented.scale

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: outSide, height: outSide), format: format)
        return renderer.image { context in
            // Draw the cropped region
            let drawRect = CGRect(x: 0, y: 0, width: outSide, height: outSide)
            context.cgContext.translateBy(x: -origin.x * (outSide / side),
                                          y: -origin.y * (outSide / side))
            context.cgContext.scaleBy(x: outSide / side, y: outSide / side)
            oriented.draw(at: .zero)
        }
    }

    // MARK: Prewarm (optional)
}

// MARK: - UIImage Orientation Fix Extension

extension UIImage {
    /// Fixes image orientation by redrawing it in the correct orientation.
    /// This ensures EXIF orientation metadata is properly applied.
    fileprivate func fixOrientation() -> UIImage {
        // If image is already .up, no need to redraw
        guard imageOrientation != .up else { return self }

        // Calculate the proper size for the redrawn image
        var transform = CGAffineTransform.identity

        switch imageOrientation {
        case .down, .downMirrored:
            transform = transform.translatedBy(x: size.width, y: size.height)
            transform = transform.rotated(by: .pi)

        case .left, .leftMirrored:
            transform = transform.translatedBy(x: size.width, y: 0)
            transform = transform.rotated(by: .pi / 2)

        case .right, .rightMirrored:
            transform = transform.translatedBy(x: 0, y: size.height)
            transform = transform.rotated(by: -.pi / 2)

        default:
            break
        }

        switch imageOrientation {
        case .upMirrored, .downMirrored:
            transform = transform.translatedBy(x: size.width, y: 0)
            transform = transform.scaledBy(x: -1, y: 1)

        case .leftMirrored, .rightMirrored:
            transform = transform.translatedBy(x: size.height, y: 0)
            transform = transform.scaledBy(x: -1, y: 1)

        default:
            break
        }

        // Draw the image into a new context with the correct orientation
        guard let cgImage = self.cgImage else { return self }
        guard let colorSpace = cgImage.colorSpace else { return self }
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: cgImage.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: cgImage.bitmapInfo.rawValue
        ) else { return self }

        context.concatenate(transform)

        switch imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size.height, height: size.width))
        default:
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        }

        guard let newCGImage = context.makeImage() else { return self }
        return UIImage(cgImage: newCGImage, scale: scale, orientation: .up)
    }
}

extension ClipStore {

    /// Hydrates the in-memory snapshot.
    func warmUp() async {
        _ = context
        await ensureLoaded()
    }

}

extension ClipStore {

    // Bulk-delete all clips for the given journal IDs (projects).
    // - Runs on the main actor like the rest of ClipStore.
    // - Updates Core Data, publishes a single in-memory change, then removes files off-main.
    @MainActor
    func delete(projectIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }

        // 1) Snapshot victims and their file URLs (on main; fast)
        let victims: [Clip] = clips.filter { c in
            guard let pid = c.projectID else { return false }
            return ids.contains(pid)
        }
        let urls: [URL] = victims.map { urlForClip($0) }
        let cloud: [(id: String, ext: String)] = victims.map {
            ($0.id?.uuidString ?? "<missing>", urlForClip($0).pathExtension.lowercased())
        }

        // 2) Delete Core Data rows (single save)
        for c in victims { context.delete(c) }
        do { try context.save() } catch {
            print("[ClipStore] delete(projectIDs:) save error:", error)
        }

        // 3) Publish one change to the in-memory snapshot + rebuild indices
        clips.removeAll { c in
            guard let pid = c.projectID else { return false }
            return ids.contains(pid)
        }
        rebuildIndices()

        // 4) Notify cloud backup for each deleted clip (if you use it)
        for (id, ext) in cloud {
            CloudBackupService.shared.onLocalClipDeleted(id: id, ext: ext)
        }

        // 5) Remove files off the main thread
        let fm = FileManager.default
        io.async {
            for u in urls { try? fm.removeItem(at: u) }
        }
    }


    /// Delete every clip and its file from disk, then refresh the published list.
    func deleteAllClips() {
        let context = container.viewContext
        let fm = FileManager.default

        // Fetch all Clip rows
        let req: NSFetchRequest<Clip> = Clip.fetchRequest()
        do {
            let rows = try context.fetch(req)
            // Remove files + rows
            for clip in rows {
                try? fm.removeItem(at: urlForClip(clip))
                context.delete(clip)
            }
            try context.save()
            loadClips()
        } catch {
            print("[ClipStore] deleteAllClips error:", error)
        }
    }
}
