//
//  MontageTypes.swift
//  Snap Second
//
//  Shared types, enums, and data structures for MontageView
//

import Foundation
import SwiftUI
import AVFoundation

// MARK: - Enums

enum Preset {
    case week, month, year
}

enum Orientation: Hashable {
    case v916, s11, h169
}

enum ControlTab: Hashable, Identifiable {
    case range, music, captions, orientation, quality, watermark, filters, speed
    var id: ControlTab { self }

    var label: String {
        switch self {
        case .range:       return "Range"
        case .music:       return "Music"
        case .captions:    return "Captions"
        case .orientation: return "Aspect"
        case .quality:     return "Quality"
        case .watermark:   return "Watermark"
        case .filters:     return "Filters"
        case .speed:       return "Speed"
        }
    }
}

/// Bottom bar categories for montage editor (CapCut-style grouping)
enum MontageCategory: Hashable, Identifiable, CaseIterable {
    case clips    // Date range / clip selection
    case effects  // Style + Filters
    case audio    // Music + Speed
    case text     // Captions
    case export   // Orientation + Quality + Watermark

    var id: MontageCategory { self }

    var label: String {
        switch self {
        case .clips:   return "Clips"
        case .effects: return "Effects"
        case .audio:   return "Audio"
        case .text:    return "Text"
        case .export:  return "Export"
        }
    }

    var icon: String {
        switch self {
        case .clips:   return "folder"
        case .effects: return "wand.and.stars"
        case .audio:   return "waveform"
        case .text:    return "textformat"
        case .export:  return "square.and.arrow.up"
        }
    }

    /// Controls available within this category
    var controls: [ControlTab] {
        switch self {
        case .clips:   return [.range]
        case .effects: return [.filters, .speed]
        case .audio:   return [.music]
        case .text:    return [.captions]
        case .export:  return [.orientation, .quality, .watermark]
        }
    }
}

/// Export quality options
enum ExportQuality: String, Codable {
    case standard, hd
}

/// Captions mode
enum CaptionKind: Equatable {
    case none
    case dateYear        // per-clip date/year
    case custom(String)  // one-line
}

enum CaptionPos3: String, CaseIterable {
    case bottomLeft, bottomCenter, bottomRight
}

enum CaptionFontVariant: String, Codable, CaseIterable {
    case system, rounded, serif, monospaced
}

enum BlankingPref: String, Codable {
    case none, blur
}

enum BackgroundStyle: String, Codable, CaseIterable {
    case black, white, blur
}

// MARK: - Data Structures

// Note: EditSnapshot removed - we now auto-save all changes immediately
