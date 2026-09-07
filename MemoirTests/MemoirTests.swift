//
//  MemoirTests.swift
//  MemoirTests
//
//  Created by Ryan Zheng on 6/5/25.
//

import Foundation
import AVFoundation
import Testing
import UIKit
@testable import Snap_Second

@MainActor
struct MemoirTests {

    @Test("Day-scoped queries include legacy same-day timestamps and replace legacy rows")
    func dayScopedQueriesUseLocalDayWindows() throws {
        let store = ClipStore.shared
        let timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let previousTimeZone = NSTimeZone.default
        NSTimeZone.default = timeZone
        defer { NSTimeZone.default = previousTimeZone }

        let dstProject = Project(name: "DST Query Regression \(UUID().uuidString)", type: .dailyJournal)
        defer { store.delete(projectIDs: Set([dstProject.id])) }

        let dstLocalIDA = "dst-a-\(UUID().uuidString)"
        let dstLocalIDB = "dst-b-\(UUID().uuidString)"

        let dstDayQuery = try makeDate(2026, 3, 8, 12, 0, timeZone: timeZone)
        let dstClipA = try seedClip(
            store: store,
            project: dstProject,
            captureDate: dstDayQuery,
            persistedDate: makeDate(2026, 3, 8, 0, 30, timeZone: timeZone),
            sourceLocalID: dstLocalIDA,
            orderIndex: 0,
            createdAt: makeDate(2026, 3, 8, 0, 35, timeZone: timeZone)
        )
        let dstClipB = try seedClip(
            store: store,
            project: dstProject,
            captureDate: dstDayQuery,
            persistedDate: makeDate(2026, 3, 8, 23, 30, timeZone: timeZone),
            sourceLocalID: dstLocalIDB,
            orderIndex: 1,
            createdAt: makeDate(2026, 3, 8, 23, 35, timeZone: timeZone)
        )

        let interval = store.dayInterval(for: dstDayQuery)
        let expectedIntervalStart = try makeDate(2026, 3, 8, 0, 0, timeZone: timeZone)
        let expectedIntervalEnd = try makeDate(2026, 3, 9, 0, 0, timeZone: timeZone)
        #expect(interval.start == expectedIntervalStart)
        #expect(interval.end == expectedIntervalEnd)
        #expect(interval.duration == 23 * 60 * 60)

        let fetchedForDay = store.clips(for: dstDayQuery, in: dstProject)
        #expect(fetchedForDay.map(\.objectID) == [dstClipA.objectID, dstClipB.objectID])
        #expect(store.clip(for: dstDayQuery, in: dstProject)?.objectID == dstClipA.objectID)
        #expect(store.count(forDayKey: Calendar.current.startOfDay(for: dstDayQuery), project: dstProject) == 2)
        #expect(store.isAssetUsedElsewhere(localID: dstLocalIDA, in: dstProject, excluding: dstDayQuery) == false)

        for clip in store.clips(for: dstDayQuery, in: dstProject) {
            store.deleteClip(clip)
        }

        #expect(store.clips(for: dstDayQuery, in: dstProject).isEmpty)
        #expect(store.count(forDayKey: Calendar.current.startOfDay(for: dstDayQuery), project: dstProject) == 0)

        let replaceProject = Project(name: "Replace Regression \(UUID().uuidString)", type: .dailyJournal)
        defer { store.delete(projectIDs: Set([replaceProject.id])) }

        let replaceDay = try makeDate(2026, 3, 10, 9, 0, timeZone: timeZone)
        let legacyClip = try seedClip(
            store: store,
            project: replaceProject,
            captureDate: replaceDay,
            persistedDate: makeDate(2026, 3, 10, 15, 45, timeZone: timeZone),
            sourceLocalID: "replace-\(UUID().uuidString)",
            orderIndex: 0,
            createdAt: makeDate(2026, 3, 10, 15, 50, timeZone: timeZone)
        )

        let replacementURL = try makeTempMediaFile()
        defer { try? FileManager.default.removeItem(at: replacementURL) }

        store.addOrReplaceClip(
            for: replaceDay,
            project: replaceProject,
            fromURL: replacementURL,
            thumb: makeThumbnail(color: .blue),
            duration: 3.5,
            isSmartFill: false
        )

        let replacementRows = store.fetchAllClips()
            .filter { $0.projectID == replaceProject.id }
            .sorted {
                ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
            }

        #expect(replacementRows.count == 1)
        #expect(replacementRows.first?.id == legacyClip.id)
        #expect(store.clips(for: replaceDay, in: replaceProject).count == 1)
    }

