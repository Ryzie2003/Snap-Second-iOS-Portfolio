import AVFoundation
import CoreVideo
import Photos
import UIKit

struct OnboardingPreparedClip: Identifiable {
    let id = UUID()
    let tempURL: URL
    let date: Date
    let duration: TimeInterval
    let sourceLocalID: String?
    let mediaType: ClipMediaType
}

struct OnboardingPreviewSlide: Identifiable, Hashable {
    let localIdentifier: String
    let date: Date

    var id: String { localIdentifier }
}

struct OnboardingPreviewTimelineEntry: Identifiable, Hashable {
    let localIdentifier: String
    let date: Date
    let duration: TimeInterval

    var id: String { localIdentifier }
}

struct OnboardingPreviewBundle {
    let composition: AVMutableComposition?
    let videoComposition: AVMutableVideoComposition?
    let audioMix: AVAudioMix?
    let exportURL: URL?
    let preparedClips: [OnboardingPreparedClip]
    let slides: [OnboardingPreviewSlide]
    let timeline: [OnboardingPreviewTimelineEntry]
    let trackID: String

    var sourceLocalIDs: [String] {
        if !slides.isEmpty {
            return slides.map(\.localIdentifier)
        }
        if !timeline.isEmpty {
            return timeline.map(\.localIdentifier)
        }
        return preparedClips.compactMap(\.sourceLocalID)
    }

    var assetCount: Int {
        max(slides.count, max(timeline.count, preparedClips.count))
    }

    var hasSlidesReady: Bool {
        !slides.isEmpty || !timeline.isEmpty
    }

    var hasPlayableVideo: Bool {
        composition != nil && videoComposition != nil
    }
}

enum OnboardingPreviewStrategy {
    case mixedMontage
    case photoTimelapse
}

enum OnboardingPreviewServiceError: LocalizedError {
    case noLibraryMoments
    case noLocalLibraryMoments
    case noPreparedClips
    case invalidImageData
    case missingTrack(String)
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noLibraryMoments:
            return "We couldn't find enough photos or videos to build a preview yet."
        case .noLocalLibraryMoments:
            return "We couldn't find enough downloaded photos to build a preview yet."
        case .noPreparedClips:
            return "We couldn't prepare a preview from your moments yet."
        case .invalidImageData:
            return "We couldn't read one of your photos."
        case .missingTrack(let name):
            return "We couldn't load the \(name) track for your preview."
        case .exportFailed:
            return "We couldn't finish the preview export."
        }
    }
}

struct OnboardingPreviewService {
    struct SamplingCandidate: Equatable {
        let localIdentifier: String
        let date: Date
        let fetchIndex: Int
    }

    private let previewTrackID = "moments"
    private let mixedClipDuration: TimeInterval = 3.0
    private let mixedTotalDuration: TimeInterval = 30.0
    private var mixedClipLimit: Int { max(Int(mixedTotalDuration / mixedClipDuration), 1) }
    private let previewPrepareConcurrency = 3
    private let mixedRenderSize = CGSize(width: 1080, height: 1920)

    private let timelapseLookbackYears = 5
    private let timelapseTotalDuration: TimeInterval = 60.0
    private let timelapsePhotoLimit: Int = 60
    private let timelapseFrameRate: Int32 = 12
    private let timelapseRenderSize = CGSize(width: 720, height: 1280)
    private let localPhotoProbeConcurrency = 16

    private var previewMediaConfig: ClipDefaults.MediaConfig {
        .init(
            crop: .portrait9x16,
            mode: .fill,
            renderSize: mixedRenderSize
        )
    }

