//
//  MomentsView.swift
//  Memoir
//
//  Created by Ryan Zheng on 8/7/25.
//

import SwiftUI

struct MomentsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Moments")
                .font(.largeTitle.weight(.semibold))
            Text("Here we’ll show your favourite clips & highlights.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
