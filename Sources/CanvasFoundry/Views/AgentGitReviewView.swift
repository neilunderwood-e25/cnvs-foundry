import SwiftUI

struct AgentGitReviewView: View {
    @ObservedObject var session: AgentSession
    let service: GitReviewService
    let onRepositoryChanged: () -> Void
    let onPreparePullRequest: () -> Void
    let onOpenPullRequest: () -> Void
    let onPushPullRequestUpdates: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: GitReviewSnapshot?
    @State private var isLoading = false
    @State private var isIntegrating = false
    @State private var errorMessage: String?
    @State private var actionMessage: String?
    @State private var testOutput = ""
    @State private var pendingAction: PendingGitAction?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading && snapshot == nil {
                ProgressView("Inspecting agent worktree…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snapshot {
                reviewContent(snapshot)
            } else {
                ContentUnavailableView(
                    "Git review unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage ?? "This agent has no readable worktree.")
                )
            }
        }
        .background(Color(red: 0.045, green: 0.05, blue: 0.065))
        .task(id: session.id) {
            await loadReview()
        }
        .alert(item: $pendingAction) { action in
            switch action {
            case .merge:
                Alert(
                    title: Text("Merge \(session.name)'s branch?"),
                    message: Text("Canvas Foundry will merge \(session.worktree?.branchName ?? "the agent branch") into the currently checked-out project branch. The main checkout must be clean."),
                    primaryButton: .default(Text("Merge Branch")) {
                        integrate(.merge)
                    },
                    secondaryButton: .cancel()
                )
            case .cherryPick(let commit):
                Alert(
                    title: Text("Cherry-pick \(commit.shortHash)?"),
                    message: Text(commit.subject),
                    primaryButton: .default(Text("Cherry-pick")) {
                        integrate(.cherryPick(commit))
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: session.provider.symbolName)
                .foregroundStyle(session.provider == .claude ? .orange : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Review \(session.name)")
                    .font(.headline)
                Text(session.worktree?.branchName ?? "No worktree")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()

            testStatusLabel

            pullRequestControls

            Button {
                runTests()
            } label: {
                Label("Run Tests", systemImage: "checkmark.circle")
            }
            .disabled(session.testStatus == .running || session.worktree == nil)

            Button {
                Task { await loadReview() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading)
            .help("Refresh review")

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
    }

    @ViewBuilder
    private var pullRequestControls: some View {
        if session.isPublishingPullRequest {
            ProgressView()
                .controlSize(.small)
                .help("Updating pull request")
        } else if let pullRequest = session.pullRequest {
            Button("Open \(pullRequest.displayLabel)", action: onOpenPullRequest)
            if pullRequest.state == .open {
                Button("Push Updates", action: onPushPullRequestUpdates)
            }
        } else {
            Button {
                dismiss()
                onPreparePullRequest()
            } label: {
                Label("Publish Draft PR", systemImage: "arrow.up.right.square")
            }
        }
    }

    private func reviewContent(_ snapshot: GitReviewSnapshot) -> some View {
        VStack(spacing: 0) {
            if let errorMessage {
                reviewBanner(errorMessage, color: .red)
            } else if let actionMessage {
                reviewBanner(actionMessage, color: .green)
            }

            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        reviewStats(snapshot)
                        filesSection(snapshot.files)
                        commitsSection(snapshot.commits)
                        integrationSection(snapshot)
                        if !testOutput.isEmpty {
                            testOutputSection
                        }
                    }
                    .padding(16)
                }
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("PATCH")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(1)
                        Spacer()
                        Text("base \(String(snapshot.baseRevision.prefix(8)))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    Divider()
                    ScrollView([.horizontal, .vertical]) {
                        Text(snapshot.diff)
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(14)
                    }
                    .background(Color.black.opacity(0.28))
                }
                .frame(minWidth: 520)
            }
        }
    }

    private func reviewStats(_ snapshot: GitReviewSnapshot) -> some View {
        HStack(spacing: 10) {
            stat("\(snapshot.files.count)", label: "files", color: .orange)
            stat("\(snapshot.commits.count)", label: "commits", color: .cyan)
        }
    }

    private func stat(_ value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func filesSection(_ files: [GitChangedFile]) -> some View {
        reviewSection("CHANGED FILES") {
            if files.isEmpty {
                Text("No changed files")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(files) { file in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(file.status)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.orange)
                            .frame(width: 54, alignment: .leading)
                        Text(file.path)
                            .font(.system(size: 10.5, design: .monospaced))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func commitsSection(_ commits: [GitCommitSummary]) -> some View {
        reviewSection("AGENT COMMITS") {
            if commits.isEmpty {
                Text("No commits beyond the agent's base revision")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(commits) { commit in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(commit.shortHash)
                                .font(.caption.monospaced())
                                .foregroundStyle(.cyan)
                            Spacer()
                            Button("Cherry-pick") {
                                pendingAction = .cherryPick(commit)
                            }
                            .buttonStyle(.borderless)
                            .disabled(isIntegrating)
                        }
                        Text(commit.subject)
                            .font(.caption)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func integrationSection(_ snapshot: GitReviewSnapshot) -> some View {
        reviewSection("INTEGRATE") {
            Button {
                pendingAction = .merge
            } label: {
                Label("Merge Agent Branch", systemImage: "arrow.triangle.merge")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(snapshot.commits.isEmpty || isIntegrating)

            Text("Only committed work can be merged or cherry-picked. Uncommitted files stay in the agent worktree.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var testOutputSection: some View {
        reviewSection("TEST OUTPUT") {
            ScrollView([.horizontal, .vertical]) {
                Text(testOutput)
                    .font(.system(size: 9.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 180)
            .padding(8)
            .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func reviewSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.9)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reviewBanner(_ message: String, color: Color) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .frame(minHeight: 34)
            .background(color.opacity(0.08))
    }

    private var testStatusLabel: some View {
        HStack(spacing: 5) {
            if session.testStatus == .running {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(testStatusColor)
                    .frame(width: 6, height: 6)
            }
            Text(session.testStatus.label)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var testStatusColor: Color {
        switch session.testStatus {
        case .notRun: .secondary
        case .running: .yellow
        case .passed: .green
        case .failed: .red
        }
    }

    @MainActor
    private func loadReview() async {
        guard let descriptor = session.worktree else {
            errorMessage = "This agent has no worktree."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded = try await service.inspect(descriptor)
            snapshot = loaded
            session.gitSummary = loaded.summary
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runTests() {
        guard let descriptor = session.worktree else { return }
        session.testStatus = .running
        testOutput = ""
        errorMessage = nil
        Task {
            do {
                let result = try await service.runTests(descriptor)
                testOutput = GitReviewService.truncated(
                    "$ \(result.command)\n\n\(result.output)",
                    maximumCharacters: 250_000,
                    label: "Test output"
                )
                session.testStatus = result.passed
                    ? .passed
                    : .failed("Tests exited with a non-zero status.")
            } catch {
                session.testStatus = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func integrate(_ action: PendingGitAction) {
        guard let descriptor = session.worktree else { return }
        isIntegrating = true
        errorMessage = nil
        actionMessage = nil
        Task {
            defer { isIntegrating = false }
            do {
                switch action {
                case .merge:
                    try await service.mergeAgentBranch(descriptor)
                    actionMessage = "Merged \(descriptor.branchName) into the main project checkout."
                case .cherryPick(let commit):
                    try await service.cherryPick(commit, from: descriptor)
                    actionMessage = "Cherry-picked \(commit.shortHash) into the main project checkout."
                }
                onRepositoryChanged()
                await loadReview()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum PendingGitAction: Identifiable {
    case merge
    case cherryPick(GitCommitSummary)

    var id: String {
        switch self {
        case .merge: "merge"
        case .cherryPick(let commit): "cherry-\(commit.hash)"
        }
    }
}
