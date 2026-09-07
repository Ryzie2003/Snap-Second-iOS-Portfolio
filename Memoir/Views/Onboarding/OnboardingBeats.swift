//
//  OnboardingBeats.swift
//  Snap Second
//
//  Created by Ryan Zheng on 9/2/25.
//

import SwiftUI

struct Beat: Identifiable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

struct OnboardingBeats {
    /// ~18s loop; adjust to 15s or 20s by nudging start/end.
    static let beats: [Beat] = [
        .init(start: 2.0,  end: 5.2,  text: "The average person lives about 27,000 days."),
        .init(start: 5.2,  end: 8.4,  text: "Sometimes the days blur together."),
        .init(start: 8.4,  end: 11.6, text: "It's easy to forget the small, everyday moments."),
        .init(start: 11.6, end: 15.2, text: "Snap Second helps you turn those moments into your life movie.")
    ]

    /// A friendly subline you can show beneath the main text (optional).
    static let subline: String? = nil
}