    func makePreview(
        strategy: OnboardingPreviewStrategy = .mixedMontage,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> OnboardingPreviewBundle {
        switch strategy {
        case .mixedMontage:
            return try await makeMixedPreview(progress: progress)
        case .photoTimelapse:
            return try await makePhotoTimelapsePreview(progress: progress)
        }
    }

    static func timelapseSecondsPerAsset(
        assetCount: Int,
        totalDuration: TimeInterval = 60.0
    ) -> TimeInterval {
        guard assetCount > 0 else { return totalDuration }
        return totalDuration / Double(assetCount)
    }

    static func timelapseFrameDistribution(
        assetCount: Int,
        totalDuration: TimeInterval = 60.0,
        frameRate: Int32 = 12
    ) -> [Int] {
        guard assetCount > 0, frameRate > 0 else { return [] }

        let totalFrames = max(Int((totalDuration * Double(frameRate)).rounded()), assetCount)
        let baseFrames = totalFrames / assetCount
        let remainder = totalFrames % assetCount

        return (0..<assetCount).map { index in
            baseFrames + (index < remainder ? 1 : 0)
        }
    }

    static func previewTrackURL(for trackID: String) throws -> URL {
        guard let track = bundledTracks.first(where: { $0.id == trackID }) else {
            throw OnboardingPreviewServiceError.missingTrack(trackID)
        }

        if let url = Bundle.main.url(forResource: track.resource, withExtension: "mp3") {
            return url
        }
        if let url = Bundle.main.url(forResource: track.resource, withExtension: "m4a") {
            return url
        }

        throw OnboardingPreviewServiceError.missingTrack(track.resource)
    }

    private func makeMixedPreview(
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> OnboardingPreviewBundle {
        let assets = fetchCandidateAssets(
            predicate: NSPredicate(
                format: "mediaType == %d OR mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            )
        )
        guard !assets.isEmpty else { throw OnboardingPreviewServiceError.noLibraryMoments }

        let selectedAssets = selectAssets(from: assets, limit: mixedClipLimit)
        let preparedClips = try await prepareClips(from: selectedAssets, progress: progress)
        guard !preparedClips.isEmpty else { throw OnboardingPreviewServiceError.noPreparedClips }

        await progress(0.92)
        let (composition, videoComposition, audioMix) = try await buildPreviewComposition(from: preparedClips)
        await progress(1.0)

        return OnboardingPreviewBundle(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            exportURL: nil,
            preparedClips: preparedClips,
            slides: preparedClips.compactMap { preparedClip in
                guard let sourceLocalID = preparedClip.sourceLocalID else { return nil }
                return OnboardingPreviewSlide(localIdentifier: sourceLocalID, date: preparedClip.date)
            },
            timeline: makeTimelineEntries(from: preparedClips),
            trackID: previewTrackID
        )
    }

    private func makePhotoTimelapsePreview(
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> OnboardingPreviewBundle {
        let slidesBundle = try await makePhotoTimelapseSlidesPreview(progress: progress)
        return try await upgradePhotoTimelapsePreview(slidesBundle, progress: progress)
    }

    func makePhotoTimelapseSlidesPreview(
        progress: @escaping @MainActor (Double) -> Void = { _ in },
        seedSlide: @escaping @MainActor (OnboardingPreviewSlide?) -> Void = { _ in }
    ) async throws -> OnboardingPreviewBundle {
        let fetchedAssets = fetchPhotoTimeline()
        guard fetchedAssets.count > 0 else { throw OnboardingPreviewServiceError.noLibraryMoments }

        let localAssets = await selectLocalTimelineAssets(
            from: fetchedAssets,
            limit: timelapsePhotoLimit,
            progress: progress,
            seedAsset: { asset in
                Task { @MainActor in
                    guard let asset else {
                        seedSlide(nil)
                        return
                    }

                    seedSlide(
                        OnboardingPreviewSlide(
                            localIdentifier: asset.localIdentifier,
                            date: asset.creationDate ?? Date()
                        )
                    )
                }
            }
        )
        guard !localAssets.isEmpty else { throw OnboardingPreviewServiceError.noLocalLibraryMoments }

        let timeline = makeTimelineEntries(from: localAssets)
        let slides = timeline.map {
            OnboardingPreviewSlide(localIdentifier: $0.localIdentifier, date: $0.date)
        }
        await progress(0.22)

        return OnboardingPreviewBundle(
            composition: nil,
            videoComposition: nil,
            audioMix: nil,
            exportURL: nil,
            preparedClips: [],
            slides: slides,
            timeline: timeline,
            trackID: previewTrackID
        )
    }

    func upgradePhotoTimelapsePreview(
        _ bundle: OnboardingPreviewBundle,
        progress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> OnboardingPreviewBundle {
        let assets = loadAssets(for: bundle.slides)
        guard !assets.isEmpty else {
            throw OnboardingPreviewServiceError.noLocalLibraryMoments
        }

        let (videoURL, preparedClips) = try await buildPhotoTimelapseVideo(
            from: assets,
            progress: { innerProgress in
                let mappedProgress = 0.22 + (innerProgress * 0.68)
                await progress(mappedProgress)
            }
        )
        await progress(0.94)

        let finalTimeline = makeTimelineEntries(from: preparedClips)
        let finalSlides = finalTimeline.map {
            OnboardingPreviewSlide(localIdentifier: $0.localIdentifier, date: $0.date)
        }

        let (composition, videoComposition, audioMix) = try await buildPreviewComposition(
            from: videoURL,
            renderSize: timelapseRenderSize,
            frameDuration: CMTime(value: 1, timescale: timelapseFrameRate)
        )
        await progress(1.0)

        return OnboardingPreviewBundle(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            exportURL: bundle.exportURL,
            preparedClips: preparedClips,
            slides: finalSlides.isEmpty ? bundle.slides : finalSlides,
            timeline: finalTimeline.isEmpty ? bundle.timeline : finalTimeline,
            trackID: previewTrackID
        )
    }

    private func selectTimelineAssets(
        from fetchResult: PHFetchResult<PHAsset>,
        limit: Int
    ) -> [PHAsset] {
        let candidates = Self.candidatesWithinTrailingYears(
            from: samplingCandidates(from: fetchResult),
            yearsBack: timelapseLookbackYears
        )
        let selectedCandidates = Self.timeSpacedCandidates(
            from: candidates,
            limit: min(limit, candidates.count)
        )

        return selectedCandidates
            .map { fetchResult.object(at: $0.fetchIndex) }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    }

    func exportPreviewAsset(
        for bundle: OnboardingPreviewBundle,
        progress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> URL {
        if let exportURL = bundle.exportURL {
            return exportURL
        }

        if let composition = bundle.composition,
           let videoComposition = bundle.videoComposition {
            return try await exportPreview(
                composition: composition,
                videoComposition: videoComposition,
                audioMix: bundle.audioMix,
                timeline: bundle.timeline,
                progress: progress
            )
        }

        if bundle.hasSlidesReady {
            let assets = loadAssets(for: bundle.slides)
            guard !assets.isEmpty else {
                throw OnboardingPreviewServiceError.noLocalLibraryMoments
            }

            let (videoURL, preparedClips) = try await buildPhotoTimelapseVideo(
                from: assets,
                progress: { innerProgress in
                    await progress(innerProgress)
                }
            )
            await progress(0.96)
            let finalTimeline = makeTimelineEntries(from: preparedClips)
            let (composition, videoComposition, audioMix) = try await buildPreviewComposition(
                from: videoURL,
                renderSize: timelapseRenderSize,
                frameDuration: CMTime(value: 1, timescale: timelapseFrameRate)
            )
            return try await exportPreview(
                composition: composition,
                videoComposition: videoComposition,
                audioMix: audioMix,
                timeline: finalTimeline.isEmpty ? bundle.timeline : finalTimeline,
                progress: progress
            )
        }

        throw OnboardingPreviewServiceError.exportFailed
    }

    @MainActor
    func persistPreparedClips(
        _ preparedClips: [OnboardingPreparedClip],
        into project: Project,
        clipStore: ClipStore
    ) async {
        guard !preparedClips.isEmpty else { return }

        for preparedClip in preparedClips.sorted(by: { $0.date < $1.date }) {
            do {
                let thumb = try ThumbnailGenerator.make(from: preparedClip.tempURL, maxLength: 300)
                clipStore.addClip(
                    for: preparedClip.date,
                    project: project,
                    fromURL: preparedClip.tempURL,
                    thumb: thumb,
                    duration: preparedClip.duration,
                    isSmartFill: false,
                    start: 0,
                    sourceLocalID: preparedClip.sourceLocalID,
                    previewFillRaw: ClipDefaults.orientationRaw,
                    mediaType: preparedClip.mediaType
                )
            } catch {
                print("[OnboardingPreview] Failed to persist prepared clip:", error.localizedDescription)
            }
        }
    }

    private func fetchCandidateAssets(predicate: NSPredicate) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = predicate

        let fetch = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    private func fetchPhotoTimeline() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return PHAsset.fetchAssets(with: options)
    }

    private func loadAssets(for slides: [OnboardingPreviewSlide]) -> [PHAsset] {
        let identifiers = slides.map(\.localIdentifier)
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsByIdentifier: [String: PHAsset] = [:]
        fetchResult.enumerateObjects { asset, _, _ in
            assetsByIdentifier[asset.localIdentifier] = asset
        }
        return identifiers.compactMap { assetsByIdentifier[$0] }
    }

    private func selectAssets(from assets: [PHAsset], limit: Int) -> [PHAsset] {
        guard assets.count > limit else {
            return assets
                .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        }

        let selectedCandidates = Self.yearBalancedCandidates(
            from: samplingCandidates(from: assets),
            limit: limit
        )

        return selectedCandidates
            .map { assets[$0.fetchIndex] }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    }

    private func samplingCandidates(from assets: [PHAsset]) -> [SamplingCandidate] {
        assets.enumerated().map { index, asset in
            SamplingCandidate(
                localIdentifier: asset.localIdentifier,
                date: asset.creationDate ?? .distantPast,
                fetchIndex: index
            )
        }
    }

    private func samplingCandidates(from fetchResult: PHFetchResult<PHAsset>) -> [SamplingCandidate] {
        var candidates: [SamplingCandidate] = []
        candidates.reserveCapacity(fetchResult.count)

        fetchResult.enumerateObjects { asset, index, _ in
            candidates.append(
                SamplingCandidate(
                    localIdentifier: asset.localIdentifier,
                    date: asset.creationDate ?? .distantPast,
                    fetchIndex: index
                )
            )
        }

        return candidates
    }

    private func makeTimelineEntries(from assets: [PHAsset]) -> [OnboardingPreviewTimelineEntry] {
        let framesPerPhoto = Self.timelapseFrameDistribution(
            assetCount: assets.count,
            totalDuration: timelapseTotalDuration,
            frameRate: timelapseFrameRate
        )

        return zip(assets, framesPerPhoto).map { asset, frameCount in
            OnboardingPreviewTimelineEntry(
                localIdentifier: asset.localIdentifier,
                date: asset.creationDate ?? Date(),
                duration: Double(frameCount) / Double(timelapseFrameRate)
            )
        }
    }

    private func makeTimelineEntries(
        from preparedClips: [OnboardingPreparedClip]
    ) -> [OnboardingPreviewTimelineEntry] {
        preparedClips.compactMap { preparedClip in
            guard let localIdentifier = preparedClip.sourceLocalID else { return nil }
            return OnboardingPreviewTimelineEntry(
                localIdentifier: localIdentifier,
                date: preparedClip.date,
                duration: preparedClip.duration
            )
        }
    }

    private func prepareClips(
        from assets: [PHAsset],
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> [OnboardingPreparedClip] {
        let total = max(Double(assets.count), 1)
        var preparedClips = Array<OnboardingPreparedClip?>(repeating: nil, count: assets.count)
        var completed = 0
        var nextIndex = 0

        return await withTaskGroup(of: (Int, OnboardingPreparedClip?).self) { group in
            func enqueue(_ index: Int) {
                let asset = assets[index]
                group.addTask {
                    do {
                        return (index, try await prepareClip(from: asset))
                    } catch {
                        print("[OnboardingPreview] Failed to prepare asset:", error.localizedDescription)
                        return (index, nil)
                    }
                }
            }

            let initialBatch = min(previewPrepareConcurrency, assets.count)
            for _ in 0..<initialBatch {
                enqueue(nextIndex)
                nextIndex += 1
            }

            while let (index, preparedClip) = await group.next() {
                preparedClips[index] = preparedClip
                completed += 1

                let fraction = 0.12 + (Double(completed) / total) * 0.78
                await progress(fraction)

                if nextIndex < assets.count {
                    enqueue(nextIndex)
                    nextIndex += 1
                }
            }

            return preparedClips.compactMap { $0 }
        }
    }

    private func selectLocalTimelineAssets(
        from fetchResult: PHFetchResult<PHAsset>,
        limit: Int,
        progress: @escaping @MainActor (Double) -> Void = { _ in },
        seedAsset: @escaping (PHAsset?) -> Void = { _ in }
    ) async -> [PHAsset] {
        let candidates = Self.candidatesWithinTrailingYears(
            from: samplingCandidates(from: fetchResult),
            yearsBack: timelapseLookbackYears
        )
        guard !candidates.isEmpty else { return [] }

        await progress(0.08)

        let targetCount = min(limit, candidates.count)
        let probeIndices = Self.timeSpacedProbeIndices(
            from: candidates,
            targetCount: targetCount,
            maxProbes: candidates.count
        )
        guard !probeIndices.isEmpty else { return [] }

        let total = max(Double(probeIndices.count), 1)
        var results = Array<PHAsset??>(repeating: nil, count: probeIndices.count)
        var completed = 0
        var nextIndex = 0
        var didPublishSeed = false

        func settledLocalPrefix(
            from results: [PHAsset??],
            targetCount: Int
        ) -> [PHAsset]? {
            var locals: [PHAsset] = []
            locals.reserveCapacity(targetCount)

            for result in results {
                guard let result else { return nil }
                if let asset = result {
                    locals.append(asset)
                    if locals.count >= targetCount {
                        return locals
                    }
                }
            }

            return nil
        }

        func settledLeadingLocalAsset(from results: [PHAsset??]) -> PHAsset? {
            for result in results {
                guard let result else { return nil }
                if let asset = result {
                    return asset
                }
            }

            return nil
        }

        return await withTaskGroup(of: (Int, PHAsset?).self) { group in
            func enqueue(_ index: Int) {
                let fetchIndex = probeIndices[index]
                let asset = fetchResult.object(at: fetchIndex)
                group.addTask {
                    let isLocal = await isLocallyAvailablePhotoAsset(asset)
                    return (index, isLocal ? asset : nil)
                }
            }

            let initialBatch = min(localPhotoProbeConcurrency, probeIndices.count)
            for _ in 0..<initialBatch {
                enqueue(nextIndex)
                nextIndex += 1
            }

            while let (index, asset) = await group.next() {
                results[index] = asset
                completed += 1

                let fraction = 0.08 + (Double(completed) / total) * 0.14
                await progress(fraction)

                if !didPublishSeed, let seed = settledLeadingLocalAsset(from: results) {
                    didPublishSeed = true
                    seedAsset(seed)
                }

                if let locals = settledLocalPrefix(from: results, targetCount: targetCount) {
                    group.cancelAll()
                    return locals.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
                }

                if nextIndex < probeIndices.count {
                    enqueue(nextIndex)
                    nextIndex += 1
                }
            }

            if !didPublishSeed {
                seedAsset(nil)
            }

            return results
                .compactMap { $0 ?? nil }
                .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        }
    }

    private func selectLocalTimelapseAssets(
        from fetchResult: PHFetchResult<PHAsset>,
        limit: Int,
        progress: @escaping @MainActor (Double) -> Void
    ) async -> [PHAsset] {
        guard fetchResult.count > 0 else { return [] }

        let candidates = samplingCandidates(from: fetchResult)
        let yearBuckets = Self.groupedCandidatesByYear(from: candidates, calendar: .current)
        guard !yearBuckets.isEmpty else { return [] }

        let desiredPerYear = max(limit / yearBuckets.count, 1)
        let probePlan = Self.uniformYearProbePlan(from: yearBuckets, desiredPerYear: desiredPerYear)
        guard !probePlan.isEmpty else { return [] }

        let yearIndexByFetchIndex = Dictionary(
            uniqueKeysWithValues: yearBuckets.enumerated().flatMap { yearIndex, bucket in
                bucket.map { ($0.fetchIndex, yearIndex) }
            }
        )

        let total = max(Double(probePlan.count), 1)
        var completed = 0
        var nextIndex = 0
        var localAssetsByYear = Array(repeating: [PHAsset](), count: yearBuckets.count)
        var seen = Set<String>()

        return await withTaskGroup(of: (Int, Int, PHAsset, Bool).self) { group in
            func enqueue(_ probeIndex: Int) {
                let candidate = probePlan[probeIndex]
                let asset = fetchResult.object(at: candidate.fetchIndex)
                let yearIndex = yearIndexByFetchIndex[candidate.fetchIndex] ?? 0
                group.addTask {
                    (probeIndex, yearIndex, asset, await isLocallyAvailablePhotoAsset(asset))
                }
            }

            let initialBatch = min(localPhotoProbeConcurrency, probePlan.count)
            for _ in 0..<initialBatch {
                enqueue(nextIndex)
                nextIndex += 1
            }

            while let (_, yearIndex, asset, isLocal) = await group.next() {
                completed += 1

                if isLocal, seen.insert(asset.localIdentifier).inserted {
                    localAssetsByYear[yearIndex].append(asset)
                    if localAssetsByYear.allSatisfy({ $0.count >= desiredPerYear }) {
                        group.cancelAll()
                        await progress(0.10)
                        return finalizeUniformYearSelection(
                            from: localAssetsByYear,
                            limit: limit
                        )
                    }
                }

                let fraction = 0.02 + (Double(completed) / total) * 0.08
                await progress(fraction)

                if nextIndex < probePlan.count {
                    enqueue(nextIndex)
                    nextIndex += 1
                }
            }

            return finalizeUniformYearSelection(
                from: localAssetsByYear,
                limit: limit
            )
        }
    }

    private func finalizeUniformYearSelection(
        from localAssetsByYear: [[PHAsset]],
        limit: Int
    ) -> [PHAsset] {
        let activeBuckets = localAssetsByYear
            .map { assets in
                assets.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            }
            .filter { !$0.isEmpty }
        guard !activeBuckets.isEmpty else { return [] }

        let desiredPerYear = limit / activeBuckets.count
        guard desiredPerYear > 0 else { return [] }

        let actualPerYear = min(
            desiredPerYear,
            activeBuckets.map(\.count).min() ?? 0
        )
        guard actualPerYear > 0 else { return [] }

        return activeBuckets
            .flatMap { bucket in
                Self.evenlySpacedIndices(count: bucket.count, samples: actualPerYear)
                    .map { bucket[$0] }
            }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
    }

    static func evenlySpacedIndices(count: Int, samples: Int) -> [Int] {
        guard count > 0, samples > 0 else { return [] }
        guard samples > 1 else { return [max(0, count / 2)] }

        let maxIndex = count - 1
        var indices: [Int] = []
        var seen = Set<Int>()

        for sample in 0..<samples {
            let position = Int(round(Double(sample) * Double(maxIndex) / Double(samples - 1)))
            if seen.insert(position).inserted {
                indices.append(position)
            }
        }

        return indices
    }

    static func yearBalancedAllocations(capacities: [Int], total: Int) -> [Int] {
        guard !capacities.isEmpty else { return [] }
        guard total > 0 else { return Array(repeating: 0, count: capacities.count) }

        var allocations = Array(repeating: 0, count: capacities.count)
        let availableIndices = capacities.indices.filter { capacities[$0] > 0 }
        guard !availableIndices.isEmpty else { return allocations }

        if total <= availableIndices.count {
            for offset in evenlySpacedIndices(count: availableIndices.count, samples: total) {
                allocations[availableIndices[offset]] = 1
            }
            return allocations
        }

        for index in availableIndices {
            allocations[index] = 1
        }

        var remaining = total - availableIndices.count
        while remaining > 0 {
            let eligible = availableIndices.filter { allocations[$0] < capacities[$0] }
            guard !eligible.isEmpty else { break }

            let roundCount = min(remaining, eligible.count)
            for offset in evenlySpacedIndices(count: eligible.count, samples: roundCount) {
                allocations[eligible[offset]] += 1
            }
            remaining -= roundCount
        }

        return allocations
    }

    static func yearBalancedCandidates(
        from candidates: [SamplingCandidate],
        limit: Int,
        calendar: Calendar = .current
    ) -> [SamplingCandidate] {
        guard limit > 0, !candidates.isEmpty else { return [] }
        guard candidates.count > limit else {
            return candidates.sorted { $0.date < $1.date }
        }

        let buckets = groupedCandidatesByYear(from: candidates, calendar: calendar)
        let allocations = yearBalancedAllocations(
            capacities: buckets.map(\.count),
            total: min(limit, candidates.count)
        )

        var selected: [SamplingCandidate] = []
        for (bucket, allocation) in zip(buckets, allocations) where allocation > 0 {
            for offset in evenlySpacedIndices(count: bucket.count, samples: allocation) {
                selected.append(bucket[offset])
            }
        }

        return selected.sorted { $0.date < $1.date }
    }

    static func yearBalancedProbeIndices(
        from candidates: [SamplingCandidate],
        targetCount: Int,
        maxProbes: Int,
        calendar: Calendar = .current
    ) -> [Int] {
        guard targetCount > 0, maxProbes > 0, !candidates.isEmpty else { return [] }

        let buckets = groupedCandidatesByYear(from: candidates, calendar: calendar)
        let allocations = yearBalancedAllocations(
            capacities: buckets.map(\.count),
            total: min(targetCount, candidates.count)
        )

        let anchorPositionsByBucket: [[Int]] = zip(buckets, allocations).map { bucket, allocation in
            guard allocation > 0 else { return [] }
            return evenlySpacedIndices(count: bucket.count, samples: allocation)
        }

        var probeIndices: [Int] = []
        var seen = Set<Int>()

        func append(_ candidate: SamplingCandidate) {
            guard seen.insert(candidate.fetchIndex).inserted else { return }
            probeIndices.append(candidate.fetchIndex)
        }

        let maxAnchorCount = anchorPositionsByBucket.map(\.count).max() ?? 0
        for anchorRound in 0..<maxAnchorCount {
            for bucketIndex in buckets.indices {
                let anchors = anchorPositionsByBucket[bucketIndex]
                guard anchors.indices.contains(anchorRound) else { continue }
                append(buckets[bucketIndex][anchors[anchorRound]])
                if probeIndices.count >= maxProbes {
                    return probeIndices
                }
            }
        }

        let maxBucketCount = buckets.map(\.count).max() ?? 0
        guard maxBucketCount > 1 else { return probeIndices }

        for distance in 1..<maxBucketCount {
            var addedAtDistance = false

            for bucketIndex in buckets.indices {
                let bucket = buckets[bucketIndex]
                let anchors = anchorPositionsByBucket[bucketIndex]
                guard !anchors.isEmpty else { continue }

                for anchor in anchors {
                    let before = anchor - distance
                    if before >= 0 {
                        let previousCount = probeIndices.count
                        append(bucket[before])
                        addedAtDistance = addedAtDistance || probeIndices.count != previousCount
                        if probeIndices.count >= maxProbes {
                            return probeIndices
                        }
                    }

                    let after = anchor + distance
                    if after < bucket.count {
                        let previousCount = probeIndices.count
                        append(bucket[after])
                        addedAtDistance = addedAtDistance || probeIndices.count != previousCount
                        if probeIndices.count >= maxProbes {
                            return probeIndices
                        }
                    }
                }
            }

            if !addedAtDistance {
                break
            }
        }

        return probeIndices
    }

    static func timeSpacedProbeIndices(
        from candidates: [SamplingCandidate],
        targetCount: Int,
        maxProbes: Int
    ) -> [Int] {
        guard targetCount > 0, maxProbes > 0, !candidates.isEmpty else { return [] }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            if lhs.date == rhs.date {
                return lhs.fetchIndex < rhs.fetchIndex
            }
            return lhs.date < rhs.date
        }
        let anchorIndices = evenlySpacedIndices(
            count: sortedCandidates.count,
            samples: min(targetCount, sortedCandidates.count)
        )

        var probeIndices: [Int] = []
        var seen = Set<Int>()

        func append(sortedIndex: Int) {
            guard sortedCandidates.indices.contains(sortedIndex) else { return }
            let fetchIndex = sortedCandidates[sortedIndex].fetchIndex
            guard seen.insert(fetchIndex).inserted else { return }
            probeIndices.append(fetchIndex)
        }

        for anchorIndex in anchorIndices {
            append(sortedIndex: anchorIndex)
            if probeIndices.count >= maxProbes {
                return probeIndices
            }
        }

        guard sortedCandidates.count > 1 else { return probeIndices }

        for distance in 1..<sortedCandidates.count {
            var addedAtDistance = false

            for anchorIndex in anchorIndices {
                let before = anchorIndex - distance
                if before >= 0 {
                    let previousCount = probeIndices.count
                    append(sortedIndex: before)
                    addedAtDistance = addedAtDistance || probeIndices.count != previousCount
                    if probeIndices.count >= maxProbes {
                        return probeIndices
                    }
                }

                let after = anchorIndex + distance
                if after < sortedCandidates.count {
                    let previousCount = probeIndices.count
                    append(sortedIndex: after)
                    addedAtDistance = addedAtDistance || probeIndices.count != previousCount
                    if probeIndices.count >= maxProbes {
                        return probeIndices
                    }
                }
            }

            if !addedAtDistance {
                break
            }
        }

        return probeIndices
    }

    static func uniformYearlyCandidates(
        from candidates: [SamplingCandidate],
        limit: Int,
        calendar: Calendar = .current
    ) -> [SamplingCandidate] {
        let yearBuckets = groupedCandidatesByYear(from: candidates, calendar: calendar)
        return uniformYearlyCandidates(from: yearBuckets, limit: limit)
    }

    static func timeSpacedCandidates(
        from candidates: [SamplingCandidate],
        limit: Int
    ) -> [SamplingCandidate] {
        guard limit > 0, !candidates.isEmpty else { return [] }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            if lhs.date == rhs.date {
                return lhs.fetchIndex < rhs.fetchIndex
            }
            return lhs.date < rhs.date
        }
        guard sortedCandidates.count > limit else { return sortedCandidates }

        let earliest = sortedCandidates[0].date
        let latest = sortedCandidates[sortedCandidates.count - 1].date
        let totalDuration = latest.timeIntervalSince(earliest)

        if totalDuration <= 0 {
            return evenlySpacedIndices(count: sortedCandidates.count, samples: limit)
                .map { sortedCandidates[$0] }
        }

        let targetCount = min(limit, sortedCandidates.count)
        var selectedIndices: [Int] = []
        selectedIndices.reserveCapacity(targetCount)
        var used = Set<Int>()

        for slot in 0..<targetCount {
            let fraction = targetCount == 1 ? 0.5 : Double(slot) / Double(targetCount - 1)
            let targetDate = earliest.addingTimeInterval(totalDuration * fraction)
            let insertionIndex = lowerBound(
                in: sortedCandidates,
                targetDate: targetDate
            )

            if let chosenIndex = nearestUnusedIndex(
                in: sortedCandidates,
                targetDate: targetDate,
                insertionIndex: insertionIndex,
                used: used
            ) {
                used.insert(chosenIndex)
                selectedIndices.append(chosenIndex)
            }
        }

        if selectedIndices.count < targetCount {
            for fallbackIndex in evenlySpacedIndices(count: sortedCandidates.count, samples: targetCount) {
                guard used.insert(fallbackIndex).inserted else { continue }
                selectedIndices.append(fallbackIndex)
                if selectedIndices.count >= targetCount {
                    break
                }
            }
        }

        return selectedIndices
            .sorted()
            .map { sortedCandidates[$0] }
    }

    static func candidatesWithinTrailingYears(
        from candidates: [SamplingCandidate],
        yearsBack: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [SamplingCandidate] {
        guard yearsBack > 0, !candidates.isEmpty else { return [] }
        guard let cutoff = calendar.date(byAdding: .year, value: -yearsBack, to: now) else {
            return candidates
        }

        return candidates.filter { $0.date >= cutoff }
    }

    static func uniformYearProbePlan(
        from candidates: [SamplingCandidate],
        limit: Int,
        calendar: Calendar = .current
    ) -> [SamplingCandidate] {
        let yearBuckets = groupedCandidatesByYear(from: candidates, calendar: calendar)
        guard !yearBuckets.isEmpty else { return [] }
        let desiredPerYear = max(limit / yearBuckets.count, 1)
        return uniformYearProbePlan(from: yearBuckets, desiredPerYear: desiredPerYear)
    }

    private static func uniformYearlyCandidates(
        from yearBuckets: [[SamplingCandidate]],
        limit: Int
    ) -> [SamplingCandidate] {
        let activeBuckets = yearBuckets.filter { !$0.isEmpty }
        guard !activeBuckets.isEmpty else { return [] }

        let desiredPerYear = limit / activeBuckets.count
        guard desiredPerYear > 0 else { return [] }

        let actualPerYear = min(
            desiredPerYear,
            activeBuckets.map(\.count).min() ?? 0
        )
        guard actualPerYear > 0 else { return [] }

        return activeBuckets
            .flatMap { bucket in
                evenlySpacedIndices(count: bucket.count, samples: actualPerYear)
                    .map { bucket[$0] }
            }
            .sorted { $0.date < $1.date }
    }

    private static func uniformYearProbePlan(
        from yearBuckets: [[SamplingCandidate]],
        desiredPerYear: Int
    ) -> [SamplingCandidate] {
        let probeOrders = yearBuckets.map { bucket in
            coverageOrderedCandidates(in: bucket, anchorCount: desiredPerYear)
        }

        let maxProbeDepth = probeOrders.map(\.count).max() ?? 0
        var ordered: [SamplingCandidate] = []
        ordered.reserveCapacity(probeOrders.reduce(0) { $0 + $1.count })

        for probeDepth in 0..<maxProbeDepth {
            for probeOrder in probeOrders where probeDepth < probeOrder.count {
                ordered.append(probeOrder[probeDepth])
            }
        }

        return ordered
    }

    private static func coverageOrderedCandidates(
        in bucket: [SamplingCandidate],
        anchorCount: Int
    ) -> [SamplingCandidate] {
        guard !bucket.isEmpty else { return [] }

        let anchorIndices = evenlySpacedIndices(
            count: bucket.count,
            samples: min(max(anchorCount, 1), bucket.count)
        )

        var ordered: [SamplingCandidate] = []
        var seen = Set<Int>()

        func append(index: Int) {
            guard bucket.indices.contains(index) else { return }
            guard seen.insert(index).inserted else { return }
            ordered.append(bucket[index])
        }

        for anchorIndex in anchorIndices {
            append(index: anchorIndex)
        }

        guard bucket.count > 1 else { return ordered }

        for distance in 1..<bucket.count {
            var addedAtDistance = false

            for anchorIndex in anchorIndices {
                let before = anchorIndex - distance
                if before >= 0 {
                    let previousCount = ordered.count
                    append(index: before)
                    addedAtDistance = addedAtDistance || ordered.count != previousCount
                }

                let after = anchorIndex + distance
                if after < bucket.count {
                    let previousCount = ordered.count
                    append(index: after)
                    addedAtDistance = addedAtDistance || ordered.count != previousCount
                }
            }

            if !addedAtDistance {
                break
            }
        }

        return ordered
    }

    private static func lowerBound(
        in sortedCandidates: [SamplingCandidate],
        targetDate: Date
    ) -> Int {
        var low = 0
        var high = sortedCandidates.count

        while low < high {
            let mid = (low + high) / 2
            if sortedCandidates[mid].date < targetDate {
                low = mid + 1
            } else {
                high = mid
            }
        }

        return low
    }

    private static func nearestUnusedIndex(
        in sortedCandidates: [SamplingCandidate],
        targetDate: Date,
        insertionIndex: Int,
        used: Set<Int>
    ) -> Int? {
        var left = insertionIndex - 1
        var right = insertionIndex

        while left >= 0 || right < sortedCandidates.count {
            let leftCandidate: (index: Int, distance: TimeInterval)? = {
                guard left >= 0, !used.contains(left) else { return nil }
                return (left, abs(sortedCandidates[left].date.timeIntervalSince(targetDate)))
            }()

            let rightCandidate: (index: Int, distance: TimeInterval)? = {
                guard right < sortedCandidates.count, !used.contains(right) else { return nil }
                return (right, abs(sortedCandidates[right].date.timeIntervalSince(targetDate)))
            }()

            switch (leftCandidate, rightCandidate) {
            case let (.some(leftValue), .some(rightValue)):
                return leftValue.distance <= rightValue.distance ? leftValue.index : rightValue.index
            case let (.some(leftValue), .none):
                return leftValue.index
            case let (.none, .some(rightValue)):
                return rightValue.index
            case (.none, .none):
                left -= 1
                right += 1
            }
        }

        return nil
    }

    private static func groupedCandidatesByYear(
        from candidates: [SamplingCandidate],
        calendar: Calendar
    ) -> [[SamplingCandidate]] {
        let buckets = Dictionary(grouping: candidates) {
            calendar.component(.year, from: $0.date)
        }

        return buckets.keys.sorted().map { year in
            (buckets[year] ?? [])
                .sorted { $0.date < $1.date }
        }
    }

    private func prepareClip(from asset: PHAsset) async throws -> OnboardingPreparedClip {
        let day = Calendar.current.startOfDay(for: asset.creationDate ?? Date())
        let mediaConfig = previewMediaConfig

        if asset.mediaSubtypes.contains(.photoLive) {
            let livePhotoURL = try await LivePhotoProcessor.extractLivePhotoVideo(
                from: asset,
                maxDuration: mixedClipDuration
            )
            let exportedURL = try await VideoEditEngine.exportVideo(
                from: livePhotoURL,
                trimTo: nil,
                crop: mediaConfig.crop,
                mode: mediaConfig.mode
            )
            let duration = try await AVURLAsset(url: exportedURL).load(.duration).seconds
            return OnboardingPreparedClip(
                tempURL: exportedURL,
                date: day,
                duration: duration,
                sourceLocalID: asset.localIdentifier,
                mediaType: .livePhoto
            )
        }

        if asset.mediaType == .video {
            let sourceURL = try await asset.fileURL()
            let exportedURL = try await VideoEditEngine.exportVideo(
                from: sourceURL,
                trimTo: mixedClipDuration,
                crop: mediaConfig.crop,
                mode: mediaConfig.mode
            )
            let duration = try await AVURLAsset(url: exportedURL).load(.duration).seconds
            return OnboardingPreparedClip(
                tempURL: exportedURL,
                date: day,
                duration: duration,
                sourceLocalID: asset.localIdentifier,
                mediaType: .video
            )
        }

        let data = try await asset.requestImageData()
        guard let image = UIImage(data: data)?.fixedOrientation() else {
            throw OnboardingPreviewServiceError.invalidImageData
        }

        let exportedURL = try await VideoEditEngine.exportStillKenBurns(
            image,
            duration: mixedClipDuration,
            renderSize: mediaConfig.renderSize,
            fps: 30,
            zoomStart: 1.01,
            zoomEnd: 1.10,
            panStart: CGPoint(x: 0.50, y: 0.44),
            panEnd: CGPoint(x: 0.50, y: 0.56)
        )
        let duration = try await AVURLAsset(url: exportedURL).load(.duration).seconds
        return OnboardingPreparedClip(
            tempURL: exportedURL,
            date: day,
            duration: duration,
            sourceLocalID: asset.localIdentifier,
            mediaType: .photo
        )
    }

    private func buildPhotoTimelapseVideo(
        from assets: [PHAsset],
        progress: @escaping @MainActor (Double) async -> Void
    ) async throws -> (videoURL: URL, preparedClips: [OnboardingPreparedClip]) {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("onboarding-photo-timelapse-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(timelapseRenderSize.width),
            AVVideoHeightKey: Int(timelapseRenderSize.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(timelapseRenderSize.width),
                kCVPixelBufferHeightKey as String: Int(timelapseRenderSize.height)
            ]
        )

        guard writer.canAdd(input) else {
            throw OnboardingPreviewServiceError.exportFailed
        }
        writer.add(input)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let framesPerPhoto = Self.timelapseFrameDistribution(
            assetCount: assets.count,
            totalDuration: timelapseTotalDuration,
            frameRate: timelapseFrameRate
        )
        let frameStep = CMTime(value: 1, timescale: timelapseFrameRate)
        let total = max(Double(assets.count), 1)
        var presentationTime = CMTime.zero
        var preparedClips: [OnboardingPreparedClip] = []

        for (index, asset) in assets.enumerated() {
            do {
                let image = try await requestPreviewImage(for: asset, targetSize: timelapseRenderSize)
                let pixelBuffer = try makePixelBuffer(from: image, renderSize: timelapseRenderSize)
                let frameCount = framesPerPhoto[index]

                for _ in 0..<frameCount {
                    while !input.isReadyForMoreMediaData {
                        try await Task.sleep(nanoseconds: 2_000_000)
                    }

                    guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                        throw writer.error ?? OnboardingPreviewServiceError.exportFailed
                    }
                    presentationTime = presentationTime + frameStep
                }

                preparedClips.append(
                    OnboardingPreparedClip(
                        tempURL: outputURL,
                        date: Calendar.current.startOfDay(for: asset.creationDate ?? Date()),
                        duration: Double(frameCount) / Double(timelapseFrameRate),
                        sourceLocalID: asset.localIdentifier,
                        mediaType: .photo
                    )
                )
            } catch {
                print("[OnboardingPreview] Failed to prepare timelapse photo:", error.localizedDescription)
            }

            let fraction = 0.12 + (Double(index + 1) / total) * 0.80
            await progress(fraction)
        }

        guard !preparedClips.isEmpty else {
            writer.cancelWriting()
            throw OnboardingPreviewServiceError.noPreparedClips
        }

        input.markAsFinished()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .completed {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(
                        throwing: writer.error ?? OnboardingPreviewServiceError.exportFailed
                    )
                }
            }
        }

        return (outputURL, preparedClips)
    }

    private func buildPreviewComposition(
        from preparedClips: [OnboardingPreparedClip]
    ) async throws -> (AVMutableComposition, AVMutableVideoComposition, AVAudioMix?) {
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw OnboardingPreviewServiceError.missingTrack("video")
        }

        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var cursor = CMTime.zero
        var hasOriginalAudio = false

        for preparedClip in preparedClips {
            let asset = AVURLAsset(url: preparedClip.tempURL)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)

            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                continue
            }

            try compositionVideoTrack.insertTimeRange(range, of: videoTrack, at: cursor)

            if let assetAudioTrack = try await asset.loadTracks(withMediaType: .audio).first,
               let compositionAudioTrack {
                try? compositionAudioTrack.insertTimeRange(range, of: assetAudioTrack, at: cursor)
                hasOriginalAudio = true
            }

            cursor = cursor + duration
        }

