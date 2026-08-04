import SwiftUI

struct AgentGitReviewView: View {
    @ObservedObject var session: AgentSession
    let service: GitReviewService
    let onRepositoryChanged: () -> Void
    let onPreparePullRequest: () -> Void
    let onOpenPullRequest: () -> Void
    let onPushPullRequestUpdates: () -> Void
    /// Re-reads the PR from GitHub so a merge done in the browser shows here.
    let onRefreshPullRequest: () -> Void
    let onArchive: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: GitReviewSnapshot?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var actionMessage: String?
    @State private var testOutput = ""
    @State private var commitMessage = ""
    @State private var isCommitting = false
    @State private var isStaging = false
    /// File focused in the patch pane; nil shows the whole patch.
    @State private var selectedFile: GitWorkingFile?
    @State private var focusedDiff: String?

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
            // A PR merged in the browser only shows here if we ask GitHub again.
            onRefreshPullRequest()
            await loadReview()
        }
    }

    private var isPullRequestMerged: Bool {
        session.pullRequest?.state == .merged
    }

    private var header: some View {
        HStack(spacing: 12) {
            ProviderLogo(provider: session.provider, size: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("Review \(session.name)")
                    .font(.foundry(size: 13, weight: .semibold))
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
                onRefreshPullRequest()
                Task { await loadReview() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading)
            .help("Refresh review and pull request state")

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
            if isPullRequestMerged {
                Label("Merged", systemImage: "checkmark.seal.fill")
                    .font(.foundry(size: 11, weight: .semibold))
                    .foregroundStyle(.purple)
            }
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
                        if isPullRequestMerged {
                            mergedSection
                        } else {
                            workingChangesSection(snapshot)
                            commitComposerSection(snapshot)
                        }
                        branchSection(snapshot)
                        if !testOutput.isEmpty {
                            testOutputSection
                        }
                    }
                    .padding(16)
                }
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 480)

                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(selectedFile.map { patchTitle($0.path) } ?? "PATCH")
                            .font(.foundry(size: 10, weight: .bold))
                            .tracking(1)
                            .lineLimit(1)
                        if selectedFile != nil {
                            Button("Show All") {
                                selectedFile = nil
                                focusedDiff = nil
                            }
                            .buttonStyle(.borderless)
                            .font(.foundry(size: 10))
                        }
                        Spacer()
                        Text("base \(String(snapshot.baseRevision.prefix(8)))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    Divider()
                    ScrollView([.horizontal, .vertical]) {
                        Text(focusedDiff ?? snapshot.diff)
                            .font(.system(size: 11, design: .monospaced))
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

    /// Shown once the PR is merged: this sheet's work is done, so the only
    /// sensible action left is tidying up the agent.
    private var mergedSection: some View {
        reviewSection("MERGED") {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "\(session.pullRequest?.displayLabel ?? "The pull request") was merged. This branch is integrated.",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.foundry(size: 11.5))
                .foregroundStyle(.purple)

                Button {
                    dismiss()
                    onArchive()
                } label: {
                    Label("Archive Agent", systemImage: "archivebox")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)

                Text("Archiving keeps the card in the sidebar. Deleting the worktree is available from the agent's menu.")
                    .font(.foundry(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Working changes (stage / unstage)

    private func workingChangesSection(_ snapshot: GitReviewSnapshot) -> some View {
        reviewSection("WORKING CHANGES") {
            if snapshot.workingFiles.isEmpty {
                Text("Worktree is clean — everything is committed.")
                    .font(.foundry(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Stage All") { runStaging { try await service.stageAll(in: $0) } }
                        .disabled(isStaging || snapshot.workingFiles.allSatisfy(\.isFullyStaged))
                    Button("Unstage All") {
                        let paths = snapshot.workingFiles
                            .filter(\.hasStagedChanges)
                            .map(\.path)
                        runStaging { try await service.unstage(paths, in: $0) }
                    }
                    .disabled(isStaging || !snapshot.workingFiles.contains(where: \.hasStagedChanges))
                    Spacer()
                    Text("\(snapshot.workingFiles.filter(\.hasStagedChanges).count) staged")
                        .font(.foundry(size: 10))
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)

                ForEach(snapshot.workingFiles) { file in
                    workingFileRow(file)
                }
            }
        }
    }

    private func workingFileRow(_ file: GitWorkingFile) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(
                "",
                isOn: Binding(
                    get: { file.isFullyStaged },
                    set: { shouldStage in
                        runStaging {
                            if shouldStage {
                                try await service.stage([file.path], in: $0)
                            } else {
                                try await service.unstage([file.path], in: $0)
                            }
                        }
                    }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(isStaging)
            .help(file.isFullyStaged ? "Unstage" : "Stage")

            Button {
                focus(on: file)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(file.statusLabel)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor(for: file))
                        .frame(width: 62, alignment: .leading)
                    Text(file.path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                        .foregroundStyle(
                            selectedFile?.path == file.path ? Color.accentColor : .primary
                        )
                    if file.hasStagedChanges && file.hasUnstagedChanges {
                        Text("partial")
                            .font(.foundry(size: 8.5, weight: .bold))
                            .foregroundStyle(.yellow)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show this file's diff")
        }
    }

    private func statusColor(for file: GitWorkingFile) -> Color {
        switch file.statusLabel {
        case "untracked", "added": .green
        case "deleted": .red
        case "renamed": .cyan
        default: .orange
        }
    }

    // MARK: - Commit composer

    private func commitComposerSection(_ snapshot: GitReviewSnapshot) -> some View {
        let stagedFiles = snapshot.workingFiles.filter(\.hasStagedChanges)
        return reviewSection("COMMIT") {
            if snapshot.workingFiles.isEmpty {
                EmptyView()
            } else {
                TextEditor(text: $commitMessage)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: 74)
                    .padding(6)
                    .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        if commitMessage.isEmpty {
                            Text("Commit message")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 10)
                                .padding(.leading, 11)
                                .allowsHitTesting(false)
                        }
                    }

                HStack {
                    Button {
                        // Describe what will actually be committed: the staged
                        // set, or everything if nothing is staged yet.
                        let described = stagedFiles.isEmpty
                            ? snapshot.workingFiles
                            : stagedFiles
                        commitMessage = CommitMessageComposer.compose(for: described)
                    } label: {
                        Label("Generate", systemImage: "wand.and.stars")
                    }
                    .disabled(snapshot.workingFiles.isEmpty)
                    .help("Generate a commit message from the changed files")

                    Spacer()

                    Button {
                        commitStaged(snapshot)
                    } label: {
                        if isCommitting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(
                                stagedFiles.isEmpty
                                    ? "Stage All & Commit"
                                    : "Commit \(stagedFiles.count) File\(stagedFiles.count == 1 ? "" : "s")",
                                systemImage: "checkmark.seal"
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(
                        isCommitting || isStaging
                            || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Committed work

    /// Everything already on the branch: the commits, then the files they
    /// touch. One section instead of three — commits are what a PR is made of,
    /// and the files are clickable for their diffs.
    private func branchSection(_ snapshot: GitReviewSnapshot) -> some View {
        let workingPaths = Set(snapshot.workingFiles.map(\.path))
        let committed = snapshot.files.filter { !workingPaths.contains($0.path) }
        return reviewSection(
            "ON THIS BRANCH · \(snapshot.commits.count) COMMIT\(snapshot.commits.count == 1 ? "" : "S")"
        ) {
            if snapshot.commits.isEmpty {
                Text("No commits yet — stage and commit above, then publish the draft PR.")
                    .font(.foundry(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.commits) { commit in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(commit.shortHash)
                            .font(.caption.monospaced())
                            .foregroundStyle(.cyan)
                        Text(commit.subject)
                            .font(.foundry(size: 11))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }

                if !committed.isEmpty {
                    Divider().opacity(0.35)
                    ForEach(committed) { file in
                        Button {
                            focus(
                                on: GitWorkingFile(
                                    indexStatus: " ",
                                    worktreeStatus: " ",
                                    path: file.path
                                )
                            )
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.cyan)
                                Text(file.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(2)
                                    .foregroundStyle(
                                        selectedFile?.path == file.path
                                            ? Color.accentColor
                                            : .primary
                                    )
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show this file's diff")
                    }
                }
            }
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
                .font(.foundry(size: 10, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reviewBanner(_ message: String, color: Color) -> some View {
        Text(message)
            .font(.foundry(size: 11))
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
        .font(.foundry(size: 11))
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

            // Keep the focused diff in step with the reloaded state; drop the
            // selection when the file no longer changes anything.
            if let current = selectedFile {
                if loaded.files.contains(where: { $0.path == current.path }) {
                    let refreshed = loaded.workingFiles.first {
                        $0.path == current.path
                    } ?? current
                    focus(on: refreshed)
                } else {
                    selectedFile = nil
                    focusedDiff = nil
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func patchTitle(_ path: String) -> String {
        (path as NSString).lastPathComponent.uppercased()
    }

    private func focus(on file: GitWorkingFile) {
        guard let descriptor = session.worktree, let snapshot else { return }
        selectedFile = file
        Task {
            do {
                let diff = try await service.fileDiff(
                    descriptor,
                    baseRevision: snapshot.baseRevision,
                    file: file
                )
                let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
                focusedDiff = trimmed.isEmpty
                    ? "No textual changes in \(file.path)."
                    : GitReviewService.truncated(
                        diff,
                        maximumCharacters: 2_000_000,
                        label: "Patch"
                    )
            } catch {
                focusedDiff = "Could not load the diff for \(file.path):\n\(error.localizedDescription)"
            }
        }
    }

    /// Runs a staging mutation, then re-inspects so checkboxes reflect git's
    /// actual state rather than an optimistic guess.
    private func runStaging(_ operation: @escaping (WorktreeDescriptor) async throws -> Void) {
        guard let descriptor = session.worktree else { return }
        isStaging = true
        errorMessage = nil
        Task {
            defer { isStaging = false }
            do {
                try await operation(descriptor)
                await loadReview()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func commitStaged(_ snapshot: GitReviewSnapshot) {
        guard let descriptor = session.worktree else { return }
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        let mustStageEverything = !snapshot.workingFiles.contains(where: \.hasStagedChanges)

        isCommitting = true
        errorMessage = nil
        actionMessage = nil
        Task {
            defer { isCommitting = false }
            do {
                if mustStageEverything {
                    try await service.stageAll(in: descriptor)
                }
                try await service.commit(message: message, in: descriptor)
                commitMessage = ""
                actionMessage = "Committed to \(descriptor.branchName). Publish or push the PR to share it."
                onRepositoryChanged()
                await loadReview()
            } catch {
                errorMessage = error.localizedDescription
            }
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

}
