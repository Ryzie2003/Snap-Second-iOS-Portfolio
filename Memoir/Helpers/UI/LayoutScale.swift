// LayoutScale.swift
import SwiftUI
import UIKit

/// Coarse device buckets you can reuse across the app.
enum LayoutScale {
    case small     // e.g. iPhone SE / mini / smaller-height devices
    case medium    // e.g. iPhone 13 / 14 / 15 non-Max
    case large     // Plus / Max or very tall devices

    // Decide the scale once per screen based on height.
    static func forScreenHeight(_ h: CGFloat = UIScreen.main.bounds.height) -> LayoutScale {
        switch h {
        case ..<800:
            // This will treat iPhone 13 mini as `.small` so things shrink more
            return .small
        case ..<900:
            return .medium
        default:
            return .large
        }
    }

    /// Generic multiplier for font sizes.
    var fontScale: CGFloat {
        switch self {
        case .small:  return 0.9
        case .medium: return 1.0
        case .large:  return 1.05
        }
    }

    /// Generic multiplier for vertical spacing & padding.
    var spacingScale: CGFloat {
        switch self {
        case .small:  return 0.85
        case .medium: return 1.0
        case .large:  return 1.1
        }
    }

    /// How tall the main ProjectsView card should be relative to available height.
    var cardHeightFactor: CGFloat {
        switch self {
        case .small:  return 0.95
        case .medium: return 0.9
        case .large:  return 0.85
        }
    }

    /// Max fraction of the width that a ProjectsView card can occupy.
    var maxCardWidthFraction: CGFloat {
        switch self {
        case .small:  return 0.82
        case .medium: return 0.78
        case .large:  return 0.72
        }
    }

    /// Horizontal padding for top sections (header).
    var headerHorizontalPadding: CGFloat {
        switch self {
        case .small:  return 16
        case .medium: return 20
        case .large:  return 24
        }
    }

    /// Top padding for the header.
    var headerTopPadding: CGFloat {
        switch self {
        case .small:  return 12
        case .medium: return 20
        case .large:  return 24
        }
    }

    /// Subtitle text shrinks more aggressively on smaller devices (used on ProjectsView).
    var subtitleScale: CGFloat {
        switch self {
        case .small:  return 0.78
        case .medium: return 0.95
        case .large:  return 1.0
        }
    }


}
