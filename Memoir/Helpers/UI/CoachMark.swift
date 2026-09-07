//
//  CoachMark.swift
//  Memoir
//
//  Created by Ryan Zheng on 8/4/25.
//

import SwiftUI

/// Simple spotlight + bubble.
/// Use   .coachMark(isVisible:text:in:arrow:tap:)
struct CoachMark: ViewModifier {
    @Binding var isVisible: Bool
    let text: String
    let highlight: CGRect      // in global coordinates
    let arrowTo: CGPoint       // tip position
    func body(content: Content) -> some View {
        content
            .overlay {
                if isVisible {
                    ZStack {
                        // dim everything except highlight
                        Color.black.opacity(0.55)
                            .mask {
                                Rectangle().fill(.black)
                                    .overlay {
                                        Rectangle()
                                            .path(in: highlight)
                                            .fill(style: .init(eoFill: true))
                                    }
                            }
                            .ignoresSafeArea()
                            .onTapGesture { isVisible = false }

                        // arrow
                        Image(systemName: "arrow.down")
                            .font(.largeTitle)
                            .foregroundStyle(.white)
                            .position(arrowTo)

                        // bubble
                        Text(text)
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(.ultraThinMaterial, in: Capsule())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .transition(.opacity.combined(with: .scale))
                    .animation(.easeInOut, value: isVisible)
                }
            }
    }
}
extension View {
    func coachMark(isVisible: Binding<Bool>,
                   text: String,
                   in rect: CGRect,
                   arrow tip: CGPoint) -> some View {
        modifier(CoachMark(isVisible: isVisible,
                           text: text,
                           highlight: rect,
                           arrowTo: tip))
    }
}