    @Test("Restore merges missing journals from clip references and local fallback metadata")
    func restoreRecoversMissingJournalMetadata() throws {
        let gmt = try #require(TimeZone(secondsFromGMT: 0))
        let remoteCreatedAt = try makeDate(2024, 1, 10, 9, 0, timeZone: gmt)
        let fallbackCreatedAt = try makeDate(2024, 2, 20, 9, 0, timeZone: gmt)
        let placeholderCreatedAt = try makeDate(2024, 3, 15, 9, 0, timeZone: gmt)

        let remoteJournal = CloudBackupService.BackupJournal(
            id: "remote-journal",
            name: "Remote Journal",
            createdAt: remoteCreatedAt,
            type: ProjectType.dailyJournal.rawValue,
            sortIndex: 0
        )
        let fallbackJournal = CloudBackupService.BackupJournal(
            id: "fallback-journal",
            name: "Fallback Journal",
            createdAt: fallbackCreatedAt,
            type: ProjectType.collections.rawValue,
            sortIndex: 2
        )

        let merged = CloudBackupService.mergeBackupJournals(
            remoteJournals: [remoteJournal],
            clipReferences: [
                .init(
                    id: "remote-journal",
                    name: nil,
                    createdAt: nil,
                    type: nil,
                    sortIndex: nil
                ),
                .init(
                    id: "fallback-journal",
                    name: nil,
                    createdAt: nil,
                    type: nil,
                    sortIndex: nil
                ),
                .init(
                    id: "placeholder-journal",
                    name: nil,
                    createdAt: placeholderCreatedAt,
                    type: nil,
                    sortIndex: nil
                )
            ],
            fallbackJournals: [fallbackJournal]
        )

        #expect(merged.map(\.id) == ["remote-journal", "fallback-journal", "placeholder-journal"])
        #expect(merged[0].name == "Remote Journal")
        #expect(merged[1].name == "Fallback Journal")
        #expect(merged[1].type == ProjectType.collections.rawValue)
        #expect(merged[1].createdAt == fallbackCreatedAt)
        #expect(merged[2].name == "Restored Journal 1")
        #expect(merged[2].type == ProjectType.dailyJournal.rawValue)
        #expect(merged[2].createdAt == placeholderCreatedAt)
    }

    @Test("Preview sampler spans the full timeline without collapsing into recent years")
    func previewSamplerSpansTimelineWithoutRecentBias() throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let candidates =
            try makeSamplingCandidates(year: 2020, count: 3, startingAt: 0, timeZone: timeZone) +
            (try makeSamplingCandidates(year: 2021, count: 4, startingAt: 3, timeZone: timeZone)) +
            (try makeSamplingCandidates(year: 2022, count: 5, startingAt: 7, timeZone: timeZone)) +
            (try makeSamplingCandidates(year: 2023, count: 90, startingAt: 12, timeZone: timeZone))

        let selected = OnboardingPreviewService.timeSpacedCandidates(
            from: candidates,
            limit: 8
        )
        let countsByYear = Dictionary(grouping: selected) {
            calendar.component(.year, from: $0.date)
        }

