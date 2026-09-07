//
//  ChevronButton.swift
//  Memoir
//
//  Created by Ryan Zheng on 8/6/25.
//

import SwiftUI

/// A reusable left / right chevron with a full-size tap target (≥44×44 pt).
struct ChevronButton: View {
    enum Direction { case left, right }

    var direction: Direction
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: direction == .left ? "chevron.left"
                                                 : "chevron.right")
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)          // HIG-minimum hit area
        }
        .buttonStyle(.plain)                           // no extra chrome
        .contentShape(Rectangle())                     // full-frame tappable
        .accessibilityLabel(direction == .left ? "Previous month"
                                               : "Next month")
    }
}
