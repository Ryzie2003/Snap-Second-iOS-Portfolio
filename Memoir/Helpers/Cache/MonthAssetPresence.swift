import Foundation
import Photos
import UIKit

/// Presence of library media for a given day when the app has no saved clip.
enum LibraryPresence: Int, Comparable {
    case none
    case photo
    case livePhoto
    case video

    var badge: DayEmptyBadge? {
        switch self {
        case .video:     return .video
        case .livePhoto: return .livePhoto
        case .photo:     return .photo
        case .none:      return nil
        }
    }
}

extension LibraryPresence {
    static func < (lhs: LibraryPresence, rhs: LibraryPresence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}


/// Caches Photos "presence" per day for a month.
@MainActor
final class MonthAssetPresenceCache: ObservableObject {
    @Published private(set) var map: [Date: LibraryPresence] = [:]
    private var task: Task<Void, Never>?

    func clear() {
        task?.cancel()
        map.removeAll()
    }

    /// Preload presence for a month (monthStart must be 1st-of-month at 00:00).
    func preload(monthStart: Date) {
        task?.cancel()
        let cal = Calendar.current
        let endOfMonth = cal.date(byAdding: DateComponents(month: 1, day: 0), to: monthStart)!
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let presence = await Self.computePresence(monthStart: monthStart, monthEnd: endOfMonth)
            await MainActor.run { self.map.merge(presence, uniquingKeysWith: { a, b in max(a, b) }) }
        }
    }

    func badge(for day: Date) -> DayEmptyBadge? {
        let d = Calendar.current.startOfDay(for: day)
        return map[d]?.badge
    }

    // MARK: - Worker (off-main)
    private static func computePresence(monthStart: Date, monthEnd: Date) async -> [Date: LibraryPresence] {
        var out: [Date: LibraryPresence] = [:]
        let cal = Calendar.current

        // One fetch for the entire month, then bucket by day.
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", monthStart as NSDate, monthEnd as NSDate)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let assets = PHAsset.fetchAssets(with: opts)
        assets.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate else { return }
            let day = cal.startOfDay(for: date)
            let current = out[day] ?? .none

            let newPresence: LibraryPresence = {
                switch asset.mediaType {
                case .video: return .video
                case .image:
                    return asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo
                default: return .none
                }
            }()

            // Keep the strongest presence (video > live > photo > none)
            if newPresence.rawValue > current.rawValue {
                out[day] = newPresence
            }
        }
        return out
    }
}
