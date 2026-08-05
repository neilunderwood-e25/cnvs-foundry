import AppKit
import SwiftUI
import XCTest
@testable import CanvasFoundry

final class CanvasFoundryTests: XCTestCase {
    func testVoiceActivityDetectorEndsAfterSpeechAndSilence() {
        let detector = LocalVoiceActivityDetector(
            silenceDuration: 0.8,
            noSpeechTimeout: 8,
            maximumDuration: 30,
            minimumSpeechDuration: 0.12
        )

        var endpoint: LocalVoiceActivityDetector.Endpoint?
        for _ in 0..<4 {
            endpoint = detector.process(decibels: -24, duration: 0.05)?.endpoint ?? endpoint
        }
        XCTAssertNil(endpoint)
        for _ in 0..<7 {
            endpoint = detector.process(decibels: -70, duration: 0.1)?.endpoint ?? endpoint
        }
        XCTAssertNil(endpoint, "a short pause should not submit mid-thought")
        endpoint = detector.process(decibels: -70, duration: 0.1)?.endpoint ?? endpoint
        XCTAssertEqual(endpoint, .silence)
    }

    func testVoiceActivityDetectorTimesOutWhenNothingIsSaid() {
        let detector = LocalVoiceActivityDetector(
            silenceDuration: 1,
            noSpeechTimeout: 1,
            maximumDuration: 30,
            minimumSpeechDuration: 0.12
        )

        var endpoint: LocalVoiceActivityDetector.Endpoint?
        for _ in 0..<10 {
            endpoint = detector.process(decibels: -72, duration: 0.1)?.endpoint ?? endpoint
        }
        XCTAssertEqual(endpoint, .noSpeech)
    }

    func testVoiceActivityDetectorIgnoresBriefNoiseAndCapsLongSpeech() {
        let briefNoise = LocalVoiceActivityDetector(
            silenceDuration: 0.5,
            noSpeechTimeout: 2,
            maximumDuration: 30,
            minimumSpeechDuration: 0.12
        )
        XCTAssertNil(briefNoise.process(decibels: -20, duration: 0.04)?.endpoint)
        for _ in 0..<10 {
            XCTAssertNotEqual(
                briefNoise.process(decibels: -70, duration: 0.1)?.endpoint,
                .silence,
                "one click or knock must not count as a spoken command"
            )
        }

        let capped = LocalVoiceActivityDetector(
            silenceDuration: 1,
            noSpeechTimeout: 10,
            maximumDuration: 1,
            minimumSpeechDuration: 0.1
        )
        var endpoint: LocalVoiceActivityDetector.Endpoint?
        for _ in 0..<10 {
            endpoint = capped.process(decibels: -22, duration: 0.1)?.endpoint ?? endpoint
        }
        XCTAssertEqual(endpoint, .maximumDuration)
    }

    func testBundledBrandAssetsAndInterFontsLoad() {
        FoundryBrand.registerBundledFonts()

        XCTAssertNotNil(FoundryBrand.markImage)
        XCTAssertNotNil(NSFont(name: "Inter-Regular", size: 13))
        XCTAssertNotNil(NSFont(name: "Inter-Medium", size: 13))
        XCTAssertNotNil(NSFont(name: "Inter-SemiBold", size: 13))
        XCTAssertNotNil(NSFont(name: "Inter-Bold", size: 13))
    }

    func testProviderLaunchPlansOpenInteractiveCLIs() {
        XCTAssertEqual(
            AgentProvider.claude.launchPlan(),
            AgentLaunchPlan(executable: "claude", arguments: [])
        )
        XCTAssertEqual(
            AgentProvider.codex.launchPlan(),
            AgentLaunchPlan(executable: "codex", arguments: [])
        )
        XCTAssertEqual(
            AgentProvider.claude.launchPlan(resuming: true),
            AgentLaunchPlan(executable: "claude", arguments: ["--continue"])
        )
        XCTAssertEqual(
            AgentProvider.codex.launchPlan(resuming: true),
            AgentLaunchPlan(executable: "codex", arguments: ["resume", "--last"])
        )
        XCTAssertEqual(
            AgentProvider.claude.launchPlan(initialPrompt: "fix the sidebar"),
            AgentLaunchPlan(executable: "claude", arguments: ["fix the sidebar"])
        )
        XCTAssertEqual(
            AgentProvider.codex.launchPlan(initialPrompt: "run the tests"),
            AgentLaunchPlan(executable: "codex", arguments: ["run the tests"])
        )
    }

    func testBranchSlugIsSafeAndBounded() {
        let slug = GitWorktreeManager.slug("  Build OAuth 2.0 / Login!!! with a deliberately very long title  ")

        XCTAssertEqual(slug, "build-oauth-2-0-login-with-a-deliber")
        XCTAssertLessThanOrEqual(slug.count, 36)
        XCTAssertFalse(slug.contains("/"))
        XCTAssertFalse(slug.contains(" "))
    }

    func testRepositoryHashIsStable() {
        XCTAssertEqual(
            GitWorktreeManager.fnv1a("/tmp/example"),
            GitWorktreeManager.fnv1a("/tmp/example")
        )
        XCTAssertNotEqual(
            GitWorktreeManager.fnv1a("/tmp/example"),
            GitWorktreeManager.fnv1a("/tmp/another")
        )
    }

    func testExecutableResolverFindsAKnownCLI() {
        let result = ExecutableResolver.resolve(
            "sh",
            in: [URL(fileURLWithPath: "/bin", isDirectory: true)]
        )

        XCTAssertEqual(result?.path, "/bin/sh")
    }

    func testGeneratedIDEWorkspaceContainsDistinctLabeledRoots() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("Canvas Foundry IDE-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let project = scratch.appendingPathComponent("Main Project", isDirectory: true)
        let ada = scratch.appendingPathComponent("Ada Worktree", isDirectory: true)
        let grace = scratch.appendingPathComponent("Grace Worktree", isDirectory: true)
        let storage = scratch.appendingPathComponent("Generated Workspaces", isDirectory: true)
        for directory in [project, ada, grace] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let workspaceURL = try IDEProjectOpener.makeMultiRootWorkspace(
            projectURL: project,
            folders: [
                .init(name: "Main — Main Project", url: project),
                .init(name: "Ada — Claude", url: ada),
                .init(name: "Grace — Codex", url: grace),
                .init(name: "Duplicate Ada", url: ada)
            ],
            storageRoot: storage
        )

        XCTAssertEqual(workspaceURL.pathExtension, "code-workspace")
        XCTAssertEqual(workspaceURL.deletingLastPathComponent(), storage)

        let data = try Data(contentsOf: workspaceURL)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let folders = try XCTUnwrap(json["folders"] as? [[String: String]])
        XCTAssertEqual(folders.count, 3)
        XCTAssertEqual(folders.compactMap { $0["name"] }, [
            "Main — Main Project", "Ada — Claude", "Grace — Codex"
        ])
        XCTAssertEqual(folders.compactMap { $0["path"] }, [
            project.path, ada.path, grace.path
        ])
    }

    func testCanvasBackgroundSurvivesAPersistenceRoundTripAndOldSnapshots() throws {
        let snapshot = WorkspaceSnapshot(
            projectPath: "/tmp/Main Project",
            zoom: 1,
            panX: 12,
            panY: 34,
            selectedSessionID: nil,
            sessions: [],
            canvasBackground: CanvasBackground.plum.rawValue
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.canvasBackground, "plum")
        XCTAssertEqual(
            decoded.canvasBackground.flatMap(CanvasBackground.init(rawValue:)),
            .plum
        )

        // Snapshots written before backdrops existed carry no key at all, and
        // must decode rather than throw.
        let legacy = Data(
            """
            {"version":1,"zoom":1,"panX":0,"panY":0,"sessions":[]}
            """.utf8
        )
        let legacySnapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: legacy)
        XCTAssertNil(legacySnapshot.canvasBackground)
        XCTAssertEqual(
            legacySnapshot.canvasBackground
                .flatMap(CanvasBackground.init(rawValue:)) ?? .fallback,
            .midnight
        )

