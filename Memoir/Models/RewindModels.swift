// RewindModels.swift
// Memoir

import Foundation
import Photos

/// One row in the Rewind list, summarizing a single past year
/// for this same month/day as "today".
struct RewindYearEntry: Identifiable {
    let id = UUID()
    let year: Int
    let clipCount: Int
    let summary: String
}

/// Represents an active "On This Day" viewing session for a single year.
struct RewindYearSession: Identifiable {
    let id = UUID()
    let year: Int
    let assets: [PHAsset]
}

/// Represents a single clip in the multi-year "On This Day" session.
struct RewindDayClip: Identifiable {
    let id = UUID()
    let asset: PHAsset
    let year: Int
}

/// Represents all clips across all past years for today's month/day.
struct RewindDaySession: Identifiable {
    let id = UUID()
    let date: Date
    let clips: [RewindDayClip]
}
