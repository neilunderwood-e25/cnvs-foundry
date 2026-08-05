import SwiftUI

/// Bottom-centre command bar: type an instruction like "add 3 claude agents and
/// one code agent" and the workspace performs it.
///
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
    @State private var isPlanning = false
    @State private var shouldSpeakPendingConfirmation = false
    @StateObject private var voice = LocalVoiceController()
    @StateObject private var speechFeedback = LocalSpeechFeedback()
    @FocusState private var isFocused: Bool

    private struct Feedback: Equatable, Identifiable {
        enum Tone { case success, failure }
        let id = UUID()
        let tone: Tone
        let message: String
    }

    var body: some View {
        VStack(spacing: 8) {
            if let pending = model.pendingConversationConfirmation {
                confirmationChip(pending)
                    .transition(.opacity)
            }
            if let feedback {
                feedbackChip(feedback)
                    .transition(.opacity)
            }
            inputPill
        }
        .animation(.easeInOut(duration: 0.15), value: feedback)
        // Summoned with ⌘K, so land the caret in the field straight away.
        .onAppear { isFocused = true }
        .onDisappear {
            voice.cancel()
            speechFeedback.stop()
        }
        .onChange(of: voice.transcript) { _, transcript in
            guard voice.isListening || voice.phase == .finishing else { return }
            text = transcript
        }
        .onChange(of: voice.completedTranscript) { _, result in
            guard let result else { return }
            text = result.text
            submit(spoken: true)
        }
        .onChange(of: voice.phase) { _, phase in
            if case .unavailable(let reason) = phase {
                show(.init(tone: .failure, message: reason))
            }
        }
        .onChange(of: voice.notice) { _, notice in
            guard let notice else { return }
            show(.init(tone: .failure, message: notice.message))
        }
        .onChange(of: model.pendingConversationConfirmation) { _, pending in
            guard let pending else { return }
            show(.init(tone: .success, message: pending.prompt))
            if shouldSpeakPendingConfirmation {
                speechFeedback.speak(pending.prompt) {
                    guard model.pendingConversationConfirmation != nil else { return }
                    voice.begin()
                }
                shouldSpeakPendingConfirmation = false
            }
        }
    }

    private var inputPill: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(
                    voice.isListening
                        ? Color.orange
                        : (isPlanning ? Color.cyan : (text.isEmpty ? Color.white.opacity(0.3) : Color.accentColor))
                )
                .frame(width: 6, height: 6)
                .padding(.leading, 14)

            TextField("Type or speak…", text: $text)
                .textFieldStyle(.plain)
                .font(.foundry(size: 12.5))
                .foregroundStyle(.white)
                .focused($isFocused)
                .onSubmit { submit() }
                // Escape backs out one step at a time: clear a draft first, then
                // dismiss the bar.
                .onExitCommand {
                    if voice.isListening || voice.phase == .finishing {
                        voice.cancel()
                        text = ""
                    } else if text.isEmpty {
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
        .disabled(isPlanning)
    }

    private var micButton: some View {
        Button {
            speechFeedback.stop()
            voice.toggle()
        } label: {
            Group {
                if voice.isListening {
                    VoiceLevelMeter(level: voice.audioLevel)
                } else {
                    Image(systemName: microphoneSymbol)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
                .foregroundStyle(voice.isListening ? .white : .white.opacity(0.72))
                .frame(width: 30, height: 28)
                .background(
                    voice.isListening
                        ? Color.orange.opacity(0.82)
                        : Color.white.opacity(isHoveringMic ? 0.11 : 0.05),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .onHover { isHoveringMic = $0 }
        .help(microphoneHelp)
        .accessibilityLabel(voice.isListening ? "Cancel voice command" : "Start voice command")
    }

    private var microphoneSymbol: String {
        switch voice.phase {
        case .requestingPermission, .finishing: "ellipsis"
        case .listening: "waveform"
        case .idle, .unavailable: "mic.fill"
        }
    }

    private var microphoneHelp: String {
        switch voice.phase {
        case .idle: "Speak a local voice command"
        case .requestingPermission: "Requesting microphone access…"
        case .listening: "Listening locally — pauses submit automatically; click to cancel"
        case .finishing: "Finishing transcription…"
        case .unavailable(let reason): reason
        }
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

    private func confirmationChip(_ pending: WorkspaceConversationConfirmation) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.orange)
            Text(pending.prompt)
                .font(.foundry(size: 11))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Cancel") {
                handleConversationControl(.cancel, spoken: false, userRequest: "cancel")
            }
            .controlSize(.mini)
            Button("Confirm") {
                handleConversationControl(.confirm, spoken: false, userRequest: "confirm")
            }
            .controlSize(.mini)
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 452)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.black.opacity(0.44))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.orange.opacity(0.32))
        }
    }

    private func submit(spoken: Bool = false) {
        let entry = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty, !isPlanning else { return }

        if let control = WorkspaceConversationControlParser.parse(entry),
           control != .doThat || model.pendingConversationConfirmation != nil {
            handleConversationControl(control, spoken: spoken, userRequest: entry)
            return
        }

        let plan = WorkspaceCommandParser.parse(
            entry,
            knownAgentNames: model.sessions.map(\.name)
        )

        guard !plan.isEmpty else {
            runLocalPlanner(entry, spoken: spoken)
            return
        }

        let executedPlan = model.run(plan)

        guard !executedPlan.isEmpty else {
            if spoken {
                speechFeedback.speak("I couldn't do that. Check Foundry for details.")
            }
            show(.init(tone: .failure, message: "Couldn’t run “\(entry)”"))
            return
        }

        if spoken {
            speechFeedback.speak(executedPlan.spokenAcknowledgement)
        }

        var message = executedPlan.summary
        if !executedPlan.notes.isEmpty {
            message += " · " + executedPlan.notes.joined(separator: " · ")
        }
        if !executedPlan.unrecognized.isEmpty {
            message += " · skipped “\(executedPlan.unrecognized.joined(separator: "”, “"))”"
        }
        show(.init(
            tone: executedPlan.unrecognized.isEmpty ? .success : .failure,
            message: message
        ))
        model.rememberConversation(
            userRequest: entry,
            assistantResult: message,
            commandPlan: executedPlan
        )
        text = ""
    }

    private func runLocalPlanner(_ entry: String, spoken: Bool) {
        isPlanning = true
        shouldSpeakPendingConfirmation = spoken
        show(.init(tone: .success, message: "Thinking locally…"))

        Task {
            defer { isPlanning = false }
            do {
                let plan = try await model.planLocalActions(for: entry)
                let result = model.run(plan)
                guard result.wasHandled else {
                    shouldSpeakPendingConfirmation = false
                    show(.init(tone: .failure, message: "Couldn’t safely handle “\(entry)”"))
                    if spoken { speechFeedback.speak("I couldn't safely do that.") }
                    return
                }

                show(.init(tone: .success, message: result.message))
                if spoken { speechFeedback.speak(result.message) }
                model.rememberConversation(
                    userRequest: entry,
                    assistantResult: result.message,
                    referencedAgentIDs: plan.actions.compactMap(\.agentID),
                    didExecuteAction: result.wasHandled
                        && plan.actions.contains(where: { $0.type != .noAction })
                )
                if !plan.actions.contains(where: { $0.type == .prepareRemoveAgent }) {
                    shouldSpeakPendingConfirmation = false
                }
                text = ""
            } catch {
                shouldSpeakPendingConfirmation = false
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                show(.init(tone: .failure, message: message))
                if spoken { speechFeedback.speak(message) }
            }
        }
    }

    private func handleConversationControl(
        _ control: WorkspaceConversationControl,
        spoken: Bool,
        userRequest: String
    ) {
        speechFeedback.stop()
        if voice.isListening || voice.phase == .finishing { voice.cancel() }
        let result = model.runConversationControl(control)
        show(.init(tone: .success, message: result.message))
        if spoken { speechFeedback.speak(result.message) }
        model.rememberConversation(
            userRequest: userRequest,
            assistantResult: result.message,
            referencedAgentIDs: [],
            didExecuteAction: control != .cancel
                && result.message != "There’s nothing waiting for confirmation."
        )
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

private struct VoiceLevelMeter: View {
    let level: Double

    var body: some View {
        HStack(spacing: 2) {
            bar(scale: 0.62)
            bar(scale: 1)
            bar(scale: 0.78)
        }
        .animation(.linear(duration: 0.08), value: level)
    }

    private func bar(scale: Double) -> some View {
        Capsule()
            .fill(.white)
            .frame(width: 2.2, height: 4 + 11 * max(0.12, level) * scale)
    }
}