        // An unknown value (older app, newer file) also lands on the default.
        XCTAssertEqual(CanvasBackground(rawValue: "aurora") ?? .fallback, .midnight)
    }

    func testAnnotationHitTestingMatchesStrokesNotHollowInteriors() {
        let stroke = CanvasAnnotation(
            kind: .freehand,
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
            color: .chalk
        )
        XCTAssertTrue(stroke.hitTest(CGPoint(x: 50, y: 4), tolerance: 8))
        XCTAssertFalse(stroke.hitTest(CGPoint(x: 50, y: 40), tolerance: 8))

        let box = CanvasAnnotation(
            kind: .rectangle,
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 120)],
            color: .amber
        )
        XCTAssertTrue(box.hitTest(CGPoint(x: 0, y: 60), tolerance: 8), "edge should hit")
        XCTAssertFalse(
            box.hitTest(CGPoint(x: 100, y: 60), tolerance: 8),
            "hollow middle should not hit"
        )

        let ring = CanvasAnnotation(
            kind: .ellipse,
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)],
            color: .mint
        )
        XCTAssertTrue(ring.hitTest(CGPoint(x: 50, y: 0), tolerance: 8))
        XCTAssertFalse(ring.hitTest(CGPoint(x: 50, y: 50), tolerance: 8))

        let note = CanvasAnnotation(
            kind: .text,
            points: [CGPoint(x: 10, y: 10)],
            color: .sky,
            text: "Ship the review queue"
        )
        XCTAssertTrue(note.hitTest(CGPoint(x: 14, y: 16), tolerance: 4))
        XCTAssertFalse(note.hitTest(CGPoint(x: 400, y: 300), tolerance: 4))
    }

    @MainActor
    func testAnnotationEditingErasingAndUndo() {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("Canvas Foundry Ink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let model = WorkspaceModel(
            persistence: WorkspacePersistence(
                fileURL: scratch.appendingPathComponent("workspace.json")
            )
        )
        XCTAssertFalse(model.canUndoAnnotationEdit)

        let stroke = CanvasAnnotation(
            kind: .line,
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 90, y: 0)],
            color: .chalk
        )
        model.addAnnotation(stroke)
        XCTAssertEqual(model.annotations.count, 1)

        // A shape dragged nowhere is a stray click and must not be kept.
        model.addAnnotation(
            CanvasAnnotation(
                kind: .rectangle,
                points: [CGPoint(x: 5, y: 5), CGPoint(x: 5.5, y: 5.5)],
                color: .chalk
            )
        )
        XCTAssertEqual(model.annotations.count, 1, "degenerate shape should be dropped")

        let note = CanvasAnnotation(kind: .text, points: [.zero], color: .rose)
        model.addAnnotation(note)
        model.updateAnnotationText(note.id, to: "   ")
        XCTAssertEqual(
            model.annotations.count,
            1,
            "a blank note leaves an invisible hit box, so it should be removed"
        )

        XCTAssertFalse(model.eraseAnnotations(near: CGPoint(x: 45, y: 90), tolerance: 6))
        XCTAssertTrue(model.eraseAnnotations(near: CGPoint(x: 45, y: 2), tolerance: 6))
        XCTAssertTrue(model.annotations.isEmpty)

        model.undoAnnotationEdit()
        XCTAssertEqual(model.annotations.map(\.id), [stroke.id], "undo should restore the stroke")
    }

    @MainActor
    func testScrollPanningAndAnchoredZoomKeepThePointerFixed() {
        let model = inkModel()
        model.pan = CGSize(width: 180, height: 130)
        model.zoom = 1

        model.panBy(CGSize(width: -40, height: 25))
        XCTAssertEqual(model.pan.width, 140, accuracy: 0.001)
        XCTAssertEqual(model.pan.height, 155, accuracy: 0.001)

        // Whatever sits under the cursor must not move while zooming, or
        // scroll-zoom drifts away from what the user is pointing at.
        let pointer = CGPoint(x: 620, y: 410)
        let worldUnderPointer = CGPoint(
            x: (pointer.x - model.pan.width) / model.zoom,
            y: (pointer.y - model.pan.height) / model.zoom
        )

        model.zoom(by: 1.2, anchoredAt: pointer)
        XCTAssertEqual(model.zoom, 1.2, accuracy: 0.001)
        XCTAssertEqual(
            worldUnderPointer.x * model.zoom + model.pan.width,
            pointer.x,
            accuracy: 0.001
        )
        XCTAssertEqual(
            worldUnderPointer.y * model.zoom + model.pan.height,
            pointer.y,
            accuracy: 0.001
        )

        // Still fixed when zooming back out, and clamped at the limits.
        model.zoom(by: 0.5, anchoredAt: pointer)
        XCTAssertEqual(
            worldUnderPointer.x * model.zoom + model.pan.width,
            pointer.x,
            accuracy: 0.001
        )

        for _ in 0..<40 { model.zoom(by: 1.25, anchoredAt: pointer) }
        XCTAssertEqual(model.zoom, 1.8, accuracy: 0.001)
        for _ in 0..<40 { model.zoom(by: 0.8, anchoredAt: pointer) }
        XCTAssertEqual(model.zoom, 0.45, accuracy: 0.001)

        // The anchor still holds after clamping, so the canvas cannot creep.
        XCTAssertEqual(
            worldUnderPointer.x * model.zoom + model.pan.width,
            pointer.x,
            accuracy: 0.001
        )
    }

    func testToolCursorsDistinguishDrawingFromPanning() {
        XCTAssertEqual(CanvasTool.select.cursor, NSCursor.arrow)
        XCTAssertEqual(CanvasTool.hand.cursor, NSCursor.openHand)
        XCTAssertEqual(CanvasTool.text.cursor, NSCursor.iBeam)
        for tool in [CanvasTool.pen, .rectangle, .ellipse, .line, .arrow, .eraser] {
            XCTAssertEqual(tool.cursor, NSCursor.crosshair, "\(tool) should draw with a crosshair")
        }
    }

    func testCommandBarParsesTheHeadlineRequest() {
        let plan = WorkspaceCommandParser.parse("add 3 claude agents and one code agent")

        XCTAssertEqual(plan.commands, [
            .createAgents(provider: .claude, count: 3),
            .createAgents(provider: .codex, count: 1)
        ])
        XCTAssertTrue(plan.unrecognized.isEmpty)
        XCTAssertEqual(plan.summary, "3 × Claude, 1 × Codex")
    }

    func testCommandBarHandlesCountsSynonymsAndSeparators() {
        // Digits, number words and articles all mean a count.
        XCTAssertEqual(
            WorkspaceCommandParser.parse("spin up two codex terminals").commands,
            [.createAgents(provider: .codex, count: 2)]
        )
        XCTAssertEqual(
            WorkspaceCommandParser.parse("open a claude agent").commands,
            [.createAgents(provider: .claude, count: 1)]
        )
        XCTAssertEqual(
            WorkspaceCommandParser.parse("give me a couple of claude agents").commands,
            [.createAgents(provider: .claude, count: 2)]
        )

        // Commas and "+" separate requests just like "and".
        XCTAssertEqual(
            WorkspaceCommandParser.parse("2 claude agents, 1 codex agent").commands,
            [
                .createAgents(provider: .claude, count: 2),
                .createAgents(provider: .codex, count: 1)
            ]
        )

        // Mishearings that dictation will produce constantly.
        for spoken in ["add a cloud agent", "add a clawed agent", "add a claud agent"] {
            XCTAssertEqual(
                WorkspaceCommandParser.parse(spoken).commands,
                [.createAgents(provider: .claude, count: 1)],
                "\(spoken) should resolve to Claude"
            )
        }
        for spoken in ["open one code agent", "open one coder agent", "open one openai agent"] {
            XCTAssertEqual(
                WorkspaceCommandParser.parse(spoken).commands,
                [.createAgents(provider: .codex, count: 1)],
                "\(spoken) should resolve to Codex"
            )
        }
    }

    func testVoiceCommandNormalizationCorrectsHighConfidenceDictationArtifacts() {
        XCTAssertEqual(
            WorkspaceCommandParser.parse("One two more Claude agents").commands,
            [.createAgents(provider: .claude, count: 2)]
        )
        XCTAssertEqual(
            WorkspaceCommandParser.parse("open two code ex agents").commands,
            [.createAgents(provider: .codex, count: 2)]
        )

        // Without “more”, consecutive numbers remain ambiguous. Do not guess
        // that the speaker corrected themselves.
        XCTAssertEqual(
            WorkspaceCommandParser.normalizeSpeechArtifacts(in: "one two Claude agents"),
            "one two claude agents"
        )
    }

    func testVoiceAcknowledgementsAreLocalDeterministicTemplates() {
        let plan = WorkspaceCommandParser.parse("open two Claude agents")
        XCTAssertEqual(
            plan.spokenAcknowledgement,
            "Opening two Claude agents now."
        )

        let multi = WorkspaceCommandParser.parse("open one codex agent and reset the view")
        XCTAssertEqual(
            multi.spokenAcknowledgement,
            "Opening one Codex agent now. Resetting the canvas view."
        )
    }

    func testVoiceCanRoutePromptsToNamedAgentsWithoutAnLLM() {
        let names = ["Reese", "Agent 51"]
        let cases: [(String, WorkspaceCommand)] = [
            (
                "say hi to Reese",
                .sendPrompt(name: "Reese", prompt: "hi")
            ),
            (
                "tell Reese to run the tests",
                .sendPrompt(name: "Reese", prompt: "run the tests")
            ),
            (
                "ask Agent 51 to inspect and fix the sidebar",
                .sendPrompt(name: "Agent 51", prompt: "inspect and fix the sidebar")
            ),
            (
                "send to Reese review the current diff",
                .sendPrompt(name: "Reese", prompt: "review the current diff")
            )
        ]

        for (utterance, expected) in cases {
            let plan = WorkspaceCommandParser.parse(
                utterance,
                knownAgentNames: names
            )
            XCTAssertEqual(plan.commands, [expected], utterance)
            XCTAssertTrue(plan.unrecognized.isEmpty, utterance)
        }

        let greeting = WorkspaceCommandParser.parse(
            "say hi to Reese",
            knownAgentNames: names
        )
        XCTAssertEqual(greeting.spokenAcknowledgement, "Sending that to Reese.")

        // Unknown targets and empty prompts must not be guessed at.
        XCTAssertTrue(
            WorkspaceCommandParser.parse(
                "say hi to Morgan",
                knownAgentNames: names
            ).isEmpty
        )
        XCTAssertTrue(
            WorkspaceCommandParser.parse(
                "tell Reese",
                knownAgentNames: names
            ).isEmpty
        )
    }

    func testVoiceCanCreateOneAgentWithAnInitialTask() {
        XCTAssertEqual(
            WorkspaceCommandParser.parse(
                "open a Claude agent to fix the sidebar animation"
            ).commands,
            [.createAgentWithPrompt(
                provider: .claude,
                prompt: "fix the sidebar animation"
            )]
        )
        XCTAssertEqual(
            WorkspaceCommandParser.parse(
                "start a Codex agent to inspect and fix the tests"
            ).commands,
            [.createAgentWithPrompt(
                provider: .codex,
                prompt: "inspect and fix the tests"
            )],
            "a conjunction inside the task must not split into canvas commands"
        )

        let plan = WorkspaceCommandParser.parse(
            "open a Claude agent to review the current diff"
        )
        XCTAssertEqual(
            plan.spokenAcknowledgement,
            "Opening a Claude agent for that now."
        )

        // A single shared prompt for multiple agents is ambiguous and must not
        // silently launch idle worktrees or duplicate the same assignment.
        XCTAssertTrue(
            WorkspaceCommandParser.parse(
                "open two Claude agents to fix the sidebar"
            ).isEmpty
        )
    }

    func testVoiceCanStopAndResumeNamedAgents() {
        let names = ["Reese", "Agent 51"]
        let cases: [(String, WorkspaceCommand)] = [
            ("stop Reese", .stopAgent(name: "Reese")),
            ("pause Agent 51", .stopAgent(name: "Agent 51")),
            ("resume Reese", .resumeAgent(name: "Reese")),
            ("restart the agent Agent 51", .resumeAgent(name: "Agent 51")),
            ("wake Reese", .resumeAgent(name: "Reese"))
        ]

        for (utterance, expected) in cases {
            XCTAssertEqual(
                WorkspaceCommandParser.parse(
                    utterance,
                    knownAgentNames: names
                ).commands,
                [expected],
                utterance
            )
        }

        XCTAssertEqual(
            WorkspaceCommandParser.parse(
                "stop Reese",
                knownAgentNames: names
            ).spokenAcknowledgement,
            "Stopping Reese now."
        )
        XCTAssertEqual(
            WorkspaceCommandParser.parse(
                "resume Agent 51",
                knownAgentNames: names
            ).spokenAcknowledgement,
            "Resuming Agent 51 now."
        )
        XCTAssertTrue(
            WorkspaceCommandParser.parse(
                "stop Morgan",
                knownAgentNames: names
            ).isEmpty
        )
    }

    @MainActor
    func testLifecycleCommandStopsARealRunningPTYAndRejectsDuplicateStop() throws {
        let session = AgentSession(provider: .claude, name: "Reese", position: .zero)
        let runtime = try AgentTerminalRuntime(
            session: session,
            directory: FileManager.default.temporaryDirectory,
            executableOverride: URL(fileURLWithPath: "/bin/cat"),
            argumentsOverride: []
        )
        session.runtime = runtime
        session.status = .needsYou("Waiting for approval")

        let model = inkModel()
        model.sessions = [session]
        let stopped = model.run(
            WorkspaceCommandParser.parse("stop Reese", knownAgentNames: ["Reese"])
        )

        XCTAssertEqual(stopped.commands, [.stopAgent(name: "Reese")])
        XCTAssertEqual(session.status, .stopped)

        let duplicate = model.run(.stopAgent(name: "Reese"))
        XCTAssertFalse(duplicate)
        guard case .message(let message) = model.alertState else {
            return XCTFail("Expected an already-stopped explanation")
        }
        XCTAssertTrue(message.contains("already stopped"))
    }

    @MainActor
    func testResumeCommandRequiresThePreservedWorktree() {
        let model = inkModel()
        let session = AgentSession(provider: .codex, name: "Reese", position: .zero)
        session.status = .stopped
        model.sessions = [session]

        let resumed = model.run(.resumeAgent(name: "Reese"))

        XCTAssertFalse(resumed)
        guard case .failed(let message) = session.status else {
            return XCTFail("Expected the missing-worktree failure")
        }
        XCTAssertTrue(message.contains("isolated workspace"))
    }

    func testInitialAgentPromptIsSanitizedAndProducesTheTaskSlug() {
        let normalized = AgentTerminalRuntime.normalizedPrompt(
            "  Fix sidebar\u{1b}\n animation  "
        )
        XCTAssertEqual(normalized, "Fix sidebar animation")
        XCTAssertEqual(
            GitWorktreeManager.slug(normalized),
            "fix-sidebar-animation"
        )
    }

    @MainActor
    func testTargetedPromptWritesOneSanitizedLineToTheAgentPTY() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryPrompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let captureURL = scratch.appendingPathComponent("prompt.txt")
        let session = AgentSession(provider: .claude, name: "Reese", position: .zero)
        let runtime = try AgentTerminalRuntime(
            session: session,
            directory: scratch,
            executableOverride: URL(fileURLWithPath: "/bin/sh"),
            argumentsOverride: [
                "-c",
                "IFS= read -r line; printf '%s' \"$line\" > \"$1\"",
                "capture-prompt",
                captureURL.path
            ]
        )

        try runtime.submitPrompt("say hello\u{1b}\nthen run tests")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: captureURL.path) {
            try await Task.sleep(for: .milliseconds(20))
        }

        let captured = try String(contentsOf: captureURL, encoding: .utf8)
        XCTAssertEqual(captured, "say hello then run tests")
        XCTAssertThrowsError(try runtime.submitPrompt("another prompt")) { error in
            guard case AgentTerminalError.processNotRunning = error else {
                return XCTFail("Expected a stopped-process error, got \(error)")
            }
        }
    }

    @MainActor
    func testTargetedPromptExplainsWhenTheRestoredAgentIsNotRunning() {
        let model = inkModel()
        let reese = AgentSession(provider: .claude, name: "Reese", position: .zero)
        reese.status = .stopped
        model.sessions = [reese]

        model.run(.sendPrompt(name: "Reese", prompt: "say hi"))

        guard case .message(let message) = model.alertState else {
            return XCTFail("Expected a lifecycle explanation")
        }
        XCTAssertTrue(message.contains("isn't running"))
        XCTAssertTrue(message.contains("Relaunch"))
    }

    func testCommandBarRefusesRunawayAndAmbiguousRequests() {
        // Each agent is a worktree plus a process, so the count is clamped.
        let runaway = WorkspaceCommandParser.parse("add 500 claude agents")
        XCTAssertEqual(
            runaway.commands,
            [.createAgents(
                provider: .claude,
                count: WorkspaceCommandParser.maximumAgentsPerCommand
            )]
        )
        XCTAssertFalse(runaway.notes.isEmpty, "clamping must be reported, not silent")

        // A bare provider name is not an instruction.
        XCTAssertTrue(WorkspaceCommandParser.parse("claude").isEmpty)

        // Nonsense is reported rather than guessed at.
        let nonsense = WorkspaceCommandParser.parse("make me a sandwich")
        XCTAssertTrue(nonsense.isEmpty)
        XCTAssertEqual(nonsense.unrecognized, ["make me a sandwich"])

        // A good clause still runs when a sibling clause is gibberish.
        let mixed = WorkspaceCommandParser.parse("add 2 codex agents and order pizza")
        XCTAssertEqual(mixed.commands, [.createAgents(provider: .codex, count: 2)])
        XCTAssertEqual(mixed.unrecognized, ["order pizza"])
    }

    func testCommandBarParsesCanvasAndNavigationVerbs() {
        XCTAssertEqual(
            WorkspaceCommandParser.parse("switch to plum").commands,
            [.setBackground(.plum)]
        )
        XCTAssertEqual(
            WorkspaceCommandParser.parse("make the background forest").commands,
            [.setBackground(.forest)]
        )
        XCTAssertEqual(
            WorkspaceCommandParser.parse("use the pen tool").commands,
            [.selectTool(.pen)]
        )
        XCTAssertEqual(
            WorkspaceCommandParser.parse("clear the drawings").commands,
            [.clearDrawings]
        )
        XCTAssertEqual(
            WorkspaceCommandParser.parse("reset the view").commands,
            [.resetView]
        )

        // "reset" is shared between two verbs; the noun decides which.
        XCTAssertEqual(
            WorkspaceCommandParser.parse("reset the annotations").commands,
            [.clearDrawings]
        )

        // Focus only matches an agent that exists, so stray names do nothing.
        XCTAssertEqual(
            WorkspaceCommandParser.parse("find ada", knownAgentNames: ["Ada", "Grace"]).commands,
            [.focusAgent(name: "Ada")]
        )
        XCTAssertTrue(WorkspaceCommandParser.parse("find ada").isEmpty)

        // A backdrop word must not hijack an agent request.
        XCTAssertEqual(
            WorkspaceCommandParser.parse("add an ink codex agent").commands,
            [.createAgents(provider: .codex, count: 1)]
        )
    }

    @MainActor
    func testCommandExecutionDrivesTheWorkspace() {
        let model = inkModel()

        model.run(WorkspaceCommandParser.parse("switch to graphite and use the arrow tool"))
        XCTAssertEqual(model.canvasBackground, .graphite)
        XCTAssertEqual(model.activeTool, .arrow)

        model.addAnnotation(
            CanvasAnnotation(
                kind: .line,
                points: [CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 0)],
                color: .chalk
            )
        )
        model.run(WorkspaceCommandParser.parse("clear the board"))
        XCTAssertTrue(model.annotations.isEmpty)
        // Clearing is undoable, which is why voice is allowed to do it.
        model.undoAnnotationEdit()
        XCTAssertEqual(model.annotations.count, 1)

        // Asking for agents without a project explains itself instead of crashing.
        XCTAssertNil(model.projectURL)
        model.run(WorkspaceCommandParser.parse("add 3 claude agents"))
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNotNil(model.alertState)
    }

    func testTextNoteBoxIsMeasuredAndGrowsWithLines() {
        FoundryBrand.registerBundledFonts()

        let short = CanvasAnnotation(kind: .text, points: [.zero], color: .chalk, text: "hi")
        let long = CanvasAnnotation(
            kind: .text,
            points: [.zero],
            color: .chalk,
            text: "a considerably longer thought about the review queue"
        )
        XCTAssertGreaterThan(
            long.boundingBox.width,
            short.boundingBox.width,
            "the hit box must follow the laid-out run, not a fixed width"
        )
        XCTAssertEqual(
            short.boundingBox.height,
            long.boundingBox.height,
            accuracy: 1,
            "single lines should be the same height regardless of length"
        )

        // Multi-line notes must grow downwards, or the lower lines would sit
        // outside the box and be unselectable.
        let twoLines = CanvasAnnotation(
            kind: .text,
            points: [.zero],
            color: .chalk,
            text: "first line\nsecond line"
        )
        XCTAssertGreaterThan(twoLines.boundingBox.height, short.boundingBox.height * 1.5)
        XCTAssertTrue(
            twoLines.hitTest(
                CGPoint(x: 4, y: twoLines.boundingBox.height - 2),
                tolerance: 1
            ),
            "the second line should be inside the hit box"
        )

        // An empty note still needs a clickable box while it is being typed.
        let empty = CanvasAnnotation(kind: .text, points: [.zero], color: .chalk)
        XCTAssertGreaterThan(empty.boundingBox.width, 0)
        XCTAssertGreaterThan(empty.boundingBox.height, 0)
    }

    @MainActor
    func testGroupedAnnotationsSelectAndMoveTogether() {
        let model = inkModel()

        let left = CanvasAnnotation(
            kind: .rectangle,
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 40)],
            color: .sky
        )
        let right = CanvasAnnotation(
            kind: .ellipse,
            points: [CGPoint(x: 200, y: 0), CGPoint(x: 260, y: 40)],
            color: .mint
        )
        let loner = CanvasAnnotation(
            kind: .line,
            points: [CGPoint(x: 0, y: 400), CGPoint(x: 80, y: 400)],
            color: .rose
        )
        [left, right, loner].forEach(model.addAnnotation)

        // Marquee across the two shapes, but not the far-away line.
        model.selectAnnotations(
            in: CGRect(x: -20, y: -20, width: 400, height: 120),
            additive: false
        )
        XCTAssertEqual(model.selectedAnnotationIDs, [left.id, right.id])
        XCTAssertTrue(model.canGroupSelection)
        XCTAssertFalse(model.canUngroupSelection)

        model.groupSelection()
        XCTAssertTrue(model.canUngroupSelection)
        let groupID = try? XCTUnwrap(
            model.annotations.first { $0.id == left.id }?.groupID
        )
        XCTAssertNotNil(groupID)
        XCTAssertEqual(model.annotations.first { $0.id == right.id }?.groupID, groupID)
        XCTAssertNil(model.annotations.first { $0.id == loner.id }?.groupID)

        // Clicking one member must pull in the whole group.
        model.clearAnnotationSelection()
        model.selectAnnotation(left.id, additive: false)
        XCTAssertEqual(model.selectedAnnotationIDs, [left.id, right.id])

        // Moving the selection moves every member by the same offset.
        model.beginSelectionDrag()
        model.updateSelectionDrag(translation: CGSize(width: 25, height: -10))
        model.updateSelectionDrag(translation: CGSize(width: 50, height: -20))
        model.endSelectionDrag()

        XCTAssertEqual(
            model.annotations.first { $0.id == left.id }?.points,
            [CGPoint(x: 50, y: -20), CGPoint(x: 110, y: 20)],
            "repeated drag frames must apply to the original geometry, not compound"
        )
        XCTAssertEqual(
            model.annotations.first { $0.id == right.id }?.points,
            [CGPoint(x: 250, y: -20), CGPoint(x: 310, y: 20)]
        )
        XCTAssertEqual(
            model.annotations.first { $0.id == loner.id }?.points,
            loner.points,
            "unselected items must not move"
        )

        // One history entry for the whole drag.
        model.undoAnnotationEdit()
        XCTAssertEqual(model.annotations.first { $0.id == left.id }?.points, left.points)

        model.selectAnnotation(left.id, additive: false)
        model.ungroupSelection()
        XCTAssertNil(model.annotations.first { $0.id == left.id }?.groupID)
        model.clearAnnotationSelection()
        model.selectAnnotation(left.id, additive: false)
        XCTAssertEqual(
            model.selectedAnnotationIDs,
            [left.id],
            "after ungrouping, a click should take only the clicked item"
        )
    }

    @MainActor
    func testSelectionShortcutsAndStaleSelectionHandling() {
        let model = inkModel()
        let first = CanvasAnnotation(
            kind: .line,
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 90, y: 0)],
            color: .chalk
        )
        let second = CanvasAnnotation(
            kind: .line,
            points: [CGPoint(x: 0, y: 60), CGPoint(x: 90, y: 60)],
            color: .amber
        )
        [first, second].forEach(model.addAnnotation)

        // Shift-click toggles rather than replaces.
        model.selectAnnotation(first.id, additive: false)
        model.selectAnnotation(second.id, additive: true)
        XCTAssertEqual(model.selectedAnnotationIDs, [first.id, second.id])
        model.selectAnnotation(second.id, additive: true)
        XCTAssertEqual(model.selectedAnnotationIDs, [first.id])

        model.selectAllAnnotations()
        XCTAssertEqual(model.selectedAnnotationIDs.count, 2)
        model.deleteSelectedAnnotations()
        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertTrue(model.selectedAnnotationIDs.isEmpty)

        // Undo brings items back; the selection must not resurrect stale ids.
        model.undoAnnotationEdit()
        XCTAssertEqual(model.annotations.count, 2)
        XCTAssertTrue(model.selectedAnnotationIDs.isEmpty)

        // Erasing a selected item drops it from the selection too, so a later
        // group or move cannot act on something that no longer exists.
        model.selectAllAnnotations()
        XCTAssertTrue(model.eraseAnnotations(near: CGPoint(x: 45, y: 0), tolerance: 6))
        XCTAssertEqual(model.selectedAnnotationIDs, [second.id])
        XCTAssertFalse(model.canGroupSelection)
    }

    @MainActor
    private func inkModel() -> WorkspaceModel {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("Canvas Foundry Ink-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
        return WorkspaceModel(
            persistence: WorkspacePersistence(
                fileURL: scratch.appendingPathComponent("workspace.json")
            )
        )
    }

    func testAnnotationsSurviveAPersistenceRoundTrip() throws {
        let stroke = CanvasAnnotation(
            kind: .arrow,
            points: [CGPoint(x: 1, y: 2), CGPoint(x: 30, y: 40)],
            color: .sky,
            lineWidth: 3,
            text: ""
        )
        let snapshot = WorkspaceSnapshot(
            projectPath: nil,
            zoom: 1,
            panX: 0,
            panY: 0,
            selectedSessionID: nil,
            sessions: [],
            annotations: [
                PersistedAnnotation(
                    id: stroke.id,
                    kind: stroke.kind.rawValue,
                    pointsX: stroke.points.map { Double($0.x) },
                    pointsY: stroke.points.map { Double($0.y) },
                    color: stroke.color.rawValue,
                    lineWidth: Double(stroke.lineWidth),
                    text: nil,
                    groupID: nil
                )
            ]
        )

        let decoded = try JSONDecoder().decode(
            WorkspaceSnapshot.self,
            from: try JSONEncoder().encode(snapshot)
        )
        let restored = try XCTUnwrap(
            (decoded.annotations ?? []).compactMap(CanvasAnnotation.init(persisted:)).first
        )
        XCTAssertEqual(restored, stroke)

        // Mismatched coordinate arrays would crash a naive zip-and-index restore.
        let corrupt = PersistedAnnotation(
            id: UUID(),
            kind: "freehand",
            pointsX: [1, 2, 3],
            pointsY: [1],
            color: "chalk",
            lineWidth: 2,
            text: nil,
            groupID: nil
        )
        XCTAssertNil(CanvasAnnotation(persisted: corrupt))

        let unknownKind = PersistedAnnotation(
            id: UUID(),
            kind: "hexagon",
            pointsX: [1],
            pointsY: [1],
            color: "chalk",
            lineWidth: 2,
            text: nil,
            groupID: nil
        )
        XCTAssertNil(CanvasAnnotation(persisted: unknownKind))
    }

    func testIDELaunchArgumentsForceAnEditorWindowRatherThanAnAgentWindow() {
        XCTAssertEqual(
            ProjectIDE.cursor.editorLaunchArguments(forPath: "/tmp/Main Project"),
            ["editor", "--new-window", "/tmp/Main Project"]
        )
        XCTAssertEqual(
            ProjectIDE.visualStudioCode.editorLaunchArguments(forPath: "/tmp/Main Project"),
            ["--new-window", "/tmp/Main Project"]
        )
        XCTAssertEqual(ProjectIDE.cursor.commandLineToolName, "cursor")
        XCTAssertEqual(ProjectIDE.visualStudioCode.commandLineToolName, "code")
    }

    func testCanvasPlacementAvoidsExistingTerminalFrames() {
        let itemSize = CGSize(width: 520, height: 360)
        let firstCenter = CanvasPlacementEngine.nextCenter(
            existingRects: [],
            viewportSize: CGSize(width: 1400, height: 800),
            itemSize: itemSize
        )
        let firstRect = CGRect(
            x: firstCenter.x - itemSize.width / 2,
            y: firstCenter.y - itemSize.height / 2,
            width: itemSize.width,
            height: itemSize.height
        )
        let secondCenter = CanvasPlacementEngine.nextCenter(
            existingRects: [firstRect],
            viewportSize: CGSize(width: 1400, height: 800),
            itemSize: itemSize
        )
        let secondRect = CGRect(
            x: secondCenter.x - itemSize.width / 2,
            y: secondCenter.y - itemSize.height / 2,
            width: itemSize.width,
            height: itemSize.height
        )

        XCTAssertFalse(firstRect.intersects(secondRect))
        XCTAssertNotEqual(firstCenter, secondCenter)
    }

    func testAgentNamesAreUniqueAndFallBackAfterCallSignsAreUsed() {
        XCTAssertEqual(AgentNameGenerator.names.count, 50)

        let firstName = AgentNameGenerator.nextName(existingNames: [])
        let secondName = AgentNameGenerator.nextName(existingNames: [firstName])

        XCTAssertTrue(AgentNameGenerator.names.contains(firstName))
        XCTAssertTrue(AgentNameGenerator.names.contains(secondName))
        XCTAssertNotEqual(firstName, secondName)

        let usedNames = Set(AgentNameGenerator.names)
        XCTAssertEqual(
            AgentNameGenerator.nextName(existingNames: usedNames),
            "Agent 51"
        )
    }

    @MainActor
    func testWorkspaceRestoresAgentLayoutWithoutLaunchingAProcess() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryPersistence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let project = scratch.appendingPathComponent("project", isDirectory: true)
        let worktree = scratch.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        let sessionID = UUID()
        let persistence = WorkspacePersistence(
            fileURL: scratch.appendingPathComponent("workspace.json")
        )
        let sourceModel = WorkspaceModel(persistence: persistence)
        sourceModel.projectURL = project
        sourceModel.zoom = 1.25
        sourceModel.pan = CGSize(width: 240, height: 160)

        let sourceSession = AgentSession(
            id: sessionID,
            provider: .codex,
            name: "Grace",
            position: CGPoint(x: 510, y: 420)
        )
        sourceSession.size = CGSize(width: 680, height: 440)
        sourceSession.worktree = WorktreeDescriptor(
            projectRoot: project,
            worktreeURL: worktree,
            branchName: "canvas/grace-codex-12345678",
            baseRevision: "deadbeef"
        )
        let pullRequestDate = Date(timeIntervalSince1970: 1_700_000_000)
        sourceSession.pullRequest = AgentPullRequest(
            number: 42,
            url: URL(string: "https://github.com/example/project/pull/42")!,
            state: .open,
            isDraft: true,
            headBranch: "canvas/grace-codex-12345678",
            baseBranch: "main",
            updatedAt: pullRequestDate,
            title: "Add persisted PR state",
            mergeability: .mergeable,
            mergeStateStatus: "CLEAN",
            checksStatus: .passed,
            reviewDecision: .approved,
            headCommitOID: "abc123",
            changedFiles: 3,
            additions: 45,
            deletions: 7,
            checks: [
                PullRequestCheck(
                    name: "tests",
                    workflow: "CI",
                    state: "SUCCESS",
                    bucket: "pass",
                    link: URL(string: "https://github.com/example/project/actions/1")
                )
            ]
        )
        sourceModel.sessions = [sourceSession]
        sourceModel.select(sourceSession)
        sourceModel.persistWorkspace()

        let model = WorkspaceModel(persistence: persistence)

        XCTAssertEqual(model.projectURL?.standardizedFileURL, project.standardizedFileURL)
        XCTAssertEqual(model.recentProjectURLs.first?.standardizedFileURL, project.standardizedFileURL)
        XCTAssertEqual(model.zoom, 1.25)
        XCTAssertEqual(model.pan, CGSize(width: 240, height: 160))
        XCTAssertEqual(model.selectedSessionID, sessionID)
        XCTAssertEqual(model.sessions.count, 1)

        let restored = try XCTUnwrap(model.sessions.first)
        XCTAssertEqual(restored.name, "Grace")
        XCTAssertEqual(restored.provider, .codex)
        XCTAssertEqual(restored.position, CGPoint(x: 510, y: 420))
        XCTAssertEqual(restored.size, CGSize(width: 680, height: 440))
        XCTAssertEqual(restored.worktree?.branchName, "canvas/grace-codex-12345678")
        XCTAssertEqual(restored.worktree?.baseRevision, "deadbeef")
        XCTAssertEqual(restored.pullRequest?.number, 42)
        XCTAssertEqual(restored.pullRequest?.state, .open)
        XCTAssertEqual(restored.pullRequest?.isDraft, true)
        XCTAssertEqual(restored.pullRequest?.updatedAt, pullRequestDate)
        XCTAssertEqual(restored.pullRequest?.title, "Add persisted PR state")
        XCTAssertEqual(restored.pullRequest?.mergeability, .mergeable)
        XCTAssertEqual(restored.pullRequest?.checksStatus, .passed)
        XCTAssertEqual(restored.pullRequest?.reviewDecision, .approved)
        XCTAssertEqual(restored.pullRequest?.headCommitOID, "abc123")
        XCTAssertEqual(restored.pullRequest?.checks.first?.name, "tests")
        XCTAssertEqual(restored.status, .stopped)
        XCTAssertTrue(restored.isSelected)
        XCTAssertNil(restored.runtime)
    }

    @MainActor
    func testFleetRenameArchiveAndRestoreLifecycle() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryFleet-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let persistence = WorkspacePersistence(
            fileURL: scratch.appendingPathComponent("workspace.json")
        )
        let model = WorkspaceModel(persistence: persistence)
        model.projectURL = scratch

        let ada = AgentSession(provider: .claude, name: "Ada", position: .zero)
        let grace = AgentSession(provider: .codex, name: "Grace", position: .zero)
        ada.status = .stopped
        grace.status = .stopped
        model.sessions = [ada, grace]

        model.rename(grace, to: "Ada")
        XCTAssertEqual(grace.name, "Ada 2")

        model.archive(ada)
        XCTAssertTrue(ada.isArchived)
        XCTAssertEqual(model.visibleSessions.map(\.id), [grace.id])

        model.restore(ada)
        XCTAssertFalse(ada.isArchived)
        XCTAssertEqual(model.selectedSessionID, ada.id)
        XCTAssertEqual(model.visibleSessions.count, 2)

        model.archive(ada)
        model.persistWorkspace()
        let restoredModel = WorkspaceModel(persistence: persistence)
        XCTAssertTrue(try XCTUnwrap(restoredModel.sessions.first { $0.id == ada.id }).isArchived)
        XCTAssertFalse(restoredModel.visibleSessions.contains { $0.id == ada.id })

        let nextProject = scratch.appendingPathComponent("next-project", isDirectory: true)
        try FileManager.default.createDirectory(at: nextProject, withIntermediateDirectories: true)
        restoredModel.switchProject(
            ProjectSwitchRequest(
                projectURL: nextProject,
                existingAgentCount: restoredModel.sessions.count
            )
        )
        XCTAssertEqual(restoredModel.projectURL, nextProject)
        XCTAssertTrue(restoredModel.sessions.isEmpty)
        XCTAssertNil(restoredModel.selectedSessionID)
    }

    @MainActor
    func testInteractiveTerminalKeepsAgentNameWhenShellSetsATitle() async throws {
        let session = AgentSession(
            provider: .claude,
            name: "Ada",
            position: .zero
        )
        let runtime = try AgentTerminalRuntime(
            session: session,
            directory: FileManager.default.temporaryDirectory,
            executableOverride: URL(fileURLWithPath: "/bin/cat"),
            argumentsOverride: []
        )

        XCTAssertTrue(runtime.terminalView.process.running)
        XCTAssertEqual(session.status, .working)

        runtime.setTerminalTitle(
            source: runtime.terminalView,
            title: "claude — project/worktree"
        )
        await Task.yield()

        XCTAssertEqual(session.name, "Ada")
        XCTAssertEqual(session.terminalTitle, "claude — project/worktree")

        runtime.stop()
        XCTAssertEqual(session.status, .stopped)
    }

    func testWorktreesLandInsideTheProjectLikeClaudeCode() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryInside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repository = scratch.appendingPathComponent("acme-app", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

        let shell = ShellRunner()
        let git = URL(fileURLWithPath: "/usr/bin/git")
        _ = try await shell.run(
            executableURL: git,
            arguments: ["init", "-b", "main"],
            currentDirectoryURL: repository
        )
        _ = try await shell.run(
            executableURL: git,
            arguments: [
                "-c", "user.name=Canvas Foundry Tests",
                "-c", "user.email=tests@canvas.invalid",
                "commit", "--allow-empty", "-m", "Initial commit"
            ],
            currentDirectoryURL: repository
        )

        // No storage override: the default must be `<project>/.foundry/worktrees`.
        let manager = GitWorktreeManager()
        let first = try await manager.createWorktree(
            for: repository,
            sessionID: UUID(),
            title: "Ada Claude"
        )

        XCTAssertEqual(
            first.worktreeURL.deletingLastPathComponent().resolvingSymlinksInPath().path,
            repository.appendingPathComponent(".foundry/worktrees", isDirectory: true)
                .resolvingSymlinksInPath().path,
            "worktrees should live inside the project, Claude Code style"
        )
        XCTAssertEqual(
            first.worktreeURL.lastPathComponent,
            "ada-claude",
            "folders should carry the agent name, not a hash"
        )

        // In-repo copies are only safe if `.git/info/exclude` hides them: the
        // worktrees themselves must never appear in the project's status. The
        // one visible addition is `.vscode/` — the editor scan-depth setting is
        // deliberately committable, unlike the worktrees.
        let excludeContents = try String(
            contentsOf: repository.appendingPathComponent(".git/info/exclude"),
            encoding: .utf8
        )
        XCTAssertTrue(excludeContents.contains("/.foundry/"))
        let status = try await shell.run(
            executableURL: git,
            arguments: ["status", "--porcelain=v1"],
            currentDirectoryURL: repository
        )
        XCTAssertEqual(
            status.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            "?? .vscode/",
            "worktrees must stay invisible; the editor settings file is the only new entry"
        )
        let editorSettings = try JSONSerialization.jsonObject(
            with: Data(contentsOf: repository.appendingPathComponent(".vscode/settings.json"))
        ) as? [String: Any]
        XCTAssertEqual(editorSettings?["git.repositoryScanMaxDepth"] as? Int, 3)

        // The rule must not be duplicated by the next agent.
        let second0 = try await manager.createWorktree(
            for: repository,
            sessionID: UUID(),
            title: "Grace Codex"
        )
        let excludeAfterSecond = try String(
            contentsOf: repository.appendingPathComponent(".git/info/exclude"),
            encoding: .utf8
        )
        XCTAssertEqual(
            excludeAfterSecond.components(separatedBy: "/.foundry/").count,
            2,
            "the exclude line should appear exactly once"
        )
        _ = try await shell.run(
            executableURL: git,
            arguments: ["worktree", "remove", "--force", second0.worktreeURL.path],
            currentDirectoryURL: repository
        )

        // A second agent with the same call sign must not collide.
        let second = try await manager.createWorktree(
            for: repository,
            sessionID: UUID(),
            title: "Ada Claude"
        )
        XCTAssertNotEqual(second.worktreeURL, first.worktreeURL)
        XCTAssertTrue(second.worktreeURL.lastPathComponent.hasPrefix("ada-claude-"))

        _ = try await shell.run(
            executableURL: git,
            arguments: ["worktree", "remove", "--force", first.worktreeURL.path],
            currentDirectoryURL: repository
        )
        _ = try await shell.run(
            executableURL: git,
            arguments: ["worktree", "remove", "--force", second.worktreeURL.path],
            currentDirectoryURL: repository
        )
    }

    func testWorkingFileParsingTracksBothStatusColumns() {
        let files = GitReviewService.parseWorkingFiles(
            """
            M  staged.swift
             M unstaged.swift
            MM partial.swift
            ?? brand-new.swift
            R  old.swift -> renamed.swift
            """
        )
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })

        XCTAssertEqual(byPath["staged.swift"]?.isFullyStaged, true)
        XCTAssertEqual(byPath["unstaged.swift"]?.hasStagedChanges, false)
        XCTAssertEqual(byPath["unstaged.swift"]?.hasUnstagedChanges, true)
        // Partially staged files must read as both, or the checkbox lies.
        XCTAssertEqual(byPath["partial.swift"]?.hasStagedChanges, true)
        XCTAssertEqual(byPath["partial.swift"]?.hasUnstagedChanges, true)
        XCTAssertEqual(byPath["partial.swift"]?.isFullyStaged, false)
        XCTAssertEqual(byPath["brand-new.swift"]?.isUntracked, true)
        XCTAssertEqual(byPath["brand-new.swift"]?.statusLabel, "untracked")
        XCTAssertEqual(byPath["renamed.swift"]?.statusLabel, "renamed")
    }

    func testCommitMessageComposerDescribesTheStagedSet() {
        func file(_ index: Character, _ tree: Character, _ path: String) -> GitWorkingFile {
            GitWorkingFile(indexStatus: index, worktreeStatus: tree, path: path)
        }

        XCTAssertEqual(CommitMessageComposer.compose(for: []), "")
        XCTAssertEqual(
            CommitMessageComposer.compose(for: [file("M", " ", "app/page.tsx")]),
            "Update page.tsx"
        )
        XCTAssertEqual(
            CommitMessageComposer.compose(for: [file("?", "?", "app/new.tsx")]),
            "Add new.tsx"
        )

        let multi = CommitMessageComposer.compose(for: [
            file("M", " ", "app/page.tsx"),
            file("M", " ", "app/layout.tsx"),
            file("M", " ", "lib/util.ts")
        ])
        XCTAssertTrue(multi.hasPrefix("Update app and lib (3 files)"), multi)
        XCTAssertTrue(multi.contains("- modified: app/page.tsx"))
        XCTAssertTrue(multi.contains("- modified: lib/util.ts"))

        let mixed = CommitMessageComposer.compose(for: [
            file("A", " ", "Tests/NewTests.swift"),
            file("M", " ", "Sources/Thing.swift")
        ])
        XCTAssertTrue(mixed.hasPrefix("Update Sources and Tests (2 files)"), mixed)
    }

    func testStageCommitRoundTripOnARealWorktree() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryCommit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repository = scratch.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let shell = ShellRunner()
        let git = URL(fileURLWithPath: "/usr/bin/git")
        for arguments in [
            ["init", "-b", "main"],
            [
                "-c", "user.name=Canvas Foundry Tests",
                "-c", "user.email=tests@canvas.invalid",
                "commit", "--allow-empty", "-m", "Initial commit"
            ]
        ] {
            let result = try await shell.run(
                executableURL: git,
                arguments: arguments,
                currentDirectoryURL: repository
            )
            XCTAssertEqual(result.exitCode, 0, result.standardError)
        }

        let manager = GitWorktreeManager(
            storageRoot: scratch.appendingPathComponent("worktrees", isDirectory: true)
        )
        let descriptor = try await manager.createWorktree(
            for: repository,
            sessionID: UUID(),
            title: "Ada Claude"
        )

        // Agent leaves uncommitted work behind, like the real review scenario.
        try Data("let feature = true\n".utf8).write(
            to: descriptor.worktreeURL.appendingPathComponent("feature.swift")
        )
        try Data("let extra = 1\n".utf8).write(
            to: descriptor.worktreeURL.appendingPathComponent("extra.swift")
        )

        let service = GitReviewService()
        var snapshot = try await service.inspect(descriptor)
        XCTAssertEqual(snapshot.workingFiles.count, 2)
        XCTAssertTrue(snapshot.commits.isEmpty)
        XCTAssertTrue(snapshot.workingFiles.allSatisfy(\.isUntracked))

        // Untracked files still show reviewable content in the focused diff.
        let untrackedDiff = try await service.fileDiff(
            descriptor,
            baseRevision: snapshot.baseRevision,
            file: snapshot.workingFiles[0]
        )
        XCTAssertTrue(untrackedDiff.contains("+let extra = 1"), untrackedDiff)

        // Stage one file, commit it, and the review must show one commit and
        // one remaining working file.
        try await service.stage(["feature.swift"], in: descriptor)
        snapshot = try await service.inspect(descriptor)
        XCTAssertEqual(
            snapshot.workingFiles.first { $0.path == "feature.swift" }?.isFullyStaged,
            true
        )

        let message = CommitMessageComposer.compose(
            for: snapshot.workingFiles.filter(\.hasStagedChanges)
        )
        XCTAssertEqual(message, "Add feature.swift")
        try await service.commit(message: message, in: descriptor)

        snapshot = try await service.inspect(descriptor)
        XCTAssertEqual(snapshot.commits.map(\.subject), ["Add feature.swift"])
        XCTAssertEqual(snapshot.workingFiles.map(\.path), ["extra.swift"])

        // Unstage must round-trip too.
        try await service.stage(["extra.swift"], in: descriptor)
        try await service.unstage(["extra.swift"], in: descriptor)
        snapshot = try await service.inspect(descriptor)
        XCTAssertEqual(snapshot.workingFiles.first?.hasStagedChanges, false)

        _ = try await shell.run(
            executableURL: git,
            arguments: ["worktree", "remove", "--force", descriptor.worktreeURL.path],
            currentDirectoryURL: repository
        )
    }

    @MainActor
    func testMergedPullRequestCleansUpAgentUnlessWorktreeIsDirty() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryMergeClean-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let repository = scratch.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let shell = ShellRunner()
        let git = URL(fileURLWithPath: "/usr/bin/git")
        for arguments in [
            ["init", "-b", "main"],
            [
                "-c", "user.name=Canvas Foundry Tests",
                "-c", "user.email=tests@canvas.invalid",
                "commit", "--allow-empty", "-m", "Initial commit"
            ]
        ] {
            _ = try await shell.run(
                executableURL: git,
                arguments: arguments,
                currentDirectoryURL: repository
            )
        }

        let manager = GitWorktreeManager(
            storageRoot: scratch.appendingPathComponent("worktrees", isDirectory: true)
        )
        let model = WorkspaceModel(
            worktreeManager: manager,
            persistence: WorkspacePersistence(
                fileURL: scratch.appendingPathComponent("workspace.json")
            )
        )

        func mergedPR(_ number: Int) -> AgentPullRequest {
            AgentPullRequest(
                number: number,
                url: URL(string: "https://github.com/example/project/pull/\(number)")!,
                state: .merged,
                isDraft: false,
                headBranch: "canvas/test",
                baseBranch: "main",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                title: "Test",
                mergeability: .mergeable,
                mergeStateStatus: "CLEAN",
                checksStatus: .passed,
                reviewDecision: .approved,
                headCommitOID: "abc123",
                changedFiles: 1,
                additions: 1,
                deletions: 0,
                checks: []
            )
        }

        // Clean worktree: cleanup removes the worktree and archives the agent.
        let cleanDescriptor = try await manager.createWorktree(
            for: repository, sessionID: UUID(), title: "Ada Claude"
        )
        let cleanSession = AgentSession(provider: .claude, name: "Ada", position: .zero)
        cleanSession.worktree = cleanDescriptor
        cleanSession.pullRequest = mergedPR(7)
        model.sessions.append(cleanSession)

        await model.cleanUpMergedSession(cleanSession)
        XCTAssertTrue(cleanSession.isArchived)
        XCTAssertEqual(cleanSession.status, .completed)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cleanDescriptor.worktreeURL.path),
            "a clean worktree should be deleted once its PR is merged"
        )

        // Dirty worktree: preserved, agent flagged, nothing destroyed.
        let dirtyDescriptor = try await manager.createWorktree(
            for: repository, sessionID: UUID(), title: "Grace Codex"
        )
        try Data("half-finished\n".utf8).write(
            to: dirtyDescriptor.worktreeURL.appendingPathComponent("leftover.txt")
        )
        let dirtySession = AgentSession(provider: .codex, name: "Grace", position: .zero)
        dirtySession.worktree = dirtyDescriptor
        dirtySession.pullRequest = mergedPR(8)
        model.sessions.append(dirtySession)

        await model.cleanUpMergedSession(dirtySession)
        XCTAssertFalse(dirtySession.isArchived)
        XCTAssertEqual(dirtySession.status, .needsYou("PR merged; uncommitted work remains"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: dirtyDescriptor.worktreeURL.appendingPathComponent("leftover.txt").path
            ),
            "uncommitted work must never be destroyed silently"
        )

        // An open PR must never trigger cleanup.
        let openSession = AgentSession(provider: .claude, name: "Alan", position: .zero)
        openSession.worktree = dirtyDescriptor
        openSession.pullRequest = {
            let pullRequest = mergedPR(9)
            return AgentPullRequest(
                number: pullRequest.number, url: pullRequest.url, state: .open,
                isDraft: true, headBranch: pullRequest.headBranch,
                baseBranch: pullRequest.baseBranch, updatedAt: pullRequest.updatedAt,
                title: pullRequest.title, mergeability: pullRequest.mergeability,
                mergeStateStatus: pullRequest.mergeStateStatus,
                checksStatus: pullRequest.checksStatus,
                reviewDecision: pullRequest.reviewDecision,
                headCommitOID: pullRequest.headCommitOID,
                changedFiles: pullRequest.changedFiles,
                additions: pullRequest.additions,
                deletions: pullRequest.deletions, checks: pullRequest.checks
            )
        }()
        await model.cleanUpMergedSession(openSession)
        XCTAssertFalse(openSession.isArchived, "open PRs are still in progress")

        _ = try await shell.run(
            executableURL: git,
            arguments: ["worktree", "remove", "--force", dirtyDescriptor.worktreeURL.path],
            currentDirectoryURL: repository
        )
    }

    func testEditorSettingsGainScanDepthWithoutClobberingExistingConfig() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryVSCode-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let settingsURL = scratch.appendingPathComponent(".vscode/settings.json")

        // Created from nothing.
        XCTAssertTrue(try EditorSettingsWriter.ensureRepositoryScanDepth(projectRoot: scratch))
        var settings = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settingsURL)
        ) as? [String: Any]
        XCTAssertEqual(settings?["git.repositoryScanMaxDepth"] as? Int, 3)

        // Merged into existing config without losing other keys.
        try Data(
            """
            {"editor.formatOnSave": true, "git.repositoryScanMaxDepth": 1}
            """.utf8
        ).write(to: settingsURL)
        XCTAssertTrue(try EditorSettingsWriter.ensureRepositoryScanDepth(projectRoot: scratch))
        settings = try JSONSerialization.jsonObject(
            with: Data(contentsOf: settingsURL)
        ) as? [String: Any]
        XCTAssertEqual(settings?["git.repositoryScanMaxDepth"] as? Int, 3)
        XCTAssertEqual(settings?["editor.formatOnSave"] as? Bool, true)

        // A deeper or unlimited configuration is never lowered.
        try Data(#"{"git.repositoryScanMaxDepth": -1}"#.utf8).write(to: settingsURL)
        XCTAssertFalse(try EditorSettingsWriter.ensureRepositoryScanDepth(projectRoot: scratch))
        try Data(#"{"git.repositoryScanMaxDepth": 5}"#.utf8).write(to: settingsURL)
        XCTAssertFalse(try EditorSettingsWriter.ensureRepositoryScanDepth(projectRoot: scratch))

        // JSONC that JSONSerialization cannot parse is left byte-for-byte alone.
        let jsonc = "{\n  // hand-written comment\n  \"editor.formatOnSave\": true,\n}"
        try Data(jsonc.utf8).write(to: settingsURL)
        XCTAssertFalse(try EditorSettingsWriter.ensureRepositoryScanDepth(projectRoot: scratch))
        XCTAssertEqual(try String(contentsOf: settingsURL, encoding: .utf8), jsonc)
    }

    func testIsInsideComparesPathComponentsNotStringPrefixes() {
        let parent = URL(fileURLWithPath: "/tmp/acme-app", isDirectory: true)

        XCTAssertTrue(
            IDEProjectOpener.isInside(
                URL(fileURLWithPath: "/tmp/acme-app/.foundry/worktrees/ada-claude"),
                of: parent
            )
        )
        // The classic prefix bug: a sibling that merely shares the name prefix.
        XCTAssertFalse(
            IDEProjectOpener.isInside(
                URL(fileURLWithPath: "/tmp/acme-app2/worktree"),
                of: parent
            )
        )
        // A folder is not inside itself.
        XCTAssertFalse(IDEProjectOpener.isInside(parent, of: parent))
        // Trailing slashes and `..` segments must not confuse the comparison.
        XCTAssertTrue(
            IDEProjectOpener.isInside(
                URL(fileURLWithPath: "/tmp/acme-app/sub/../.foundry"),
                of: URL(fileURLWithPath: "/tmp/acme-app/")
            )
        )
    }

    func testAgentIDEWorkspacePairsProjectWithBranchWithoutClobbering() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryWS-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let storage = scratch.appendingPathComponent("workspaces", isDirectory: true)
        let project = scratch.appendingPathComponent("acme-app", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        // Two agents on the same repository must get two distinct workspace
        // files, or opening one editor window would rewrite the other's roots.
        let adaURL = try IDEProjectOpener.makeMultiRootWorkspace(
            projectURL: project,
            folders: [.init(name: "Main", url: project)],
            variant: "ada12345",
            storageRoot: storage
        )
        let graceURL = try IDEProjectOpener.makeMultiRootWorkspace(
            projectURL: project,
            folders: [.init(name: "Main", url: project)],
            variant: "grace678",
            storageRoot: storage
        )
        XCTAssertNotEqual(adaURL, graceURL)

        // And the fleet-wide workspace (no variant) keeps its own file.
        let fleetURL = try IDEProjectOpener.makeMultiRootWorkspace(
            projectURL: project,
            folders: [.init(name: "Main", url: project)],
            storageRoot: storage
        )
        XCTAssertNotEqual(fleetURL, adaURL)
        XCTAssertNotEqual(fleetURL, graceURL)
    }

    func testCreatesARealIsolatedGitWorktree() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repository = scratch.appendingPathComponent("project", isDirectory: true)
        let worktreeStorage = scratch.appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

        let shell = ShellRunner()
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let initResult = try await shell.run(
            executableURL: git,
            arguments: ["init", "-b", "main"],
            currentDirectoryURL: repository
        )
        XCTAssertEqual(initResult.exitCode, 0)

        let commitResult = try await shell.run(
            executableURL: git,
            arguments: [
                "-c", "user.name=Canvas Foundry Tests",
                "-c", "user.email=tests@canvas.invalid",
                "commit", "--allow-empty", "-m", "Initial commit"
            ],
            currentDirectoryURL: repository
        )
        XCTAssertEqual(commitResult.exitCode, 0, commitResult.standardError)

        let manager = GitWorktreeManager(storageRoot: worktreeStorage)
        let descriptor = try await manager.createWorktree(
            for: repository,
            sessionID: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!,
            title: "Implement settings"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: descriptor.worktreeURL.path))
        XCTAssertEqual(descriptor.branchName, "canvas/implement-settings-12345678")
        XCTAssertNotNil(descriptor.baseRevision)

        let branchResult = try await shell.run(
            executableURL: git,
            arguments: ["branch", "--show-current"],
            currentDirectoryURL: descriptor.worktreeURL
        )
        XCTAssertEqual(
            branchResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            descriptor.branchName
        )
    }

    func testGitReviewMergeAndGuardedWorktreeRemoval() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryReview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let repository = scratch.appendingPathComponent("project", isDirectory: true)
        let worktreeStorage = scratch.appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

        let shell = ShellRunner()
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let initResult = try await shell.run(
            executableURL: git,
            arguments: ["init", "-b", "main"],
            currentDirectoryURL: repository
        )
        XCTAssertEqual(initResult.exitCode, 0)
        let initialCommit = try await shell.run(
            executableURL: git,
            arguments: [
                "-c", "user.name=Canvas Foundry Tests",
                "-c", "user.email=tests@canvas.invalid",
                "commit", "--allow-empty", "-m", "Initial commit"
            ],
            currentDirectoryURL: repository
        )
        XCTAssertEqual(initialCommit.exitCode, 0, initialCommit.standardError)

        let manager = GitWorktreeManager(storageRoot: worktreeStorage)
        let descriptor = try await manager.createWorktree(
            for: repository,
            sessionID: UUID(),
            title: "Grace Codex"
        )

        try Data("reviewed feature\n".utf8).write(
            to: descriptor.worktreeURL.appendingPathComponent("feature.txt")
        )
        let featureCommit = try await shell.run(
            executableURL: git,
            arguments: [
                "add", "feature.txt"
            ],
            currentDirectoryURL: descriptor.worktreeURL
        )
        XCTAssertEqual(featureCommit.exitCode, 0, featureCommit.standardError)
        let commitResult = try await shell.run(
            executableURL: git,
            arguments: [
                "-c", "user.name=Grace",
                "-c", "user.email=grace@canvas.invalid",
                "commit", "-m", "Add reviewed feature"
            ],
            currentDirectoryURL: descriptor.worktreeURL
        )
        XCTAssertEqual(commitResult.exitCode, 0, commitResult.standardError)
        try Data("uncommitted note\n".utf8).write(
            to: descriptor.worktreeURL.appendingPathComponent("notes.txt")
        )

        let reviewService = GitReviewService()
        let review = try await reviewService.inspect(descriptor)
        XCTAssertEqual(Set(review.files.map(\.path)), ["feature.txt", "notes.txt"])
        XCTAssertEqual(review.commits.count, 1)
        XCTAssertEqual(review.commits.first?.subject, "Add reviewed feature")
        XCTAssertTrue(review.diff.contains("reviewed feature"))
        XCTAssertTrue(review.diff.contains("notes.txt"))

        let summary = try await reviewService.summary(descriptor)
        XCTAssertEqual(summary.changedFileCount, 2)
        XCTAssertEqual(summary.commitCount, 1)

        try await reviewService.mergeAgentBranch(descriptor)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: repository.appendingPathComponent("feature.txt").path
            )
        )

        let hasUncommittedChanges = try await manager.hasUncommittedChanges(descriptor)
        XCTAssertTrue(hasUncommittedChanges)
        do {
            try await manager.removeWorktree(descriptor, force: false)
            XCTFail("A dirty worktree must not be removed without force")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: descriptor.worktreeURL.path))
        }

        try await manager.removeWorktree(descriptor, force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.worktreeURL.path))
        let branchResult = try await shell.run(
            executableURL: git,
            arguments: ["show-ref", "--verify", "refs/heads/\(descriptor.branchName)"],
            currentDirectoryURL: repository
        )
        XCTAssertEqual(branchResult.exitCode, 0, "Removing a worktree must preserve its branch")
    }

    func testDraftPullRequestWorkflowPushesAndCreatesPR() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryPR-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let project = scratch.appendingPathComponent("project", isDirectory: true)
        let worktree = scratch.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        let pullRequestState = scratch.appendingPathComponent("pr-created")
        let gitLog = scratch.appendingPathComponent("git.log")
        let ghLog = scratch.appendingPathComponent("gh.log")
        let fakeGit = scratch.appendingPathComponent("git")
        let fakeGitHub = scratch.appendingPathComponent("gh")

        let gitScript = """
        #!/bin/sh
        printf '%s\n' "$*" >> "\(gitLog.path)"
        if [ "$1" = "remote" ]; then
          echo 'git@github.com:example/project.git'
        elif [ "$1" = "rev-list" ]; then
          echo '2'
        elif [ "$1" = "status" ]; then
          echo ' M Sources/Feature.swift'
        elif [ "$1" = "log" ]; then
          echo 'Add agent feature'
        fi
        exit 0
        """
        let ghScript = """
        #!/bin/sh
        printf '%s\n' "$*" >> "\(ghLog.path)"
        if [ "$1" = "auth" ]; then
          exit 0
        elif [ "$1" = "repo" ]; then
          echo '{"defaultBranchRef":{"name":"main"}}'
          exit 0
        elif [ "$1" = "pr" ] && [ "$2" = "view" ]; then
          if [ -f "\(pullRequestState.path)" ]; then
            echo '{"number":17,"url":"https://github.com/example/project/pull/17","state":"OPEN","isDraft":true,"headRefName":"canvas/ada-claude-12345678","baseRefName":"main"}'
            exit 0
          fi
          exit 1
        elif [ "$1" = "pr" ] && [ "$2" = "create" ]; then
          touch "\(pullRequestState.path)"
          echo 'https://github.com/example/project/pull/17'
          exit 0
        fi
        exit 1
        """
        try Data(gitScript.utf8).write(to: fakeGit)
        try Data(ghScript.utf8).write(to: fakeGitHub)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGit.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGitHub.path
        )

        let descriptor = WorktreeDescriptor(
            projectRoot: project,
            worktreeURL: worktree,
            branchName: "canvas/ada-claude-12345678",
            baseRevision: "abc123"
        )
        let service = GitHubPullRequestService(gitURL: fakeGit, ghURL: fakeGitHub)
        let preflight = try await service.preflight(descriptor)
        XCTAssertEqual(preflight.commitCount, 2)
        XCTAssertEqual(preflight.baseBranch, "main")
        XCTAssertEqual(preflight.suggestedTitle, "Add agent feature")
        XCTAssertTrue(preflight.hasUncommittedChanges)
        XCTAssertNil(preflight.existingPullRequest)

        let pullRequest = try await service.publishDraft(
            descriptor,
            agentName: "Ada",
            testStatus: .passed
        )
        XCTAssertEqual(pullRequest.number, 17)
        XCTAssertEqual(pullRequest.state, .open)
        XCTAssertTrue(pullRequest.isDraft)
        XCTAssertEqual(pullRequest.baseBranch, "main")

        let recordedGitCommands = try String(contentsOf: gitLog, encoding: .utf8)
        XCTAssertTrue(
            recordedGitCommands.contains(
                "push --set-upstream origin canvas/ada-claude-12345678"
            )
        )
        let recordedGitHubCommands = try String(contentsOf: ghLog, encoding: .utf8)
        XCTAssertTrue(recordedGitHubCommands.contains("pr create --draft"))
        XCTAssertTrue(recordedGitHubCommands.contains("--base main"))
        XCTAssertTrue(recordedGitHubCommands.contains("--title Add agent feature"))
    }

    func testPullRequestWorkflowExplainsMissingGitHubCLI() async throws {
        let scratch = FileManager.default.temporaryDirectory
        let descriptor = WorktreeDescriptor(
            projectRoot: scratch,
            worktreeURL: scratch,
            branchName: "canvas/test",
            baseRevision: "abc123"
        )
        let service = GitHubPullRequestService(ghURL: nil)

        do {
            _ = try await service.preflight(descriptor)
            XCTFail("Expected a missing GitHub CLI error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("brew install gh"))
            XCTAssertTrue(error.localizedDescription.contains("gh auth login"))
        }
    }

    func testReviewQueueReadySyncAndSquashMergeWorkflow() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryMergeQueue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let project = scratch.appendingPathComponent("project", isDirectory: true)
        let worktree = scratch.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

        let draftMarker = scratch.appendingPathComponent("draft")
        let mergedMarker = scratch.appendingPathComponent("merged")
        let gitLog = scratch.appendingPathComponent("git.log")
        let ghLog = scratch.appendingPathComponent("gh.log")
        let fakeGit = scratch.appendingPathComponent("git")
        let fakeGitHub = scratch.appendingPathComponent("gh")
        try Data().write(to: draftMarker)

        let gitScript = """
        #!/bin/sh
        printf '%s\n' "$*" >> "\(gitLog.path)"
        if [ "$1" = "remote" ]; then
          echo 'git@github.com:example/project.git'
        fi
        exit 0
        """
        let ghScript = """
        #!/bin/sh
        printf '%s\n' "$*" >> "\(ghLog.path)"
        if [ "$1" = "auth" ]; then
          exit 0
        elif [ "$1" = "repo" ]; then
          echo '{"defaultBranchRef":{"name":"main"}}'
          exit 0
        elif [ "$1" = "pr" ] && [ "$2" = "checks" ]; then
          echo '[{"name":"tests","workflow":"CI","state":"SUCCESS","bucket":"pass","link":"https://github.com/example/project/actions/1"}]'
          exit 0
        elif [ "$1" = "pr" ] && [ "$2" = "view" ]; then
          if [ -f "\(mergedMarker.path)" ]; then
            echo '{"number":31,"url":"https://github.com/example/project/pull/31","state":"MERGED","isDraft":false,"headRefName":"canvas/grace-codex-12345678","baseRefName":"main","title":"Ship the queue","mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","reviewDecision":"","headRefOid":"abc123","changedFiles":4,"additions":80,"deletions":12}'
          elif [ -f "\(draftMarker.path)" ]; then
            echo '{"number":31,"url":"https://github.com/example/project/pull/31","state":"OPEN","isDraft":true,"headRefName":"canvas/grace-codex-12345678","baseRefName":"main","title":"Ship the queue","mergeable":"MERGEABLE","mergeStateStatus":"DRAFT","reviewDecision":"","headRefOid":"abc123","changedFiles":4,"additions":80,"deletions":12}'
          else
            echo '{"number":31,"url":"https://github.com/example/project/pull/31","state":"OPEN","isDraft":false,"headRefName":"canvas/grace-codex-12345678","baseRefName":"main","title":"Ship the queue","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"","headRefOid":"abc123","changedFiles":4,"additions":80,"deletions":12}'
          fi
          exit 0
        elif [ "$1" = "pr" ] && [ "$2" = "ready" ]; then
          rm "\(draftMarker.path)"
          exit 0
        elif [ "$1" = "pr" ] && [ "$2" = "update-branch" ]; then
          exit 0
        elif [ "$1" = "pr" ] && [ "$2" = "merge" ]; then
          touch "\(mergedMarker.path)"
          exit 0
        fi
        exit 1
        """
        try Data(gitScript.utf8).write(to: fakeGit)
        try Data(ghScript.utf8).write(to: fakeGitHub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGit.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGitHub.path)

        let descriptor = WorktreeDescriptor(
            projectRoot: project,
            worktreeURL: worktree,
            branchName: "canvas/grace-codex-12345678",
            baseRevision: "base123"
        )
        let service = GitHubPullRequestService(gitURL: fakeGit, ghURL: fakeGitHub)

        let draft = try await service.refresh(descriptor)
        XCTAssertEqual(draft.queueState, .draft)
        XCTAssertEqual(draft.checksStatus, .passed)
        XCTAssertEqual(draft.changedFiles, 4)

        let ready = try await service.markReady(descriptor)
        XCTAssertEqual(ready.queueState, .readyToMerge)
        XCTAssertEqual(ready.headCommitOID, "abc123")

        let synced = try await service.syncWithBase(descriptor)
        XCTAssertEqual(synced.queueState, .readyToMerge)

        let merged = try await service.squashMerge(descriptor)
        XCTAssertEqual(merged.state, .merged)
        XCTAssertEqual(merged.queueState, .merged)

        let recordedGitCommands = try String(contentsOf: gitLog, encoding: .utf8)
        XCTAssertTrue(recordedGitCommands.contains("push --set-upstream origin canvas/grace-codex-12345678"))
        XCTAssertTrue(recordedGitCommands.contains("fetch origin canvas/grace-codex-12345678"))
        XCTAssertTrue(recordedGitCommands.contains("merge --ff-only FETCH_HEAD"))

        let recordedGitHubCommands = try String(contentsOf: ghLog, encoding: .utf8)
        XCTAssertTrue(recordedGitHubCommands.contains("pr ready 31"))
        XCTAssertTrue(recordedGitHubCommands.contains("pr update-branch 31"))
        XCTAssertTrue(recordedGitHubCommands.contains("pr merge 31 --squash --match-head-commit abc123"))
    }

    func testReviewQueueStatePrioritizesConflictsChecksAndReviews() {
        func pullRequest(
            draft: Bool = false,
            mergeability: PullRequestMergeability = .mergeable,
            mergeState: String = "CLEAN",
            checks: PullRequestChecksStatus = .passed,
            review: PullRequestReviewDecision = .none
        ) -> AgentPullRequest {
            AgentPullRequest(
                number: 1,
                url: URL(string: "https://github.com/example/project/pull/1")!,
                state: .open,
                isDraft: draft,
                headBranch: "canvas/test",
                baseBranch: "main",
                updatedAt: Date(),
                mergeability: mergeability,
                mergeStateStatus: mergeState,
                checksStatus: checks,
                reviewDecision: review,
                headCommitOID: "abc123"
            )
        }

        XCTAssertEqual(pullRequest(draft: true).queueState, .draft)
        XCTAssertEqual(
            pullRequest(mergeability: .conflicting, mergeState: "DIRTY").queueState,
            .conflict
        )
        XCTAssertEqual(pullRequest(checks: .failed).queueState, .checksFailed)
        XCTAssertEqual(pullRequest(checks: .pending).queueState, .checksPending)
        XCTAssertEqual(
            pullRequest(review: .changesRequested).queueState,
            .changesRequested
        )
        XCTAssertEqual(pullRequest(review: .reviewRequired).queueState, .reviewRequired)
        XCTAssertEqual(pullRequest(mergeState: "BEHIND").queueState, .behind)
        XCTAssertEqual(pullRequest().queueState, .readyToMerge)
    }

    func testEmptyFolderCanBeInitializedForAgentWorktrees() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryBootstrap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let manager = GitProjectManager()
        let inspection = try await manager.inspect(scratch)
        guard case .needsBootstrap(let request) = inspection else {
            return XCTFail("Expected an empty folder to offer local Git initialization")
        }
        XCTAssertTrue(request.shouldInitializeGit)

        let repositoryRoot = try await manager.bootstrap(request)
        XCTAssertEqual(repositoryRoot.standardizedFileURL, scratch.standardizedFileURL)

        let readyInspection = try await manager.inspect(scratch)
        XCTAssertEqual(readyInspection, .ready(repositoryRoot))

        let headResult = try await ShellRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["rev-parse", "--verify", "HEAD"],
            currentDirectoryURL: scratch
        )
        XCTAssertEqual(headResult.exitCode, 0)
    }

    func testNonGitFolderWithFilesRequiresConsentThenCommitsThem() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryNonGit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("existing work".utf8).write(
            to: scratch.appendingPathComponent("notes.txt")
        )

        // Still never silent: inspect only *offers* initialization — the
        // consent alert stands between this and any git command running.
        let manager = GitProjectManager()
        let inspection = try await manager.inspect(scratch)
        guard case .needsBootstrap(let request) = inspection else {
            return XCTFail("Expected a folder with files to offer initialization")
        }
        XCTAssertTrue(request.shouldInitializeGit)
        XCTAssertTrue(
            request.hasExistingFiles,
            "the consent copy must warn that existing files will be committed"
        )

        // After consent, existing files must land in the initial commit —
        // agent worktrees branch from it and would otherwise be empty.
        let root = try await manager.bootstrap(request)
        let shell = ShellRunner()
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let tracked = try await shell.run(
            executableURL: git,
            arguments: ["ls-files"],
            currentDirectoryURL: root
        )
        XCTAssertTrue(tracked.standardOutput.contains("notes.txt"))
        let status = try await shell.run(
            executableURL: git,
            arguments: ["status", "--porcelain=v1"],
            currentDirectoryURL: root
        )
        XCTAssertEqual(status.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "")
        let readyInspection = try await manager.inspect(scratch)
        XCTAssertEqual(readyInspection, .ready(root))
    }

    func testDotfileOnlyFolderIsInitializableAndCommitsTheDotfile() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryDotfile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("node_modules/\n".utf8).write(
            to: scratch.appendingPathComponent(".gitignore")
        )

        let manager = GitProjectManager()
        guard case .needsBootstrap(let request) = try await manager.inspect(scratch) else {
            return XCTFail("A dotfile-only folder should be initializable")
        }
        XCTAssertTrue(request.hasExistingFiles)

        let root = try await manager.bootstrap(request)
        let tracked = try await ShellRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["ls-files"],
            currentDirectoryURL: root
        )
        XCTAssertTrue(tracked.standardOutput.contains(".gitignore"))
    }

    func testCreateProjectFromScratchIsImmediatelyReadyForAgents() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasFoundryNewProj-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let projectURL = scratch.appendingPathComponent("Fresh Idea", isDirectory: true)

        let manager = GitProjectManager()
        let root = try await manager.createProject(at: projectURL)
        XCTAssertEqual(root.standardizedFileURL.lastPathComponent, "Fresh Idea")
        let readyInspection = try await manager.inspect(projectURL)
        XCTAssertEqual(readyInspection, .ready(root))

        // The point of the whole flow: an agent can start immediately.
        let worktreeManager = GitWorktreeManager(
            storageRoot: scratch.appendingPathComponent("worktrees", isDirectory: true)
        )
        let descriptor = try await worktreeManager.createWorktree(
            for: root,
            sessionID: UUID(),
            title: "Ada Claude"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: descriptor.worktreeURL.path))
        _ = try await ShellRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["worktree", "remove", "--force", descriptor.worktreeURL.path],
            currentDirectoryURL: root
        )
    }

    @MainActor
    func testNativeCardDragMovesHostedLayerWithoutMovingLayoutContainer() {
        let host = NativeTerminalCardHost(rootView: Color.clear)
        host.frame = CGRect(x: 0, y: 0, width: 520, height: 360)
        host.layoutSubtreeIfNeeded()

        host.applyMove(CGSize(width: 80, height: 45))

        XCTAssertEqual(host.frame.origin, .zero)
        XCTAssertEqual(host.hostingView.frame.origin, CGPoint(x: 80, y: -45))
        XCTAssertEqual(host.hostingView.frame.size, CGSize(width: 520, height: 360))
    }

    @MainActor
    func testAgentDeliveryStateProvidesOneLinearShippingLifecycle() {
        let session = AgentSession(
            provider: .codex,
            name: "Ada",
            position: .zero
        )

        session.status = .working
        XCTAssertEqual(session.deliveryState, .working)

        session.gitSummary = AgentGitSummary(changedFileCount: 3)
        XCTAssertEqual(session.deliveryState, .working)
        XCTAssertTrue(session.canReviewAndShip)

        session.status = .stopped
        XCTAssertEqual(session.deliveryState, .changesReady)

        session.gitSummary = AgentGitSummary(commitCount: 1)
        XCTAssertEqual(session.deliveryState, .readyToPublish)

        session.pullRequest = AgentPullRequest(
            number: 12,
            url: URL(string: "https://github.com/example/project/pull/12")!,
            state: .open,
            isDraft: true,
            headBranch: "canvas/ada",
            baseBranch: "main",
            updatedAt: Date()
        )
        XCTAssertEqual(session.deliveryState, .draftPullRequest)

        session.pullRequest = AgentPullRequest(
            number: 12,
            url: URL(string: "https://github.com/example/project/pull/12")!,
            state: .open,
            isDraft: false,
            headBranch: "canvas/ada",
            baseBranch: "main",
            updatedAt: Date(),
            mergeability: .mergeable,
            mergeStateStatus: "CLEAN",
            checksStatus: .passed
        )
        XCTAssertEqual(session.deliveryState, .readyToMerge)
    }

    func testLocalPlannerRequestUsesStrictSchemaAndLocalEndpointPayload() throws {
        let planner = LocalActionPlanner(model: "test-model")
        let context = LocalFoundryWorkspaceContext(
            projectName: "Acme",
            selectedAgentID: nil,
            agents: [],
            recentConversation: [
                LocalFoundryConversationTurn(
                    userRequest: "Review the authentication flow",
                    assistantResult: "Which agent should handle it?",
                    referencedAgentNames: [],
                    didExecuteAction: false
                )
            ]
        )

        let data = try planner.makeRequestBody(
            input: "remove Reese",
            context: context
        )
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["think"] as? Bool, false)
        XCTAssertEqual(body["keep_alive"] as? String, LocalActionPlanner.keepAlive)

        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        let function = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "propose_foundry_plan")
        let schema = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let actions = try XCTUnwrap(properties["actions"] as? [String: Any])
        XCTAssertEqual(
            actions["maxItems"] as? Int,
            WorkspaceCommandParser.maximumAgentsPerCommand
        )
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]?.contains("Always call the propose_foundry_plan tool") == true)
        XCTAssertTrue(messages[1]["content"]?.contains("Review the authentication flow") == true)
        XCTAssertTrue(messages[1]["content"]?.contains("Which agent should handle it?") == true)
    }

    func testLocalPlannerContextKeepsOnlyNamedOrSelectedAgentWhenPossible() {
        let reese = LocalFoundryAgentContext(
            id: UUID().uuidString,
            name: "Reese",
            provider: "claude",
            status: "Stopped",
            isRunning: false,
            isArchived: false,
            changedFileCount: 2,
            commitCount: 0,
            pullRequestNumber: nil
        )
        let grace = LocalFoundryAgentContext(
            id: UUID().uuidString,
            name: "Grace Hopper",
            provider: "codex",
            status: "Working",
            isRunning: true,
            isArchived: false,
            changedFileCount: 0,
            commitCount: 0,
            pullRequestNumber: nil
        )
        let agents = [reese, grace]

        XCTAssertEqual(
            LocalFoundryContextFilter.agents(
                for: "Remove Reese",
                selectedAgentID: grace.id,
                from: agents
            ),
            [reese]
        )
        XCTAssertEqual(
            LocalFoundryContextFilter.agents(
                for: "Stop the selected agent",
                selectedAgentID: grace.id,
                from: agents
            ),
            [grace]
        )
        XCTAssertEqual(
            LocalFoundryContextFilter.agents(
                for: "Which agents have changes?",
                selectedAgentID: grace.id,
                from: agents
            ),
            agents,
            "fleet-wide questions must retain the full context"
        )
    }

    func testInstalledLocalModelProducesAValidRemovalPlanWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["FOUNDRY_TEST_LOCAL_MODEL"] == "1" else {
            throw XCTSkip("Set FOUNDRY_TEST_LOCAL_MODEL=1 to exercise the installed Ollama model.")
        }
        let agentHandle = "agent_1"
        let context = LocalFoundryWorkspaceContext(
            projectName: "Acme",
            selectedAgentID: nil,
            agents: [
                LocalFoundryAgentContext(
                    id: agentHandle,
                    name: "Reese",
                    provider: "claude",
                    status: "Stopped",
                    isRunning: false,
                    isArchived: false,
                    changedFileCount: 2,
                    commitCount: 0,
                    pullRequestNumber: nil
                )
            ]
        )

        let planner = LocalActionPlanner(
            model: ProcessInfo.processInfo.environment["FOUNDRY_TEST_LOCAL_MODEL_NAME"]
                ?? LocalActionPlanner.defaultModel
        )
        try await planner.warmUp()
        let plan: LocalFoundryActionPlan
        do {
            let result = try await planner.planWithMetrics(
                input: "Remove Reese",
                context: context
            )
            plan = result.plan
            XCTAssertLessThan(
                result.metrics.loadDuration,
                0.5,
                "a prewarmed model should not pay a meaningful load penalty"
            )
            XCTAssertGreaterThan(result.metrics.promptTokenCount, 0)
            XCTAssertLessThan(
                result.metrics.generatedTokenCount,
                100,
                "action plans should stay compact so speech can start quickly"
            )
        } catch {
            var request = URLRequest(url: planner.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try planner.makeRequestBody(input: "Remove Reese", context: context)
            let (data, _) = try await URLSession.shared.data(for: request)
            XCTFail("Raw Ollama response: \(String(decoding: data, as: UTF8.self))")
            throw error
        }
        XCTAssertEqual(plan.actions.count, 1)
        XCTAssertEqual(plan.actions[0].type, .prepareRemoveAgent)
        XCTAssertEqual(plan.actions[0].agentID, agentHandle)

        let runningHandle = "agent_2"
        let lifecycleContext = LocalFoundryWorkspaceContext(
            projectName: "Acme",
            selectedAgentID: nil,
            agents: context.agents + [
                LocalFoundryAgentContext(
                    id: runningHandle,
                    name: "Grace",
                    provider: "codex",
                    status: "Working",
                    isRunning: true,
                    isArchived: false,
                    changedFileCount: 0,
                    commitCount: 0,
                    pullRequestNumber: nil
                )
            ]
        )
        let stopPlan = try await planner.plan(
            input: "Stop the agent that is currently running",
            context: lifecycleContext
        )
        XCTAssertEqual(stopPlan.actions.count, 1)
        XCTAssertEqual(stopPlan.actions[0].type, .stopAgent)
        XCTAssertEqual(stopPlan.actions[0].agentID, runningHandle)

        let followUpContext = LocalFoundryWorkspaceContext(
            projectName: "Acme",
            selectedAgentID: nil,
            agents: context.agents,
            recentConversation: [
                LocalFoundryConversationTurn(
                    userRequest: "Review the authentication flow and fix the refresh race",
                    assistantResult: "Which agent should handle it?",
                    referencedAgentNames: [],
                    didExecuteAction: false
                )
            ]
        )
        let followUpPlan = try await planner.plan(
            input: "Send it to Reese",
            context: followUpContext
        )
        XCTAssertEqual(followUpPlan.actions.count, 1)
        XCTAssertEqual(followUpPlan.actions[0].type, .sendPrompt)
        XCTAssertEqual(followUpPlan.actions[0].agentID, agentHandle)
        XCTAssertTrue(followUpPlan.actions[0].prompt?.contains("authentication") == true)
    }

    @MainActor
    func testLocalPlannerCanOnlyTargetRealAgentIDsAndRemovalRequiresConfirmation() {
        let persistence = WorkspacePersistence(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("FoundryLocalPlanner-\(UUID().uuidString).json")
        )
        let model = WorkspaceModel(persistence: persistence)
        let reese = AgentSession(provider: .claude, name: "Reese", position: .zero)
        reese.status = .stopped
        model.sessions = [reese]

        let invented = model.run(
            LocalFoundryActionPlan(
                response: "I removed Reese.",
                actions: [
                    LocalFoundryAction(
                        type: .prepareRemoveAgent,
                        agentID: UUID().uuidString
                    )
                ]
            )
        )
        XCTAssertFalse(invented.wasHandled)
        XCTAssertTrue(invented.message.isEmpty)
        XCTAssertNil(model.alertState)
        XCTAssertEqual(model.sessions.map(\.id), [reese.id])

        let valid = model.run(
            LocalFoundryActionPlan(
                response: "Removing Reese.",
                actions: [
                    LocalFoundryAction(
                        type: .prepareRemoveAgent,
                        agentID: reese.id.uuidString
                    )
                ]
            )
        )
        XCTAssertTrue(valid.wasHandled)
        XCTAssertEqual(valid.message, "Checking Reese’s workspace before removal.")
        XCTAssertNil(model.alertState, "voice confirmation must stay non-modal")
        XCTAssertEqual(
            model.pendingConversationConfirmation?.prompt,
            "Remove Reese and its isolated workspace?"
        )
        XCTAssertEqual(model.sessions.map(\.id), [reese.id])

        let cancelled = model.runConversationControl(.cancel)
        XCTAssertEqual(cancelled.message, "Cancelled. Nothing was changed.")
        XCTAssertNil(model.pendingConversationConfirmation)
        XCTAssertEqual(model.sessions.map(\.id), [reese.id])

        _ = model.run(
            LocalFoundryActionPlan(
                response: "",
                actions: [
                    LocalFoundryAction(
                        type: .prepareRemoveAgent,
                        agentID: reese.id.uuidString
                    )
                ]
            )
        )
        let confirmed = model.runConversationControl(.confirm)
        XCTAssertEqual(confirmed.message, "Removing Reese now.")
        XCTAssertNil(model.pendingConversationConfirmation)
        XCTAssertTrue(model.sessions.isEmpty)
    }

    func testConversationControlParserKeepsDoThatDistinctFromConfirmation() {
        XCTAssertEqual(WorkspaceConversationControlParser.parse("Confirm"), .confirm)
        XCTAssertEqual(WorkspaceConversationControlParser.parse("yes, do it"), .confirm)
        XCTAssertEqual(WorkspaceConversationControlParser.parse("never mind"), .cancel)
        XCTAssertEqual(WorkspaceConversationControlParser.parse("do that"), .doThat)
        XCTAssertNil(WorkspaceConversationControlParser.parse("do that for Reese"))
    }

    @MainActor
    func testConversationHistoryIsShortAndRetainsAgentReferences() {
        let persistence = WorkspacePersistence(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("FoundryConversation-\(UUID().uuidString).json")
        )
        let model = WorkspaceModel(persistence: persistence)
        let reese = AgentSession(provider: .claude, name: "Reese", position: .zero)
        model.sessions = [reese]

        for index in 0..<6 {
            model.rememberConversation(
                userRequest: "request \(index)",
                assistantResult: "result \(index)",
                referencedAgentIDs: [reese.id.uuidString],
                didExecuteAction: index.isMultiple(of: 2)
            )
        }

        XCTAssertEqual(model.recentConversation.count, 4)
        XCTAssertEqual(model.recentConversation.first?.userRequest, "request 2")
        XCTAssertEqual(model.recentConversation.last?.referencedAgentNames, ["Reese"])
    }

    @MainActor
    func testLocalPlannerCanAnswerFromContextWithoutMutatingWorkspace() {
        let persistence = WorkspacePersistence(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("FoundryLocalAnswer-\(UUID().uuidString).json")
        )
        let model = WorkspaceModel(persistence: persistence)
        let result = model.run(
            LocalFoundryActionPlan(
                response: "Two agents are stopped.",
                actions: [LocalFoundryAction(type: .noAction)]
            )
        )

        XCTAssertTrue(result.wasHandled)
        XCTAssertEqual(result.message, "Two agents are stopped.")
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNil(model.alertState)
    }
}
