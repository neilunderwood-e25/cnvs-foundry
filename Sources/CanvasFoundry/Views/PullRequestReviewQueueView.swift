import AppKit
import SwiftUI

struct PullRequestReviewQueueView: View {
    @ObservedObject var model: WorkspaceModel

    @Environment(\.dismiss) private var dismiss
    @State private var pendingMerge: AgentSession?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let notice = model.reviewQueueNotice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                    Text(notice)
                        .font(.foundry(size: 13))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        model.reviewQueueNotice = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(Color.orange.opacity(0.08))
                Divider()
            }

            if model.reviewQueueSessions.isEmpty {
                ContentUnavailableView(
                    "No Pull Requests",
                    systemImage: "arrow.triangle.pull",
                    description: Text("Publish an agent branch as a draft PR to add it to this queue.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.reviewQueueSessions) { session in
                            PullRequestQueueRow(
                                session: session,
                                isAnyMergeRunning: model.mergingSessionID != nil,
                                onOpen: { model.openPullRequest(session) },
                                onRefresh: {
                                    model.refreshPullRequest(session, reportErrors: true)
                                },
                                onMarkReady: { model.markPullRequestReady(session) },
                                onSync: { model.syncPullRequestWithBase(session) },
                                onMerge: { pendingMerge = session }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            model.reviewQueueNotice = nil
            model.refreshAllPullRequests()
        }
        .alert(item: $pendingMerge) { session in
            let number = session.pullRequest?.number ?? 0
            return Alert(
                title: Text("Squash Merge PR #\(number)?"),
                message: Text(
                    "GitHub will squash this agent’s commits into \(session.pullRequest?.baseBranch ?? "the base branch"). After a successful merge, Canvas Foundry will archive the agent and remove its clean worktree while preserving the Git branch."
                ),
                primaryButton: .default(Text("Squash Merge")) {
                    model.squashMergePullRequest(session)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.pull")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Review Queue")
                    .font(.foundry(size: 20, weight: .semibold))
                Text("Land agent work one pull request at a time")
                    .font(.foundry(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.refreshAllPullRequests()
            } label: {
                Label("Refresh All", systemImage: "arrow.clockwise")
            }
            .disabled(model.reviewQueueSessions.contains(where: \.isPublishingPullRequest))
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .frame(height: 68)
    }
}

private struct PullRequestQueueRow: View {
    @ObservedObject var session: AgentSession
    let isAnyMergeRunning: Bool
    let onOpen: () -> Void
    let onRefresh: () -> Void
    let onMarkReady: () -> Void
    let onSync: () -> Void
    let onMerge: () -> Void

    var body: some View {
        if let pullRequest = session.pullRequest {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ProviderLogo(provider: session.provider, size: 16)
                        .frame(width: 30, height: 30)
                        .background(
                            session.provider.brandColor.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 7)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(session.name)
                                .font(.foundry(size: 13, weight: .semibold))
                            Text("PR #\(pullRequest.number)")
                                .font(.system(.caption, design: .monospaced, weight: .semibold))
                                .foregroundStyle(.secondary)
                            queueBadge(pullRequest.queueState)
                        }
                        Text(pullRequest.title.isEmpty ? pullRequest.headBranch : pullRequest.title)
                            .font(.foundry(size: 13))
                            .lineLimit(2)
                        Text("\(pullRequest.headBranch) → \(pullRequest.baseBranch)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if session.isPublishingPullRequest {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(session.isPublishingPullRequest)
                    .help("Refresh GitHub status")
                }

                HStack(spacing: 16) {
                    Label("\(pullRequest.changedFiles) files", systemImage: "doc.on.doc")
                    Text("+\(pullRequest.additions)")
                        .foregroundStyle(.green)
                    Text("−\(pullRequest.deletions)")
                        .foregroundStyle(.red)
                    Label(pullRequest.checksStatus.label, systemImage: checksSymbol(pullRequest.checksStatus))
                    Label(pullRequest.reviewDecision.label, systemImage: "person.crop.circle.badge.checkmark")
                }
                .font(.foundry(size: 11))
                .foregroundStyle(.secondary)

                if !pullRequest.checks.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(pullRequest.checks.prefix(4)) { check in
                            Button {
                                if let link = check.link {
                                    NSWorkspace.shared.open(link)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: checkSymbol(check.bucket))
                                    Text(check.name)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(checkColor(check.bucket))
                            .disabled(check.link == nil)
                        }
                    }
                    .font(.foundry(size: 10))
                }

                HStack(spacing: 8) {
                    Button("Open on GitHub", action: onOpen)

                    if pullRequest.state == .open && pullRequest.isDraft {
                        Button("Mark Ready for Review", action: onMarkReady)
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                    } else if pullRequest.state == .open {
                        Button("Sync with \(pullRequest.baseBranch)", action: onSync)
                        Button("Squash Merge", action: onMerge)
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(!pullRequest.isReadyToMerge || isAnyMergeRunning)
                            .help(mergeHelp(pullRequest))
                    }

                    Spacer()
                    Text("Updated \(pullRequest.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.foundry(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .disabled(session.isPublishingPullRequest)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
        }
    }

    private func queueBadge(_ state: PullRequestQueueState) -> some View {
        Text(state.label.uppercased())
            .font(.foundry(size: 9, weight: .bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(queueColor(state))
            .background(queueColor(state).opacity(0.14), in: Capsule())
    }

    private func queueColor(_ state: PullRequestQueueState) -> Color {
        switch state {
        case .readyToMerge, .merged: .green
        case .draft, .checksPending, .reviewRequired, .behind: .orange
        case .checksFailed, .changesRequested, .conflict: .red
        case .blocked, .closed: .secondary
        }
    }

    private func checksSymbol(_ status: PullRequestChecksStatus) -> String {
        switch status {
        case .noChecks: "minus.circle"
        case .passed: "checkmark.circle.fill"
        case .pending: "clock.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private func checkSymbol(_ bucket: String) -> String {
        switch bucket.lowercased() {
        case "pass": "checkmark.circle.fill"
        case "pending": "clock.fill"
        case "skipping": "forward.circle.fill"
        default: "xmark.circle.fill"
        }
    }

    private func checkColor(_ bucket: String) -> Color {
        switch bucket.lowercased() {
        case "pass": .green
        case "pending": .orange
        case "skipping": .secondary
        default: .red
        }
    }

    private func mergeHelp(_ pullRequest: AgentPullRequest) -> String {
        pullRequest.isReadyToMerge
            ? "Squash merge this pull request"
            : "Cannot merge: \(pullRequest.queueState.label.lowercased())"
    }
}
