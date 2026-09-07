//
//  CalendarTheme.swift
//  Snap Second
//
//  Theme and layout scale extensions for CalendarView
//

import SwiftUI

// MARK: - Calendar-specific layout tokens

extension LayoutScale {
    /// Today's date title above the hero tile.
    var calendarHeroTitleSize: CGFloat {
        switch self {
        case .small:  return 22
        case .medium: return 26
        case .large:  return 30
        }
    }

    /// Size of the big hero square tile.
    var calendarHeroTileSize: CGFloat {
        switch self {
        case .small:  return 132
        case .medium: return 144
        case .large:  return 160
        }
    }

    /// Month name font size (e.g. "AUGUST").
    var calendarMonthTitleSize: CGFloat {
        switch self {
        case .small:  return 18
        case .medium: return 20
        case .large:  return 22
        }
    }

    /// Year font size (e.g. "2025").
    var calendarMonthYearSize: CGFloat {
        switch self {
        case .small:  return 12
        case .medium: return 14
        case .large:  return 16
        }
    }

    /// Number of columns in the day grid.
    var calendarGridColumns: Int {
        switch self {
        case .small:  return 3
        case .medium: return 3
        case .large:  return 4
        }
    }

    /// Spacing between grid cells.
    var calendarGridSpacing: CGFloat {
        switch self {
        case .small:  return 2
        case .medium: return 3
        case .large:  return 4
        }
    }

    /// Navigation bar title size for CalendarView.
    var calendarNavTitleSize: CGFloat {
        switch self {
        case .small:  return 16
        case .medium: return 18
        case .large:  return 20
        }
    }

    /// Back button icon size on CalendarView.
    var calendarBackIconSize: CGFloat {
        switch self {
        case .small:  return 16
        case .medium: return 18
        case .large:  return 20
        }
    }

    /// Back button text size ("Projects")
    var calendarBackTextSize: CGFloat {
        switch self {
        case .small:  return 14
        case .medium: return 16
        case .large:  return 18
        }
    }
}
