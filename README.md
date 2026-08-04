# Canvas Foundry

Canvas Foundry is a native macOS workspace for running Claude Code and OpenAI Codex in parallel. Each agent receives an isolated Git branch and worktree, while its live output stays visible as a movable card on an infinite canvas.

## Current milestone

The first vertical slice is functional:

- Native SwiftUI macOS application with a zoomable, pannable canvas.
- Git project picker.
- Concurrent Claude Code and Codex agent sessions.
- One automatically-created branch and worktree per session.
- Live merged stdout/stderr streaming into draggable agent cards.
- Honest lifecycle states: preparing, working, completed, stopped, and failed.
- Stop controls and Finder reveal actions.

Canvas Foundry intentionally uses the user's existing CLI authentication. It does not store API keys.

## Requirements

- macOS 14 or later.
- Xcode 15.3 or later, or the matching Swift 5.10 toolchain.
- Git.
- At least one supported CLI on `PATH`:
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
  - [OpenAI Codex CLI](https://github.com/openai/codex)

## Run

```bash
swift run CanvasFoundry
```

For day-to-day development, open `Package.swift` in Xcode and run the `CanvasFoundry` executable scheme.

## How isolation works

For every new session, Canvas Foundry:

1. Resolves the selected repository root with `git rev-parse`.
2. Creates a unique `canvas/<task>-<id>` branch from `HEAD`.
3. Adds a worktree under `~/Library/Application Support/CanvasFoundry/Worktrees`.
4. Starts the chosen CLI with that worktree as its current directory.

Worktrees are not deleted automatically because they may contain uncommitted agent work.

## Architecture

```text
SwiftUI workspace
├── Infinite canvas + draggable agent cards
├── WorkspaceModel (session orchestration)
├── GitWorktreeManager (branch/worktree isolation)
└── AgentProcessController (CLI lifecycle + streamed output)
```

## Product roadmap

### Milestone 2 — real terminal sessions

- Replace pipe-only output with a PTY-backed terminal core.
- Add interactive stdin and ANSI rendering.
- Persist and restore canvases, cards, and sessions.
- Detect installed agent CLIs and account state before launch.

### Milestone 3 — fleet orchestration

- Fleet sidebar grouped by `needs you`, active agents, and preview windows.
- Shared task graph with dependencies and hand-offs.
- Diff summaries, test status, commit review, and selective merge/cherry-pick.
- Project policies for permissions, commands, and sandboxing.

### Milestone 4 — spatial development environment

- Browser and simulator preview nodes.
- File, note, image, and task nodes.
- Multiple named canvases per project.
- Command palette and keyboard-first stage/focus mode.

### Milestone 5 — voice and external control

- On-device speech-to-text command surface.
- Natural-language routing to one agent, a selected group, or the fleet.
- Local control API and MCP server for external orchestration.

## Safety boundary

The app launches the agent CLIs in their normal non-interactive execution modes and does not add unsafe permission-bypass flags. Git worktree cleanup and branch deletion should remain explicit user actions in a later review UI.
