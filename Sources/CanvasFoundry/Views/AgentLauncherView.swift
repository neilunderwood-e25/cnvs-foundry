import SwiftUI

struct AgentLauncherView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    @State private var provider: AgentProvider = .claude
    @State private var prompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Launch an agent")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("A new Git branch and worktree will be created automatically.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Picker("Agent", selection: $provider) {
                ForEach(AgentProvider.allCases) { provider in
                    Label(provider.displayName, systemImage: provider.symbolName)
                        .tag(provider)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                Text("What should this agent build?")
                    .font(.headline)
                TextEditor(text: $prompt)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(.white.opacity(0.1))
                    }
                    .frame(minHeight: 150)
            }

            HStack {
                Label(model.projectURL?.lastPathComponent ?? "No project", systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Launch \(provider.shortName)") {
                    model.spawn(provider: provider, prompt: prompt)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 560, height: 430)
        .background(.ultraThinMaterial)
    }
}
