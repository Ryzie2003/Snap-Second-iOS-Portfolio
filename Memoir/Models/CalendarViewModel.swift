//
//  CalendarViewModel.swift
//  Snap Second
//
//  View model and state management for CalendarView
//

import Foundation
import SwiftUI

// MARK: - Smart Fill View Model

@MainActor
final class CalendarSmartFillVM: ObservableObject {
    @Published var filling       = false
    @Published var freshDates    = Set<Date>()
    @Published var processingDay : Date?

    private var task: Task<Void, Never>? = nil

    func run(range: ClosedRange<Date>, for project: Project, store: ClipStore) {
        filling = true
        freshDates.removeAll()

        task = Task {
            do {
                let engine = SmartFillEngine()
                _ = try await engine.fillMissingDays(
                    in:     range,
                    project: project
                ) { _ /*processed*/, _ /*total*/, day in
                    Task { @MainActor in
                        self.processingDay = day
                        self.freshDates.insert(day)
                    }
                }
            } catch {
                print(error)
            }

            await MainActor.run {
                filling        = false
                processingDay  = nil
            }
        }
    }

    func cancel()         { task?.cancel(); filling = false }
    func resetHighlight() { freshDates.removeAll() }
}

// MARK: - Type Aliases

typealias SmartFillRunner =
  (_ range: ClosedRange<Date>,
   _ progress: @escaping @Sendable (Int, Int, Date, UIImage?) -> Void
  ) async throws -> Void
