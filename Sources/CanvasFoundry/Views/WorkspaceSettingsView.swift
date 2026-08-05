import SwiftUI

/// Workspace preferences, shown in a popover from the toolbar. Currently just
/// the canvas backdrop; laid out as sections so more settings can slot in.
struct WorkspaceSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    @AppStorage(LocalSpeechFeedback.voiceIdentifierKey) private var voiceIdentifier = ""
    @StateObject private var speechPreview = LocalSpeechFeedback()

    private let columns = [GridItem(.adaptive(minimum: 62), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.foundry(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 10) {
                Text("CANVAS BACKGROUND")
                    .font(.foundry(size: 9.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(CanvasBackground.allCases) { background in
                        Button {
                            model.canvasBackground = background
                        } label: {
                            VStack(spacing: 5) {
                                CanvasBackgroundSwatch(
                                    background: background,
                                    isSelected: background == model.canvasBackground
                                )
                                Text(background.displayName)
                                    .font(.foundry(size: 9.5, weight: .medium))
                                    .foregroundStyle(
                                        background == model.canvasBackground
                                            ? .primary
                                            : .secondary
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .help(background.displayName)
                        .accessibilityLabel("\(background.displayName) background")
                        .accessibilityAddTraits(
                            background == model.canvasBackground
                                ? [.isButton, .isSelected]
                                : .isButton
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 9) {
                Text("VOICE AGENT")
                    .font(.foundry(size: 9.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Picker("Voice", selection: $voiceIdentifier) {
                        Text("Best available").tag(LocalSpeechFeedback.automaticVoiceIdentifier)
                        ForEach(LocalSpeechFeedback.installedVoiceOptions) { voice in
                            Text(voice.displayName).tag(voice.id)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)

                    Button {
                        speechPreview.speak("Foundry is ready when you are.")
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Preview voice")
                }

                if LocalSpeechFeedback.installedVoiceOptions.isEmpty {
                    Text("Download an enhanced voice in System Settings → Accessibility → Spoken Content.")
                        .font(.foundry(size: 9.5))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 5) {
                    Circle()
                        .fill(model.isLocalPlannerWarm ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(model.isLocalPlannerWarm ? "Local model ready" : "Local model loads on demand")
                }
                .font(.foundry(size: 10.5))
                .foregroundStyle(.secondary)

                if let metrics = model.lastLocalPlannerMetrics {
                    Text(
                        "Last plan \(metrics.totalDuration.formatted(.number.precision(.fractionLength(2))))s · \(metrics.promptTokenCount) input tokens"
                    )
                    .font(.foundry(size: 9.5))
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 8) {
                Text("DRAWINGS")
                    .font(.foundry(size: 9.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                HStack {
                    Text(
                        model.annotations.isEmpty
                            ? "Nothing drawn yet"
                            : "\(model.annotations.count) item\(model.annotations.count == 1 ? "" : "s") on the canvas"
                    )
                    .font(.foundry(size: 11))
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button("Clear", action: model.clearAnnotations)
                        .disabled(model.annotations.isEmpty)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(width: 292)
        .onDisappear { speechPreview.stop() }
    }
}
