import Foundation
import Photos   // ⬅️ instead of CoreData

/// Stateless helper that turns the user's Photos library into
/// "On this day in past years" summary rows for the Rewind tab.
struct RewindEngine {
    struct SelectionKey: Equatable {
        let year: Int
        let mediaPriority: Int
        let creationDate: Date
        let stableID: String
    }

    static func pickOneItemPerYear<Item>(
        from items: [Item],
        selectionKey: (Item) -> SelectionKey
    ) -> [Item] {
        var bestByYear: [Int: (item: Item, key: SelectionKey)] = [:]

        for item in items {
            let key = selectionKey(item)

            if let existing = bestByYear[key.year] {
                if prefers(key, over: existing.key) {
                    bestByYear[key.year] = (item, key)
                }
            } else {
                bestByYear[key.year] = (item, key)
            }
        }

        return bestByYear.values
            .sorted { $0.key.year > $1.key.year }
            .map(\.item)
    }

    /// Build rewind entries by scanning the photo library for assets
    /// shot on this month/day in past years.
    static func buildEntriesFromPhotos(
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> [RewindYearEntry] {
        let matchingAssets = matchingAssetsOnThisDay(today: today, calendar: calendar)
        let countByYear = Dictionary(grouping: matchingAssets, by: {
            calendar.component(.year, from: $0.creationDate ?? .distantPast)
        }).mapValues(\.count)

        let sortedYears = countByYear.keys.sorted(by: >)   // newest → oldest

        return sortedYears.map { year in
            let count = countByYear[year] ?? 0

            let summary: String
            if count == 1 {
                summary = "You captured 1 moment on this day."
            } else {
                summary = "You captured \(count) moments on this day."
            }

            return RewindYearEntry(
                year: year,
                clipCount: count,
                summary: summary
            )
        }
    }

    static func assetsForYearOnThisDay(
        year targetYear: Int,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> [PHAsset] {
        let matchingAssets = matchingAssetsOnThisDay(today: today, calendar: calendar)
            .filter { calendar.component(.year, from: $0.creationDate ?? .distantPast) == targetYear }

        return pickOneItemPerYear(from: matchingAssets) { asset in
            selectionKey(for: asset, calendar: calendar)
        }
    }

    /// Build a single multi-year session containing all clips
    /// from this month/day across all past years, selecting one
    /// representative asset per year.
    static func buildDaySession(
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> RewindDaySession? {
        let selectedAssets = pickOneItemPerYear(
            from: matchingAssetsOnThisDay(today: today, calendar: calendar),
            selectionKey: { asset in
                selectionKey(for: asset, calendar: calendar)
            }
        )
        let allClips = selectedAssets.map {
            RewindDayClip(
                asset: $0,
                year: calendar.component(.year, from: $0.creationDate ?? .distantPast)
            )
        }

        guard !allClips.isEmpty else {
            return nil
        }

        return RewindDaySession(
            date: today,
            clips: allClips
        )
    }

    private static func matchingAssetsOnThisDay(
        today: Date,
        calendar: Calendar
    ) -> [PHAsset] {
        let todayYear = calendar.component(.year, from: today)
        let todayMonth = calendar.component(.month, from: today)
        let todayDay = calendar.component(.day, from: today)
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        var result: [PHAsset] = []
        let assets = PHAsset.fetchAssets(with: options)

        assets.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image else { return }
            guard let date = asset.creationDate else { return }

            let comps = calendar.dateComponents([.year, .month, .day], from: date)
            guard
                let year = comps.year,
                let month = comps.month,
                let day = comps.day
            else { return }

            guard year < todayYear, month == todayMonth, day == todayDay else { return }
            result.append(asset)
        }

        return result
    }

    private static func selectionKey(
        for asset: PHAsset,
        calendar: Calendar
    ) -> SelectionKey {
        SelectionKey(
            year: calendar.component(.year, from: asset.creationDate ?? .distantPast),
            mediaPriority: mediaPriority(for: asset),
            creationDate: asset.creationDate ?? .distantPast,
            stableID: asset.localIdentifier
        )
    }

    private static func mediaPriority(for asset: PHAsset) -> Int {
        if asset.mediaSubtypes.contains(.photoLive) {
            return 1
        }
        return 0
    }

    private static func prefers(_ lhs: SelectionKey, over rhs: SelectionKey) -> Bool {
        if lhs.mediaPriority != rhs.mediaPriority {
            return lhs.mediaPriority > rhs.mediaPriority
        }
        if lhs.creationDate != rhs.creationDate {
            return lhs.creationDate > rhs.creationDate
        }
        return lhs.stableID < rhs.stableID
    }

}