        #expect(selected.count == 8)
        #expect(calendar.component(.year, from: selected.first?.date ?? .distantPast) == 2020)
        #expect(calendar.component(.year, from: selected.last?.date ?? .distantPast) == 2023)
        #expect((countsByYear[2020]?.count ?? 0) >= 1)
        #expect((countsByYear[2021]?.count ?? 0) >= 1)
        #expect((countsByYear[2022]?.count ?? 0) >= 1)
        #expect((countsByYear[2023]?.count ?? 0) < 5)
    }

    @Test("Preview window only uses the trailing five years")
    func previewWindowUsesTrailingFiveYears() throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let now = try makeDate(2026, 4, 21, 12, 0, timeZone: timeZone)
        let cutoff = try makeDate(2021, 4, 21, 12, 0, timeZone: timeZone)

        let candidates =
            try makeSamplingCandidates(year: 2019, count: 3, startingAt: 0, timeZone: timeZone) +
            (try makeSamplingCandidates(year: 2020, count: 3, startingAt: 3, timeZone: timeZone)) +
            (try makeSamplingCandidates(year: 2021, count: 6, startingAt: 6, timeZone: timeZone)) +
            (try makeSamplingCandidates(year: 2025, count: 3, startingAt: 12, timeZone: timeZone))

        let filtered = OnboardingPreviewService.candidatesWithinTrailingYears(
            from: candidates,
            yearsBack: 5,
            now: now,
            calendar: calendar
        )

        #expect(filtered.count == 5)
        #expect(filtered.allSatisfy { $0.date >= cutoff })
        #expect(filtered.contains { calendar.component(.year, from: $0.date) == 2025 })
        #expect(filtered.contains { calendar.component(.year, from: $0.date) == 2021 })
        #expect(filtered.contains { calendar.component(.year, from: $0.date) == 2020 } == false)
    }

    @Test("Rewind selector keeps one representative clip per year")
    func rewindSelectorKeepsOneRepresentativeClipPerYear() throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: 0))

        let candidates = [
            RewindCandidate(
                id: "2024-photo",
                key: .init(
                    year: 2024,
                    mediaPriority: 0,
                    creationDate: try makeDate(2024, 4, 21, 12, 0, timeZone: timeZone),
                    stableID: "2024-photo"
                )
            ),
            RewindCandidate(
                id: "2024-video",
                key: .init(
                    year: 2024,
                    mediaPriority: 2,
                    creationDate: try makeDate(2024, 4, 21, 18, 0, timeZone: timeZone),
                    stableID: "2024-video"
                )
            ),
            RewindCandidate(
                id: "2023-live",
                key: .init(
                    year: 2023,
                    mediaPriority: 1,
                    creationDate: try makeDate(2023, 4, 21, 16, 0, timeZone: timeZone),
                    stableID: "2023-live"
                )
            ),
            RewindCandidate(
                id: "2023-photo",
                key: .init(
                    year: 2023,
                    mediaPriority: 0,
                    creationDate: try makeDate(2023, 4, 21, 20, 0, timeZone: timeZone),
                    stableID: "2023-photo"
                )
            ),
            RewindCandidate(
                id: "2022-older-photo",
                key: .init(
                    year: 2022,
                    mediaPriority: 0,
                    creationDate: try makeDate(2022, 4, 21, 9, 0, timeZone: timeZone),
                    stableID: "2022-older-photo"
                )
            ),
            RewindCandidate(
                id: "2022-newer-photo",
                key: .init(
                    year: 2022,
                    mediaPriority: 0,
                    creationDate: try makeDate(2022, 4, 21, 21, 0, timeZone: timeZone),
                    stableID: "2022-newer-photo"
                )
            )
        ]

        let selected = RewindEngine.pickOneItemPerYear(from: candidates, selectionKey: \.key)

        #expect(selected.map(\.id) == ["2024-video", "2023-live", "2022-newer-photo"])
    }

    @Test("Montage prefs round-trip through Codable")
    func montagePrefsRoundTrip() throws {
        let prefs = MontagePrefs(
            trackID: nil,
            musicVol: 65,
            videoVol: 20,
            rangeStart: Date(timeIntervalSince1970: 10),
            rangeEnd: Date(timeIntervalSince1970: 20),
            rangeLabel: "All",
            orientation: "v916",
            contentMode: "fit",
            captionsMode: "none",
            customCaption: nil,
            showDates: true,
            showBranding: false,
            captionTextColor: "white",
            captionRGBA: RGBA(r: 1, g: 1, b: 1, a: 1),
            captionOpacity: 1,
            captionFontSize: 24,
            captionFont: "system",
            captionPos: "bottomCenter",
            exportQuality: "standard",
            background: "black",
            captionNormX: 0.5,
            captionNormY: 0.9,
            filter: "none",
            speed: 1
        )

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(MontagePrefs.self, from: data)

        #expect(decoded.showDates == prefs.showDates)
        #expect(decoded.filter == prefs.filter)
        #expect(decoded.captionNormX == prefs.captionNormX)
        #expect(decoded.speed == prefs.speed)
    }

    @Test("Preview sampler returns exact cap when enough assets exist")
    func previewSamplerReturnsRequestedCap() throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: 0))

        let candidates =
            try makeSamplingCandidates(year: 2020, count: 120, startingAt: 0, timeZone: timeZone) +
            (try makeSamplingCandidates(year: 2021, count: 120, startingAt: 120, timeZone: timeZone)) +
            (try makeSamplingCandidates(year: 2022, count: 120, startingAt: 240, timeZone: timeZone)) +
            (try makeSamplingCandidates(year: 2023, count: 120, startingAt: 360, timeZone: timeZone))

        let selected = OnboardingPreviewService.timeSpacedCandidates(
            from: candidates,
            limit: 180
        )

        #expect(selected.count == 180)
    }

    @Test("Timelapse frame distribution stays pinned to one minute")
    func timelapseFrameDistributionStaysAtOneMinute() {
        let thirtyAssetFrames = OnboardingPreviewService.timelapseFrameDistribution(
            assetCount: 30,
            totalDuration: 60,
            frameRate: 12
        )
        let oneEightyAssetFrames = OnboardingPreviewService.timelapseFrameDistribution(
            assetCount: 180,
            totalDuration: 60,
            frameRate: 12
        )

        #expect(thirtyAssetFrames.count == 30)
        #expect(thirtyAssetFrames.reduce(0, +) == 720)
        #expect(Set(thirtyAssetFrames) == [24])

        #expect(oneEightyAssetFrames.count == 180)
        #expect(oneEightyAssetFrames.reduce(0, +) == 720)
        #expect(Set(oneEightyAssetFrames) == [4])
        #expect(OnboardingPreviewService.timelapseSecondsPerAsset(assetCount: 30) == 2)
        #expect(abs(OnboardingPreviewService.timelapseSecondsPerAsset(assetCount: 180) - (1.0 / 3.0)) < 0.000_001)
    }

    @Test("Montage export diagnostics use the NSError reason for failed exports")
    func montageExportFailedPresentationUsesSpecificReason() {
        let error = NSError(
            domain: AVError.errorDomain,
            code: -11800,
            userInfo: [
                NSLocalizedFailureReasonErrorKey: "Disk full while writing the movie.",
                NSLocalizedDescriptionKey: "The operation could not be completed."
            ]
        )

        let presentation = MontageExportDiagnostics.presentation(for: .failed, error: error)

        #expect(presentation.title == "Export Failed")
        #expect(presentation.message == "Export failed: Disk full while writing the movie.")
    }

    @Test("Montage export diagnostics report session creation failure")
    func montageExportSessionCreationPresentation() {
        let presentation = MontageExportDiagnostics.presentation(for: .sessionCreationFailed, error: nil)

        #expect(presentation.title == "Export Failed")
        #expect(presentation.message == "Couldn’t start the export.")
    }

    @Test("Montage export diagnostics report stall cancellations")
    func montageExportStalledPresentation() {
        let presentation = MontageExportDiagnostics.presentation(for: .stalled, error: nil)

        #expect(presentation.message == "Export stopped making progress and was cancelled.")
    }

    @Test("Montage export diagnostics report absolute timeouts")
    func montageExportTimedOutPresentation() {
        let presentation = MontageExportDiagnostics.presentation(for: .timedOut, error: nil)

        #expect(presentation.message == "Export took too long and timed out.")
    }

    @Test("Montage export diagnostics fall back cleanly for cancelled exports without detail")
    func montageExportCancelledPresentationFallsBack() {
        let presentation = MontageExportDiagnostics.presentation(for: .cancelled, error: nil)

        #expect(presentation.message == "Export failed before the video could be created.")
    }

    private enum TestError: Error {
        case clipNotFound(String)
        case invalidDate
    }

    private struct RewindCandidate: Equatable {
        let id: String
        let key: RewindEngine.SelectionKey
    }

    private func seedClip(
        store: ClipStore,
        project: Project,
        captureDate: Date,
        persistedDate: Date,
        sourceLocalID: String,
        orderIndex: Int32,
        createdAt: Date
    ) throws -> Clip {
        let tmpURL = try makeTempMediaFile()
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        store.addClip(
            for: captureDate,
            project: project,
            fromURL: tmpURL,
            thumb: makeThumbnail(color: .red),
            duration: 2.0,
            isSmartFill: false,
            start: 0,
            sourceLocalID: sourceLocalID
        )

        guard let clip = store.fetchAllClips().first(where: {
            $0.projectID == project.id && $0.sourceLocalID == sourceLocalID
        }) else {
            throw TestError.clipNotFound(sourceLocalID)
        }

        clip.date = persistedDate
        clip.createdAt = createdAt
        clip.orderIndex = orderIndex
        try store.context.save()
        return clip
    }

    private func makeDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        timeZone: TimeZone
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        guard let date = calendar.date(from: components) else {
            throw TestError.invalidDate
        }
        return date
    }

    private func makeTempMediaFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        try Data("memoir-test".utf8).write(to: url)
        return url
    }

    private func makeThumbnail(color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func makeSamplingCandidates(
        year: Int,
        count: Int,
        startingAt startIndex: Int,
        timeZone: TimeZone
    ) throws -> [OnboardingPreviewService.SamplingCandidate] {
        try (0..<count).map { offset in
            let month = (offset % 12) + 1
            let day = ((offset / 12) % 28) + 1
            return OnboardingPreviewService.SamplingCandidate(
                localIdentifier: "\(year)-\(offset)",
                date: try makeDate(year, month, day, 12, 0, timeZone: timeZone),
                fetchIndex: startIndex + offset
            )
        }
    }
}
