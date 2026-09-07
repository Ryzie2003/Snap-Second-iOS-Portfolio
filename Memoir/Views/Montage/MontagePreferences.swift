//
//  MontagePreferences.swift
//  Snap Second
//
//  Preferences persistence for Montage
//

import Foundation
import SwiftUI
import AVFoundation

// Global debounce task storage (per-project)
private var debouncedSaveTasks: [UUID: Task<Void, Never>] = [:]
private let debounceInterval: UInt64 = 300_000_000  // 0.3 seconds in nanoseconds

extension MontageView {
    var prefsKey: String { "montage.prefs.\(project.id)" }

    /// Debounced save - collects rapid changes and saves after 0.3s of inactivity
    func savePrefsDebounced() {
        // Cancel any pending save for this project
        debouncedSaveTasks[project.id]?.cancel()

        // Schedule a new debounced save
        debouncedSaveTasks[project.id] = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: debounceInterval)
                savePrefsImmediate()
            } catch {
                // Task was cancelled, ignore
            }
        }
    }

    /// Immediate save - use for onDisappear and before export
    func savePrefsImmediate() {
        // Cancel any pending debounced save
        debouncedSaveTasks[project.id]?.cancel()
        debouncedSaveTasks[project.id] = nil
        savePrefsInternal()
    }

    /// Alias for backward compatibility - now uses debounced version
    func savePrefs() {
        savePrefsDebounced()
    }

    private func savePrefsInternal() {
        // Decompose Color to RGBA in sRGB
        func rgba(_ color: Color, alpha: Double) -> RGBA {
            let ui = UIColor(color).withAlphaComponent(alpha)
            var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
            ui.getRed(&r, green: &g, blue: &b, alpha: &a)
            return RGBA(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
        }

        let rgbaVals = rgba(captionColor, alpha: captionOpacity)

        let prefs = MontagePrefs(
            style: selectedStyle.rawValue,
            trackID: selectedTrack?.id,
            musicVol: musicVol,
            videoVol: videoVol,
            rangeStart: range.start,
            rangeEnd: range.end,
            rangeLabel: rangeLabel,
            orientation: {
                switch orientation {
                case .v916: return "v916"
                case .s11:  return "s11"
                case .h169: return "h169"
                }
            }(),
            contentMode: (contentMode == .fit ? "fit" : "fill"),
            captionsMode: {
                switch captionMode {
                case .none:     return "none"
                case .dateYear: return "dateYear"
                case .custom:   return "custom"
                }
            }(),
            customCaption: {
                if case .custom = captionMode {
                    let trimmed = customCaptionText.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                return nil
            }(),
            showDates: showDates,
            showBranding: brandingOn,
            captionRGBA: rgbaVals,
            captionOpacity: captionOpacity,
            captionFontSize: captionFontSize,
            captionFont: captionFont.rawValue,
            captionPos: {
                switch captionPos {
                case .bottomLeft:   return "bottomLeft"
                case .bottomCenter: return "bottomCenter"
                case .bottomRight:  return "bottomRight"
                }
            }(),
            exportQuality: exportQuality.rawValue,
            background: backgroundStyle.rawValue,
            captionNormX: Double(captionPosNorm.x).clamped01,
            captionNormY: Double(captionPosNorm.y).clamped01,
            filter: selectedFilter.rawValue,
            speed: speed
        )

        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: prefsKey)
        }
    }

    func loadPrefsIfAny() {
        guard
            let data = UserDefaults.standard.data(forKey: prefsKey),
            let prefs = try? JSONDecoder().decode(MontagePrefs.self, from: data)
        else { return }

        // Music
        if let id = prefs.trackID,
           let t = bundledTracks.first(where: { $0.id == id }) { selectedTrack = t }
        musicVol = prefs.musicVol
        videoVol = prefs.videoVol

        // Range
        if prefs.rangeLabel == "All" {
            range = DateInterval(start: .distantPast, end: .distantFuture)
            rangeLabel = "All"
        } else {
            range = DateInterval(start: prefs.rangeStart, end: prefs.rangeEnd)
            rangeLabel = prefs.rangeLabel
        }

        // Orientation
        switch prefs.orientation {
        case "v916": orientation = .v916
        case "s11":  orientation = .s11
        case "h169": orientation = .h169
        default: break
        }
        contentMode = (prefs.contentMode == "fill" ? .fill : .fit)

        // Captions
        showDates = prefs.showDates
        brandingOn = prefs.showBranding

        switch prefs.captionsMode {
        case "dateYear":
            captionMode = .dateYear

        case "custom":
            let txt = prefs.customCaption ?? ""
            customCaptionText = txt
            captionMode = .custom(customCaptionText)

        default:
            captionMode = .none
        }

        if let q = ExportQuality(rawValue: prefs.exportQuality) {
            exportQuality = (isPro ? q : .standard)
        }

        // Background
        switch prefs.background {
        case "white": self.backgroundStyle = .white
        case "blur":  self.backgroundStyle = .blur
        default:      self.backgroundStyle = .black
        }

        // Rich caption prefs
        let rgba = prefs.captionRGBA
        captionColor = Color(.sRGB,
                             red: rgba.r.clamped01,
                             green: rgba.g.clamped01,
                             blue: rgba.b.clamped01,
                             opacity: rgba.a.clamped01)

        captionOpacity = prefs.captionOpacity
        captionFontSize = prefs.captionFontSize

        if let f = CaptionFontVariant(rawValue: prefs.captionFont) {
            captionFont = f
        }

        // Allow unclamped caption positioning (can be off-screen)
        captionPosNorm = CGPoint(x: prefs.captionNormX, y: prefs.captionNormY)

        switch prefs.captionPos {
        case "bottomLeft":   captionPos = .bottomLeft
        case "bottomRight":  captionPos = .bottomRight
        default:             captionPos = .bottomCenter
        }

        if let styleStr = try? JSONDecoder().decode(MontagePrefs.self, from: data).style,
           let s = MontageStyle(rawValue: styleStr) {
            selectedStyle = s
        }

        if let f = MontageFilter(rawValue: prefs.filter) {
            selectedFilter = f
        } else {
            selectedFilter = .none
        }

        speed = prefs.speed
    }
}