        guard cursor > .zero else { throw OnboardingPreviewServiceError.noPreparedClips }

        let videoComposition = AVMutableVideoComposition(propertiesOf: composition)
        videoComposition.renderSize = mixedRenderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let musicTrackURL = try resolvePreviewTrackURL()
        let audioMix = try await buildAudioMix(
            for: composition,
            existingAudioTrack: compositionAudioTrack,
            hasOriginalAudio: hasOriginalAudio,
            musicTrackURL: musicTrackURL,
            totalDuration: cursor
        )

        return (composition, videoComposition, audioMix)
    }

    private func buildPreviewComposition(
        from sourceVideoURL: URL,
        renderSize: CGSize,
        frameDuration: CMTime
    ) async throws -> (AVMutableComposition, AVMutableVideoComposition, AVAudioMix?) {
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw OnboardingPreviewServiceError.missingTrack("video")
        }

        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        let asset = AVURLAsset(url: sourceVideoURL)
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw OnboardingPreviewServiceError.missingTrack("video")
        }

        try compositionVideoTrack.insertTimeRange(range, of: videoTrack, at: .zero)

        var hasOriginalAudio = false
        if let assetAudioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack {
            try? compositionAudioTrack.insertTimeRange(range, of: assetAudioTrack, at: .zero)
            hasOriginalAudio = true
        }

        let videoComposition = AVMutableVideoComposition(propertiesOf: composition)
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = frameDuration

        let musicTrackURL = try resolvePreviewTrackURL()
        let audioMix = try await buildAudioMix(
            for: composition,
            existingAudioTrack: compositionAudioTrack,
            hasOriginalAudio: hasOriginalAudio,
            musicTrackURL: musicTrackURL,
            totalDuration: duration
        )

        return (composition, videoComposition, audioMix)
    }

    private func requestPreviewImage(for asset: PHAsset, targetSize: CGSize) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = false
            options.version = .current

            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                guard !resumed else { return }

                if let cancelled = info?[PHImageCancelledKey] as? NSNumber, cancelled.boolValue {
                    resumed = true
                    continuation.resume(throwing: CancellationError())
                    return
                }

                if let error = info?[PHImageErrorKey] as? Error {
                    resumed = true
                    continuation.resume(throwing: error)
                    return
                }

                let isDegraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                if isDegraded {
                    return
                }

                guard let image else {
                    resumed = true
                    continuation.resume(throwing: OnboardingPreviewServiceError.invalidImageData)
                    return
                }

                resumed = true
                continuation.resume(returning: image.fixedOrientation())
            }
        }
    }

    private func isLocallyAvailablePhotoAsset(_ asset: PHAsset) async -> Bool {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .fastFormat

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? (data == nil)
                continuation.resume(returning: !isInCloud)
            }
        }
    }

    private func makePixelBuffer(from image: UIImage, renderSize: CGSize) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(renderSize.width),
            Int(renderSize.height),
            kCVPixelFormatType_32ARGB,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw OnboardingPreviewServiceError.exportFailed
        }

        guard let cgImage = image.cgImage else {
            throw OnboardingPreviewServiceError.invalidImageData
        }

        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let scale = max(renderSize.width / imageWidth, renderSize.height / imageHeight)
        let drawWidth = (imageWidth * scale).rounded()
        let drawHeight = (imageHeight * scale).rounded()
        let drawRect = CGRect(
            x: ((renderSize.width - drawWidth) / 2).rounded(),
            y: ((renderSize.height - drawHeight) / 2).rounded(),
            width: drawWidth,
            height: drawHeight
        )

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(renderSize.width),
            height: Int(renderSize.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            throw OnboardingPreviewServiceError.exportFailed
        }

        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: renderSize))
        context.interpolationQuality = .high
        context.draw(cgImage, in: drawRect)
        return pixelBuffer
    }

    private func buildAudioMix(
        for composition: AVMutableComposition,
        existingAudioTrack: AVMutableCompositionTrack?,
        hasOriginalAudio: Bool,
        musicTrackURL: URL,
        totalDuration: CMTime
    ) async throws -> AVAudioMix? {
        var inputParameters: [AVMutableAudioMixInputParameters] = []

        if hasOriginalAudio, let existingAudioTrack {
            let originalAudio = AVMutableAudioMixInputParameters(track: existingAudioTrack)
            originalAudio.setVolume(0.18, at: .zero)
            inputParameters.append(originalAudio)
        }

        let musicAsset = AVURLAsset(url: musicTrackURL)
        guard let musicTrack = try await musicAsset.loadTracks(withMediaType: .audio).first else {
            throw OnboardingPreviewServiceError.missingTrack("music")
        }
        let musicDuration = try await musicAsset.load(.duration)

        if let compositionMusicTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) {
            var insertAt = CMTime.zero
            while insertAt < totalDuration {
                let remaining = totalDuration - insertAt
                let chunk = CMTimeMinimum(remaining, musicDuration)
                try compositionMusicTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: chunk),
                    of: musicTrack,
                    at: insertAt
                )
                insertAt = insertAt + chunk
            }

            let musicAudio = AVMutableAudioMixInputParameters(track: compositionMusicTrack)
            musicAudio.setVolume(0.82, at: .zero)
            inputParameters.append(musicAudio)
        }

        guard !inputParameters.isEmpty else { return nil }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = inputParameters
        return audioMix
    }

    private func exportPreview(
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        audioMix: AVAudioMix?,
        timeline: [OnboardingPreviewTimelineEntry],
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("onboarding-preview-\(UUID().uuidString).mp4")

        try? FileManager.default.removeItem(at: outputURL)

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw OnboardingPreviewServiceError.exportFailed
        }

        let exportVideoComposition: AVMutableVideoComposition
        if let copiedVideoComposition = videoComposition.copy() as? AVMutableVideoComposition {
            exportVideoComposition = copiedVideoComposition
        } else {
            exportVideoComposition = AVMutableVideoComposition(propertiesOf: composition)
            exportVideoComposition.renderSize = videoComposition.renderSize
            exportVideoComposition.frameDuration = videoComposition.frameDuration
            exportVideoComposition.instructions = videoComposition.instructions
        }

        if !timeline.isEmpty {
            let parentLayer = CALayer()
            parentLayer.frame = CGRect(origin: .zero, size: exportVideoComposition.renderSize)

            let videoLayer = CALayer()
            videoLayer.frame = parentLayer.bounds

            let captionOverlay = MontageService.onboardingPreviewCaptionLayer(
                for: timeline,
                renderSize: exportVideoComposition.renderSize,
                anchor: .bottomLeft,
                captionColor: .white
            )
            captionOverlay.beginTime = AVCoreAnimationBeginTimeAtZero
            captionOverlay.speed = 1

            parentLayer.addSublayer(videoLayer)
            parentLayer.addSublayer(captionOverlay)

            exportVideoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer,
                in: parentLayer
            )
        }

        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = exportVideoComposition
        session.audioMix = audioMix
        session.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

        let progressTask = Task {
            while !Task.isCancelled {
                let status = session.status
                if status != .unknown && status != .waiting && status != .exporting {
                    break
                }

                let exportProgress = 0.88 + Double(session.progress) * 0.12
                await progress(exportProgress.clamped01)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }

        defer { progressTask.cancel() }

        try await withCheckedThrowingContinuation { continuation in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume(returning: ())
                case .failed:
                    continuation.resume(throwing: session.error ?? OnboardingPreviewServiceError.exportFailed)
                case .cancelled:
                    continuation.resume(throwing: OnboardingPreviewServiceError.exportFailed)
                default:
                    continuation.resume(throwing: session.error ?? OnboardingPreviewServiceError.exportFailed)
                }
            }
        }

        return outputURL
    }

    private func resolvePreviewTrackURL() throws -> URL {
        try Self.previewTrackURL(for: previewTrackID)
    }
}
