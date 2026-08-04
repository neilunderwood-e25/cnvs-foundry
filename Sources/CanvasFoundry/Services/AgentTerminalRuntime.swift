import AppKit
import Foundation
import SwiftTerm

final class CanvasTerminalView: LocalProcessTerminalView {
    var onInteraction: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onInteraction?()
        super.rightMouseDown(with: event)
    }
}

enum AgentTerminalError: LocalizedError {
    case executableNotFound(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            "Could not find the \(name) CLI. Install it, authenticate it, and relaunch Canvas Foundry."
        }
    }
}

enum ExecutableResolver {
    static func resolve(_ name: String, in directories: [URL] = defaultDirectories()) -> URL? {
        for directory in directories {
            let candidate = directory.appendingPathComponent(name, isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func defaultDirectories() -> [URL] {
        let environmentPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let knownPaths = [
            home.appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
            URL(fileURLWithPath: "/bin", isDirectory: true)
        ]
        return environmentPaths + knownPaths
    }
}

@MainActor
final class AgentTerminalRuntime: NSObject, LocalProcessTerminalViewDelegate {
    let terminalView: CanvasTerminalView

    private weak var session: AgentSession?
    private var didRequestStop = false
    private var preservesSessionStatusOnStop = false

    init(
        session: AgentSession,
        directory: URL,
        executableOverride: URL? = nil,
        argumentsOverride: [String]? = nil
    ) throws {
        self.session = session
        self.terminalView = CanvasTerminalView(frame: .zero)
        super.init()

        configureTerminal()
        terminalView.processDelegate = self

        let plan = session.provider.launchPlan()
        guard let executableURL = executableOverride ?? ExecutableResolver.resolve(plan.executable) else {
            throw AgentTerminalError.executableNotFound(session.provider.displayName)
        }
        terminalView.startProcess(
            executable: executableURL.path,
            args: argumentsOverride ?? plan.arguments,
            environment: Self.environment(),
            execName: plan.executable,
            currentDirectory: directory.path
        )
        session.status = .working
    }

    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    func stop(preservingSessionStatus: Bool = false) {
        guard session?.status.isActive == true else { return }
        didRequestStop = true
        preservesSessionStatusOnStop = preservingSessionStatus
        if !preservingSessionStatus {
            session?.status = .stopped
        }
        terminalView.terminate()
    }

    nonisolated func sizeChanged(
        source: LocalProcessTerminalView,
        newCols: Int,
        newRows: Int
    ) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { @MainActor [weak self] in
            self?.session?.terminalTitle = trimmed
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(
        source: TerminalView,
        directory: String?
    ) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            guard let self, let session = self.session else { return }
            if self.didRequestStop {
                if !self.preservesSessionStatusOnStop {
                    session.status = .stopped
                }
            } else if exitCode == 0 {
                session.status = .completed
            } else if exitCode == 127 {
                session.status = .failed(
                    "\(session.provider.displayName) was not found. Install it and make sure it is on PATH."
                )
            } else {
                session.status = .failed(
                    "CLI exited with status \(exitCode.map(String.init) ?? "unknown")."
                )
            }
        }
    }

    private func configureTerminal() {
        let background = NSColor(
            calibratedRed: 0.025,
            green: 0.028,
            blue: 0.038,
            alpha: 1
        )
        terminalView.wantsLayer = true
        terminalView.autoresizingMask = [.width, .height]
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        terminalView.nativeForegroundColor = NSColor(
            calibratedRed: 0.89,
            green: 0.91,
            blue: 0.94,
            alpha: 1
        )
        terminalView.nativeBackgroundColor = background
        terminalView.layer?.backgroundColor = background.cgColor
        terminalView.caretColor = session?.provider == .claude ? .systemOrange : .systemGreen
        terminalView.getTerminal().setCursorStyle(.steadyBlock)
        try? terminalView.setUseMetal(false)
    }

    private static func environment() -> [String] {
        var values = ProcessInfo.processInfo.environment
        let existingPath = values["PATH"] ?? "/usr/bin:/bin"
        values["PATH"] = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin", isDirectory: true).path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/Applications/ChatGPT.app/Contents/Resources",
            existingPath
        ].joined(separator: ":")
        values["TERM"] = "xterm-256color"
        values["COLORTERM"] = "truecolor"
        return values.map { "\($0.key)=\($0.value)" }
    }
}
