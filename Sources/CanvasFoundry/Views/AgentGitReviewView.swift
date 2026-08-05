import SwiftUI

struct AgentGitReviewView: View {
    @ObservedObject var session: AgentSession
    let service: GitReviewService
    let onRepositoryChanged: () -> Void
    let onPublishPullRequest: () -> Void
    let onOpenPullRequest: () -> Void
    let onPushPullRequestUpdates: () -> Void
    let onMarkPullRequestReady: () -> Void
    let onSyncPullRequest: () -> Void
    let onMergePullRequest: () -> Void
    let onRefreshPullRequest: () -> Void
    let onDelete: () -> Void

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
    @State private var isMergeConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading && snapshot == nil {
                ProgressView("Inspecting agent changes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snapshot {
                reviewContent(snapshot)
            } else {
                ContentUnavailableView(
                    "Git review unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage ?? "This agent's workspace could not be read.")
                )
            }
        }
        .background(Color(red: 0.045, green: 0.05, blue: 0.065))
        .task(id: session.id) {
            // A PR merged in the browser only shows here if we ask GitHub again.
            onRefreshPullRequest()
            await loadReview()
        }
        .alert("Merge \(session.name)?", isPresented: $isMergeConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Squash Merge") { onMergePullRequest() }
        } message: {
            Text("This will merge the pull request and complete the agent. Its clean workspace will be removed automatically.")
        }
    }

    private var isPullRequestMerged: Bool {
        session.pullRequest?.state == .merged
    }

    private var header: some View {
        HStack(spacing: 12) {
            ProviderLogo(provider: session.provider, size: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("Review & Ship \(session.name)")
                    .font(.foundry(size: 13, weight: .semibold))
                Text("\(session.provider.displayName) agent")
                    .font(.foundry(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            testStatusLabel

            deliveryControls

            Button {
                runTests()
            } label: {
                Label("Run Tests", systemImage: "checkmark.circle")
            }
            .disabled(session.testStatus == .running || session.worktree == nil)

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
    }

    @ViewBuilder
    private var deliveryControls: some View {
        if session.isPublishingPullRequest {
            ProgressView()
                .controlSize(.small)
                .help("Updating delivery")
        } else if let pullRequest = session.pullRequest {
            if pullRequest.state == .merged {
                Label("Merged", systemImage: "checkmark.seal.fill")
                    .font(.foundry(size: 11, weight: .semibold))
                    .foregroundStyle(.purple)
            } else if pullRequest.isDraft {
                Button("Ready for Review", action: onMarkPullRequestReady)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            } else if pullRequest.isReadyToMerge {
                Button("Merge", action: { isMergeConfirmationPresented = true })
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            } else if pullRequest.queueState == .behind
                        || pullRequest.queueState == .conflict {
                Button("Sync with \(pullRequest.baseBranch)", action: onSyncPullRequest)
            }
            Button("Open on GitHub", action: onOpenPullRequest)
        } else {
            Button("Create Pull Request", action: onPublishPullRequest)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(
                    snapshot == nil
                        || snapshot?.commits.isEmpty == true
                        || snapshot?.workingFiles.isEmpty == false
                )
                .help(
                    snapshot?.workingFiles.isEmpty == false
                        ? "Commit the reviewed changes first"
                        : "Create a draft pull request"
                )
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
                            deliverySummarySection(snapshot)
                            workingChangesSection(snapshot)
                            commitComposerSection(snapshot)
                            advancedGitSection(snapshot)
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

    private func deliverySummarySection(_ snapshot: GitReviewSnapshot) -> some View {
        reviewSection("DELIVERY") {
            HStack(spacing: 12) {
                Label(session.deliveryState.label, systemImage: deliverySymbol)
                    .font(.foundry(size: 12, weight: .semibold))
                    .foregroundStyle(deliveryColor)
                Spacer()
                Text("\(snapshot.files.count) changed file\(snapshot.files.count == 1 ? "" : "s")")
                    .font(.foundry(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            if let pullRequest = session.pullRequest {
                Text("PR #\(pullRequest.number) · \(pullRequest.queueState.label)")
                    .font(.foundry(size: 11))
                    .foregroundStyle(.secondary)
            } else if !snapshot.workingFiles.isEmpty {
                Text("Review the diff, commit all changes, then create the pull request above.")
                    .font(.foundry(size: 11))
                    .foregroundStyle(.secondary)
            } else if !snapshot.commits.isEmpty {
                Text("The branch is committed and ready to become a pull request.")
                    .font(.foundry(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var worktreeStillOnDisk: Bool {
        guard let path = session.worktree?.worktreeURL.path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Shown once the PR is merged. Cleanup is automatic when the worktree is
    /// clean; this section reports it, or offers the guarded delete when
    /// uncommitted leftovers stopped the automatic pass.
    private var mergedSection: some View {
        reviewSection("MERGED") {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "\(session.pullRequest?.displayLabel ?? "The pull request") was merged. This branch's work is done.",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.foundry(size: 11.5))
                .foregroundStyle(.purple)

                if worktreeStillOnDisk {
                    Text("The agent was kept because it still has uncommitted changes. Deleting it discards them permanently.")
                        .font(.foundry(size: 10.5))
                        .foregroundStyle(.secondary)

                    Button {
                        dismiss()
                        onDelete()
                    } label: {
                        Label("Delete Agent…", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                } else {
                    Text("Agent completed and its isolated workspace was cleaned up. New agents will start from the merged code.")
                        .font(.foundry(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Working changes (stage / unstage)

    private func workingChangesSection(_ snapshot: GitReviewSnapshot) -> some View {
        reviewSection("WORKING CHANGES") {
            if snapshot.workingFiles.isEmpty {
                Text("Everything is committed.")
                    .font(.foundry(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.workingFiles) { file in
                    workingFileRow(file)
                }
            }
        }
    }

    private func workingFileRow(_ file: GitWorkingFile) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
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

    private func advancedGitSection(_ snapshot: GitReviewSnapshot) -> some View {
        DisclosureGroup("Advanced Git controls") {
            HStack {
                Button("Stage All") {
                    runStaging { try await service.stageAll(in: $0) }
                }
                .disabled(isStaging || snapshot.workingFiles.allSatisfy(\.isFullyStaged))

                Button("Unstage All") {
                    let paths = snapshot.workingFiles
                        .filter(\.hasStagedChanges)
                        .map(\.path)
                    runStaging { try await service.unstage(paths, in: $0) }
                }
                .disabled(
                    isStaging
                        || !snapshot.workingFiles.contains(where: \.hasStagedChanges)
                )
                Spacer()
                Text("\(snapshot.workingFiles.filter(\.hasStagedChanges).count) staged")
                    .foregroundStyle(.secondary)
            }
            .font(.foundry(size: 10.5))
            .controlSize(.small)
            .padding(.top, 8)
        }
        .font(.foundry(size: 10.5, weight: .medium))
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
                        commitMessage = CommitMessageComposer.compose(
                            for: snapshot.workingFiles
                        )
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
                                "Commit All Changes",
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
            "COMMITS · \(snapshot.commits.count)"
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
            errorMessage = "This agent has no isolated workspace."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded = try await service.inspect(descriptor)
            snapshot = loaded
            session.gitSummary = loaded.summary
            if commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !loaded.workingFiles.isEmpty {
                commitMessage = CommitMessageComposer.compose(for: loaded.workingFiles)
            }

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
        isCommitting = true
        errorMessage = nil
        actionMessage = nil
        Task {
            defer { isCommitting = false }
            do {
                try await service.stageAll(in: descriptor)
                try await service.commit(message: message, in: descriptor)
                commitMessage = ""
                actionMessage = session.pullRequest == nil
                    ? "Changes committed. This agent is ready to publish."
                    : "Changes committed. Updating the pull request…"
                onRepositoryChanged()
                if session.pullRequest?.state == .open {
                    onPushPullRequestUpdates()
                }
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

    private var deliverySymbol: String {
        switch session.deliveryState {
        case .preparing: "gearshape.2"
        case .working: "bolt.fill"
        case .changesReady: "doc.badge.ellipsis"
        case .readyToPublish: "arrow.up.circle.fill"
        case .publishing: "arrow.triangle.2.circlepath"
        case .draftPullRequest: "doc.text"
        case .checksRunning: "clock.fill"
        case .readyToMerge: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .completed: "checkmark.seal.fill"
        case .idle: "pause.circle"
        }
    }

    private var deliveryColor: Color {
        switch session.deliveryState {
        case .readyToMerge, .completed: .green
        case .needsAttention: .red
        case .changesReady, .readyToPublish, .draftPullRequest, .checksRunning: .orange
        case .preparing, .publishing: .yellow
        case .working: .cyan
        case .idle: .secondary
        }
    }

}
