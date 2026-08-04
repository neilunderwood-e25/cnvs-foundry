# Canvas Foundry

Canvas Foundry is a native macOS workspace for running interactive Claude Code and OpenAI Codex terminals in parallel. Each terminal receives an isolated Git branch and worktree, while the full CLI stays usable inside a movable card on an infinite canvas.

## Core interaction model

An agent is an interactive CLI terminal session, not a prompt form. After choosing a project, select **New Agent → Open Claude Code** or **Open Codex** and Canvas Foundry immediately creates a worktree and opens the real CLI. Prompts are typed directly into Claude or Codex.

## Current milestone

The first vertical slice is functional:

- Native SwiftUI macOS application with a zoomable, pannable canvas.
- Git project picker with local initialization for empty folders and unborn repositories.
- Concurrent, interactive Claude Code and Codex PTY sessions.
- A unique, stable call sign for every Claude Code and Codex agent.
- Durable project, canvas, and agent-card state restored between app launches.
- Explicit relaunching of restored agents in their existing worktrees.
- Fleet sidebar with focus navigation, inline renaming, archive/restore, and guarded worktree removal.
- Per-agent Git review with changed files, commits, patches, test execution, merge, and cherry-pick actions.
- Main-project, per-agent worktree, and generated multi-root workspace launch in installed Cursor or Visual Studio Code applications.
- Per-agent draft GitHub PR publishing, persisted PR status, and branch update actions through authenticated GitHub CLI.
- One automatically-created branch and worktree per session.
- Full ANSI color, keyboard input, selection, scrolling, resizing, and terminal escape-sequence support.
- Draggable and resizable terminal cards.
- Collision-aware placement keeps newly opened terminals from covering existing cards.
- Pixel-stable terminal surfaces keep text crisp and interaction responsive while the canvas pans or zooms.
- Native AppKit card compositing keeps terminal dragging outside SwiftUI's render loop.
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
- To publish pull requests: [GitHub CLI](https://cli.github.com/) authenticated with `gh auth login`.

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
4. Starts the chosen interactive CLI in a pseudo-terminal with that worktree as its current directory.

Worktrees are not deleted automatically because they may contain uncommitted agent work.

## Architecture

```text
SwiftUI workspace
├── Infinite canvas + draggable agent cards
├── WorkspaceModel (session orchestration)
├── GitWorktreeManager (branch/worktree isolation)
└── AgentTerminalRuntime (PTY lifecycle + terminal emulation)
```

## Product roadmap

### Milestone 2 — durable sessions

- Persist and restore canvases, cards, and sessions.
- Detect installed agent CLIs and account state before launch.
- Reconnect restored cards to surviving terminal sessions.

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

The app launches the agent CLIs in their normal interactive modes and does not add unsafe permission-bypass flags. Git worktree cleanup and branch deletion remain explicit user actions because worktrees may contain uncommitted work.
