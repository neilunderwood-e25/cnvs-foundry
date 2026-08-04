import SwiftUI

/// Bottom-centre command bar: type an instruction like "add 3 claude agents and
/// one code agent" and the workspace performs it.
///
/// Voice is deliberately not wired up yet — dictation needs microphone and
/// speech-recognition consent, which require an `Info.plist` inside a signed app
/// bundle, and this target still ships as a bare SwiftPM executable. The parser
/// already folds in speech synonyms, so dictation becomes an input adapter in
/// front of the same code path rather than a rewrite.
/// UserDefaults key shared by the menu command and the canvas.
enum CommandBarVisibility {
    static let key = "foundry.commandBarVisible"
}

struct CommandBar: View {
    @ObservedObject var model: WorkspaceModel
    /// Set false to dismiss; the ⌘K menu toggle writes the same store.
    @Binding var isVisible: Bool

    @State private var text = ""
    @State private var feedback: Feedback?
    @State private var isHoveringMic = false
    @FocusState private var isFocused: Bool

    private struct Feedback: Equatable, Identifiable {
        enum Tone { case success, failure }
        let id = UUID()
        let tone: Tone
        let message: String
    }

    var body: some View {
        VStack(spacing: 8) {
            if let feedback {
                feedbackChip(feedback)
                    .transition(.opacity)
            }
            inputPill
        }
        .animation(.easeInOut(duration: 0.15), value: feedback)
        // Summoned with ⌘K, so land the caret in the field straight away.
        .onAppear { isFocused = true }
    }

    private var inputPill: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(text.isEmpty ? Color.white.opacity(0.3) : Color.accentColor)
                .frame(width: 6, height: 6)
                .padding(.leading, 14)

            TextField("Type or speak…", text: $text)
                .textFieldStyle(.plain)
                .font(.foundry(size: 12.5))
                .foregroundStyle(.white)
                .focused($isFocused)
                .onSubmit(submit)
                // Escape backs out one step at a time: clear a draft first, then
                // dismiss the bar.
                .onExitCommand {
                    if text.isEmpty {
                        isVisible = false
                    } else {
                        text = ""
                        feedback = nil
                    }
                }

            micButton
                .padding(.trailing, 6)
        }
        .frame(width: 452, height: 40)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay { Capsule().fill(.black.opacity(0.42)) }
        }
        .overlay {
            Capsule().strokeBorder(
                isFocused ? Color.accentColor.opacity(0.5) : .white.opacity(0.13)
            )
        }
        .shadow(color: .black.opacity(0.34), radius: 11, y: 4)
    }

    private var micButton: some View {
        Image(systemName: "mic.slash")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.4))
            .frame(width: 30, height: 28)
            .background(
                Color.white.opacity(isHoveringMic ? 0.08 : 0.05),
                in: Capsule()
            )
            .onHover { isHoveringMic = $0 }
            .help(
                "Voice input is not enabled yet: it needs microphone consent, which requires a signed app bundle. Typed commands work now."
            )
            .accessibilityLabel("Voice input unavailable")
    }

    private func feedbackChip(_ feedback: Feedback) -> some View {
        HStack(spacing: 7) {
            Image(
                systemName: feedback.tone == .success
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(feedback.tone == .success ? .green : .orange)

            Text(feedback.message)
                .font(.foundry(size: 11))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: 452, alignment: .leading)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay { Capsule().fill(.black.opacity(0.42)) }
        }
        .overlay { Capsule().strokeBorder(.white.opacity(0.11)) }
    }

    private func submit() {
        let entry = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else { return }

        let plan = WorkspaceCommandParser.parse(
            entry,
            knownAgentNames: model.sessions.map(\.name)
        )

        guard !plan.isEmpty else {
            // Leave the text in place so a near-miss can be edited, not retyped.
            show(.init(tone: .failure, message: "Didn’t understand “\(entry)”"))
            return
        }

        model.run(plan)

        var message = plan.summary
        if !plan.notes.isEmpty {
            message += " · " + plan.notes.joined(separator: " · ")
        }
        if !plan.unrecognized.isEmpty {
            message += " · skipped “\(plan.unrecognized.joined(separator: "”, “"))”"
        }
        show(.init(tone: plan.unrecognized.isEmpty ? .success : .failure, message: message))
        text = ""
    }

    private func show(_ next: Feedback) {
        feedback = next
        Task {
            try? await Task.sleep(for: .seconds(5))
            // Only clear if nothing newer replaced it.
            if feedback?.id == next.id { feedback = nil }
        }
    }
}
