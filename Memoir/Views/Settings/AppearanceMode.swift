//
//  AppearanceMode.swift
//  Memoir
//
//  Created by Ryan Zheng on 9/26/25.
//


import SwiftUI

public enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// Convenience accessor used by MemoirApp
public func appPreferredColorScheme() -> ColorScheme? {
    let raw = UserDefaults.standard.string(forKey: "appearance.mode") ?? "system"
    return AppearanceMode(rawValue: raw)?.colorScheme
}
