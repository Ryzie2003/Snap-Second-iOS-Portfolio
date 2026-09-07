//
//  WelcomeScreen.swift
//  Memoir
//
//  Created by Ryan Zheng on 8/5/25.
//

import SwiftUI

struct WelcomeScreen: View {
    @EnvironmentObject private var onboard: OnboardState

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App Logo or Name
            Image(systemName: "sparkles.tv.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .foregroundColor(.accentColor)

            Text("Welcome to Snap Second")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)

            Text("Capture your life, one second at a time.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            // Primary CTA
            Button(action: {
                onboard.advance()
            }) {
                Text("Let’s Begin")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(18)
                    .padding(.horizontal, 40)
            }
        }
        .padding(.vertical)
    }
}
