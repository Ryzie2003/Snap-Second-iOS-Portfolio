//
//  ClipStore+Maintenance.swift
//  Snap Second
//
//  Debug and diagnostic utilities for ClipStore
//

import Foundation
import CoreData
import UIKit

extension ClipStore {

    // MARK: - Debug Utilities


    /// List all clips with their file status for debugging
    @MainActor
    public func debugListClips(in project: Project) {
        let req: NSFetchRequest<Clip> = Clip.fetchRequest()
        req.predicate = NSPredicate(format: "projectID == %@", project.id as CVarArg)
        req.sortDescriptors = [
            NSSortDescriptor(key: "date", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: true)
        ]

        guard let allClips = try? context.fetch(req) else {
            print("[debugListClips] Fetch failed")
            return
        }

        let fm = FileManager.default
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short

        print("\n=== DEBUG: All clips in project '\(project.name)' ===")
        for clip in allClips {
            let url = urlForClip(clip)
            let exists = fm.fileExists(atPath: url.path)
            let dateStr = clip.date.map { df.string(from: $0) } ?? "nil"

            print("• \(exists ? "✓" : "✗") \(url.lastPathComponent) | Date: \(dateStr)")
            print("  assetURL: \(clip.assetURL ?? "nil")")
        }
        print("=== Total: \(allClips.count) clips ===\n")
    }

    /// Diagnose file path issues for a specific date/project
    @MainActor
    public func diagnoseFilePaths(for date: Date, in project: Project) {
        print("\n🔍 [PATH DIAGNOSTIC] Starting path diagnosis for \(date), project \(project.name)")

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

        guard let clips = try? context.fetch(req) else {
            print("❌ [PATH DIAGNOSTIC] Failed to fetch clips")
            return
        }

        print("📊 [PATH DIAGNOSTIC] Found \(clips.count) clips in database")
        print("📁 [PATH DIAGNOSTIC] Clips directory: \(clipsDirectory.path)")

        let fm = FileManager.default

        // Check directory contents
        if let contents = try? fm.contentsOfDirectory(at: clipsDirectory, includingPropertiesForKeys: nil) {
            print("📁 [PATH DIAGNOSTIC] Files in directory: \(contents.count)")
            let dateStr = DateFormatter().string(from: date)
            let matchingFiles = contents.filter { $0.lastPathComponent.contains(dateStr.prefix(10)) }
            print("📁 [PATH DIAGNOSTIC] Files matching this date: \(matchingFiles.count)")
            for file in matchingFiles {
                print("  ✓ \(file.lastPathComponent)")
            }
        }

        print("\n🔍 [PATH DIAGNOSTIC] Checking each clip:")
        for (index, clip) in clips.enumerated() {
            print("\n--- Clip \(index + 1) ---")
            print("  assetURL: \(clip.assetURL ?? "nil")")
            print("  id: \(clip.id?.uuidString ?? "nil")")

            let constructedURL = urlForClip(clip)
            print("  Constructed path: \(constructedURL.path)")
            print("  Constructed filename: \(constructedURL.lastPathComponent)")

            let fileExists = fm.fileExists(atPath: constructedURL.path)
            print("  File exists: \(fileExists ? "✅ YES" : "❌ NO")")

            if !fileExists && clip.assetURL != nil {
                // Try alternative paths
                let justFilename = clipsDirectory.appendingPathComponent(clip.assetURL!)
                let altExists = fm.fileExists(atPath: justFilename.path)
                print("  Alt path (clipsDir + assetURL): \(justFilename.path)")
                print("  Alt exists: \(altExists ? "✅ YES" : "❌ NO")")
            }

            if let data = clip.thumbnailData {
                print("  Has thumbnail: ✅ YES (\(data.count) bytes)")
            } else {
                print("  Has thumbnail: ❌ NO")
            }
        }

        print("\n✅ [PATH DIAGNOSTIC] Complete\n")
    }

