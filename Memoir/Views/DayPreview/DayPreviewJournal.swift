//
//  DayPreviewJournal.swift
//  Snap Second
//
//  Journal editor for DayPreviewView
//

import SwiftUI
import PhosphorSwift
import Speech

// MARK: - Journal Editor View

struct JournalEditorView: View {
    @Binding var text: String
    let theme: Theme
    let date: Date

    @Environment(\.dismiss) private var dismiss

    @StateObject private var speechManager = SpeechToTextManager()
    @State private var dictationBaseText: String = ""
    @FocusState private var isEditorFocused: Bool

    @State private var currentPromptIndex: Int = 0

    private let prompts: [String] = [
        "What are you grateful for today?",
        "What is one small moment from today you want to remember?",
        "How did today feel in one sentence?",
        "What is something you learned or noticed today?",
        "Who or what made you smile today?",
        "What moment from today deserves to be remembered?",
        "What feeling stayed with you the longest today?",
        "What surprised you today, even in a small way?",
        "What is one thing you noticed about yourself today?",
        "What made today feel different from yesterday?",
        "What is something you wish you could slow down and appreciate?",
        "What moment made you pause, even briefly?",
        "What drained your energy today, and why?",
        "What restored your energy today?",
        "What is one thought you kept returning to?",
        "What would you like to let go of after today?",
        "What is something today taught you?",
        "Who made your day a little lighter?",
        "What small comfort meant the most today?",
        "What made you smile unexpectedly?",
        "What ordinary thing felt special today?",
        "What made you feel supported?",
        "What kindness did you witness or receive?",
        "What do you appreciate about your life today?",
        "What beauty did you notice that you might overlook?",
        "What warmed your heart today?",
        "What emotion was strongest today?",
        "What are you proud of today, even if it feels small?",
        "What felt heavy today?",
        "What helped you feel grounded?",
        "What did you avoid feeling or thinking about?",
        "What brought you comfort when you needed it?",
        "What felt meaningful today?",
        "When did you feel most like yourself?",
        "What is something you wish you could say out loud?",
        "What fear or worry showed up today?",
        "What helped you feel calm or peaceful?",
        "What challenged you today?",
        "What did you learn about yourself recently?",
        "What habit or pattern did you notice yourself repeating?",
        "What small win did you achieve today?",
        "What would you like to do differently tomorrow?",
        "What are you trying to grow toward?",
        "What boundaries did you hold or break today?",
        "What decision are you glad you made?",
        "What is something you want to question or rethink?",
        "What perspective shifted for you?",
        "Who did you feel connected to today?",
        "What part of your day felt the most alive?",
        "What memory from today would you keep forever if you could?",
        "What made today feel worthwhile?",
        "What moment deserves more of your attention?",
        "What would you want your future self to remember about today?",
        "What made you feel grateful to be here?"
    ]

    private var currentPrompt: String {
        if prompts.isEmpty { return "Write anything that's on your mind…" }
        return prompts[currentPromptIndex % prompts.count]
    }

    private func cyclePromptIfEmpty() {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !prompts.isEmpty {
            currentPromptIndex = (currentPromptIndex + 1) % prompts.count
        }
    }

    private var formattedDayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        let base = formatter.string(from: date)

        let day = Calendar.current.component(.day, from: date)
        let suffix: String
        switch day {
        case 11, 12, 13: suffix = "th"
        default:
            switch day % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return base + suffix
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(theme.textSecondary.opacity(0.25), lineWidth: 1)

                    TextEditor(text: $text)
                        .padding(EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18))
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .focused($isEditorFocused)

                    if text.isEmpty && !isEditorFocused {
                        HStack(spacing: 8) {
                            Ph.pencilSimpleLine.regular
                                .frame(width: 17, height: 17)
                                .foregroundStyle(theme.textSecondary.opacity(0.85))

                            Text(currentPrompt)
                                .font(.system(size: 17, weight: .regular, design: .rounded))
                                .foregroundStyle(theme.textSecondary)
                        }
                        .padding(EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, -32)
                .overlay(alignment: .bottomTrailing) {
                    let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        cyclePromptIfEmpty()
                    } label: {
                        Text("Inspire Me!")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .textCase(.uppercase)
                            .kerning(0.6)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(
                                        Color.black.opacity(isEmpty ? 0.35 : 0.18),
                                        lineWidth: 1
                                    )
                                    .background(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(Color.white.opacity(isEmpty ? 0.9 : 0.7))
                                    )
                            )
                            .foregroundStyle(
                                isEmpty
                                ? Color.black.opacity(0.9)
                                : Color.black.opacity(0.45)
                            )
                            .shadow(
                                color: Color.black.opacity(isEmpty ? 0.10 : 0.0),
                                radius: 4,
                                y: 2
                            )
                    }
                    .disabled(!isEmpty)
                    .padding(.trailing, 20)
                    .padding(.bottom, 8)
                }
            }
            .background(theme.core.surface.ignoresSafeArea())
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    VStack(spacing: 6) {
                        if speechManager.isRecording {
                            Text("Listening…")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.textSecondary)
                                .transition(.opacity)
                        }

                        Button {
                            toggleRecording()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(
                                        speechManager.isRecording
                                        ? theme.core.primary.opacity(0.95)
                                        : theme.core.primary
                                    )
                                    .frame(width: 56, height: 56)
                                    .shadow(
                                        color: theme.core.primary.opacity(
                                            speechManager.isRecording ? 0.45 : 0.28
                                        ),
                                        radius: 12, y: 4
                                    )

                                (speechManager.isRecording ? Ph.microphone.fill : Ph.microphone.regular)
                                    .frame(width: 22, height: 22)
                                    .foregroundStyle(.white)
                            }
                        }
                        .accessibilityLabel(
                            speechManager.isRecording ? "Stop dictation" : "Start dictation"
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 32)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(formattedDayString)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.textSecondary)

                        Text("Journal")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.core.text)
                    }
                }

                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        if speechManager.isRecording {
                            speechManager.stopRecording()
                        }
                        isEditorFocused = false
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
            }
        }
    }

    private func toggleRecording() {
        if speechManager.isRecording {
            speechManager.stopRecording()
        } else {
            dictationBaseText = text
            speechManager.startRecording { partial in
                let trimmedPartial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedPartial.isEmpty else { return }

                let prefix = dictationBaseText
                let separator = prefix.isEmpty ? "" : (prefix.hasSuffix(" ") ? "" : " ")

                self.text = prefix + separator + trimmedPartial
            }
        }
    }
}
