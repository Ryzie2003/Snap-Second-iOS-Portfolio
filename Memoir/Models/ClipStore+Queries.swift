//
//  ClipStore+Queries.swift
//  Snap Second
//
//  Query and fetch methods for ClipStore
//

import Foundation
import CoreData
import UIKit

extension ClipStore {

    // MARK: - Fast Lookups via Indices

    /// Fast count for a specific date and project using in-memory indices
    @MainActor
    public func count(for date: Date, project: Project) -> Int {
        countByProjectDay[project.id]?[dayKey(date)] ?? 0
    }

    /// Get the first thumbnail data for a specific date and project
    @MainActor
    public func firstThumbData(for date: Date, project: Project) -> Data? {
        thumbByProjectDay[project.id]?[dayKey(date)]
    }

    /// Fast count using pre-normalized day key
    @MainActor
    public func count(forDayKey key: Date, project: Project) -> Int {
        countByProjectDay[project.id]?[key] ?? 0
    }

    /// Get thumbnail using pre-normalized day key
    @MainActor
    public func firstThumbData(forDayKey key: Date, project: Project) -> Data? {
        thumbByProjectDay[project.id]?[key]
    }

    /// Get the rotation angle for the first clip on a given day
    @MainActor
    public func firstClipRotation(forDayKey key: Date, project: Project) -> Double {
        rotationByProjectDay[project.id]?[key] ?? 0.0
    }

    /// Get the latest thumbnail for a project (most recent day with clips)
    @MainActor
    public func latestThumbData(for project: Project) -> Data? {
        guard let days = thumbByProjectDay[project.id], !days.isEmpty else { return nil }
        // Pick the newest day with a thumb
        return days.max(by: { $0.key < $1.key })?.value
    }

    // MARK: - Day Window Helpers

    /// Returns the local calendar day window `[startOfDay, nextStartOfDay)` for day-scoped queries.
    func dayInterval(for date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 60 * 60)
        return DateInterval(start: start, end: end)
    }

    // MARK: - Core Data Queries

    /// Get the first clip for a specific date in a project
    public func clip(for date: Date, in project: Project) -> Clip? {
        let interval = dayInterval(for: date)
        let req: NSFetchRequest<Clip> = Clip.fetchRequest()
        req.predicate = NSPredicate(
            format: "date >= %@ AND date < %@ AND projectID == %@",
            interval.start as NSDate, interval.end as NSDate, project.id as CVarArg
        )
        req.sortDescriptors = [
            NSSortDescriptor(key: "orderIndex", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: true)
        ]
        req.fetchLimit = 1
        return (try? context.fetch(req))?.first
    }

    /// Convenience alias for backwards compatibility
    @MainActor
    public func firstClip(for date: Date, in project: Project) -> Clip? {
        self.clip(for: date, in: project)
    }

    /// Get all clips for a specific date in a project
    public func clips(for date: Date, in project: Project) -> [Clip] {
        let interval = dayInterval(for: date)
        let req: NSFetchRequest<Clip> = Clip.fetchRequest()
        req.predicate = NSPredicate(
            format: "date >= %@ AND date < %@ AND projectID == %@",
            interval.start as NSDate, interval.end as NSDate, project.id as CVarArg
        )
        req.sortDescriptors = [
            NSSortDescriptor(key: "orderIndex", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: true)
        ]

        return (try? context.fetch(req)) ?? []
    }

    /// Get clips within a date range for a project
    public func clips(from start: Date, to end: Date, in project: Project) -> [Clip] {
        let req: NSFetchRequest<Clip> = Clip.fetchRequest()
        req.predicate = NSPredicate(
            format: "date >= %@ AND date <= %@ AND projectID == %@",
            start as NSDate, end as NSDate, project.id as CVarArg
        )

        // Collections: honor user's manual ordering across dates
        // Daily Journal/Timelapse: chronological order by date
        if project.type == .collections {
            req.sortDescriptors = [
                NSSortDescriptor(key: "orderIndex", ascending: true),
                NSSortDescriptor(key: "date", ascending: true),
                NSSortDescriptor(key: "createdAt", ascending: true)
            ]
        } else {
            req.sortDescriptors = [
                NSSortDescriptor(key: "date", ascending: true),
                NSSortDescriptor(key: "orderIndex", ascending: true),
                NSSortDescriptor(key: "createdAt", ascending: true)
            ]
        }

        return (try? context.fetch(req)) ?? []
    }

    /// Fetch all clips (no filtering)
    public func fetchAllClips() -> [Clip] {
        let request: NSFetchRequest<Clip> = Clip.fetchRequest()
        request.sortDescriptors = []
        return (try? context.fetch(request)) ?? []
    }

    // MARK: - Asset Checks

    /// Check if an asset (by local identifier) is used in other clips
    public func isAssetUsedElsewhere(localID: String, in project: Project, excluding date: Date?) -> Bool {
        var preds: [NSPredicate] = [
            NSPredicate(format: "projectID == %@", project.id as CVarArg),
            NSPredicate(format: "sourceLocalID == %@", localID)
        ]
        if let date {
            let interval = dayInterval(for: date)
            preds.append(NSPredicate(
                format: "NOT (date >= %@ AND date < %@)",
                interval.start as NSDate,
                interval.end as NSDate
            ))
        }
        let req: NSFetchRequest<Clip> = Clip.fetchRequest()
        req.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: preds)
        req.fetchLimit = 1
        return ((try? context.fetch(req))?.isEmpty == false)
    }

    /// Get all local IDs used in a project
    public func usedLocalIDs(in project: Project) -> Set<String> {
        let req: NSFetchRequest<Clip> = Clip.fetchRequest()
        req.predicate = NSPredicate(format: "projectID == %@ AND sourceLocalID != nil", project.id as CVarArg)
        let clips = (try? context.fetch(req)) ?? []
        return Set(clips.compactMap(\.sourceLocalID))
    }
}