    /// Compare database records with actual files on disk
    @MainActor
    public func auditClipsDirectory() {
        print("\n📊 [AUDIT] Starting clips directory audit")

        let allClips = fetchAllClips()
        let fm = FileManager.default

        print("📊 [AUDIT] Database has \(allClips.count) clip records")
        print("📁 [AUDIT] Clips directory: \(clipsDirectory.path)")

        guard let contents = try? fm.contentsOfDirectory(at: clipsDirectory, includingPropertiesForKeys: nil) else {
            print("❌ [AUDIT] Could not read Clips directory!")
            return
        }

        print("📁 [AUDIT] Directory contains \(contents.count) files")

        // Compare database vs filesystem
        let fileNames = Set(contents.map { $0.lastPathComponent })
        let dbAssetURLs = Set(allClips.compactMap { $0.assetURL })

        let orphanFiles = fileNames.subtracting(dbAssetURLs)
        let missingFiles = dbAssetURLs.subtracting(fileNames)

        if orphanFiles.isEmpty && missingFiles.isEmpty {
            print("✅ [AUDIT] Perfect sync: All database records have files, no orphans")
        } else {
            if !orphanFiles.isEmpty {
                print("⚠️ [AUDIT] Found \(orphanFiles.count) orphan files (on disk, not in DB):")
                for f in orphanFiles.prefix(10) {
                    print("  - \(f)")
                }
            }

            if !missingFiles.isEmpty {
                print("⚠️ [AUDIT] Found \(missingFiles.count) missing files (in DB, not on disk):")
                for f in missingFiles.prefix(10) {
                    print("  - \(f)")
                }
            }
        }

        print("✅ [AUDIT] Complete\n")
    }

    // MARK: - Thumbnail Regeneration

    /// Regenerates thumbnails for all clips in a project from their actual video files
    @MainActor
    public func regenerateThumbnails(in project: Project, progress: ((Int, Int) -> Void)? = nil) async -> Int {
        let req: NSFetchRequest<Clip> = Clip.fetchRequest()
        req.predicate = NSPredicate(format: "projectID == %@", project.id as CVarArg)

        guard let allClips = try? context.fetch(req) else {
            print("❌ [REGEN] Failed to fetch clips")
            return 0
        }

        print("🔄 [REGEN] Regenerating thumbnails for \(allClips.count) clips...")
        var successCount = 0
        let fm = FileManager.default

        for (index, clip) in allClips.enumerated() {
            let url = urlForClip(clip)

            guard fm.fileExists(atPath: url.path) else {
                print("⚠️ [REGEN] Skipping \(url.lastPathComponent) - file not found")
                continue
            }

            do {
                let thumb = try ThumbnailGenerator.make(from: url, maxLength: 300)
                clip.thumbnailData = squareThumbnail(thumb).pngData()
                successCount += 1
                print("✅ [REGEN] \(index + 1)/\(allClips.count): \(url.lastPathComponent) - \(clip.thumbnailData?.count ?? 0) bytes")
            } catch {
                print("❌ [REGEN] \(index + 1)/\(allClips.count): \(url.lastPathComponent) - \(error.localizedDescription)")
            }

            progress?(index + 1, allClips.count)
        }

        do {
            try context.save()
            print("✅ [REGEN] Saved \(successCount) regenerated thumbnails")
        } catch {
            print("❌ [REGEN] Save failed: \(error)")
        }

        return successCount
    }

    /// Regenerates thumbnail for a single clip
    @MainActor
    public func regenerateThumbnail(for clip: Clip) -> Bool {
        let url = urlForClip(clip)

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ [REGEN] File not found: \(url.lastPathComponent)")
            return false
        }

        do {
            let thumb = try ThumbnailGenerator.make(from: url, maxLength: 300)
            clip.thumbnailData = squareThumbnail(thumb).pngData()
            try context.save()
            print("✅ [REGEN] Regenerated thumbnail for \(url.lastPathComponent)")
            return true
        } catch {
            print("❌ [REGEN] Failed: \(error.localizedDescription)")
            return false
        }
    }
}
