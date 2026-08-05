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
    case processNotRunning(String)
    case emptyPrompt

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            "Could not find the \(name) CLI. Install it, authenticate it, and relaunch Canvas Foundry."
        case .processNotRunning(let name):
            "\(name) isn't running. Relaunch the agent before sending it a prompt."
        case .emptyPrompt:
            "The agent prompt is empty."
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
        resumeConversation: Bool = false,
        initialPrompt: String? = nil,
        executableOverride: URL? = nil,
        argumentsOverride: [String]? = nil
    ) throws {
        self.session = session
        self.terminalView = CanvasTerminalView(frame: .zero)
        super.init()

        configureTerminal()
        terminalView.processDelegate = self

        let normalizedInitialPrompt = initialPrompt
            .map(Self.normalizedPrompt)
            .flatMap { $0.isEmpty ? nil : $0 }
        let plan = session.provider.launchPlan(
            resuming: resumeConversation,
            initialPrompt: normalizedInitialPrompt
        )
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

    /// Delivers one printable prompt and one Return directly to the agent PTY.
    /// Control characters are replaced with spaces so voice/text routing cannot
    /// smuggle terminal escapes, interrupts, or additional submitted commands.
    func submitPrompt(_ rawPrompt: String) throws {
        guard terminalView.process.running else {
            throw AgentTerminalError.processNotRunning(session?.name ?? "This agent")
        }

        let prompt = Self.normalizedPrompt(rawPrompt)
        guard !prompt.isEmpty else { throw AgentTerminalError.emptyPrompt }

        var bytes = Array(prompt.utf8)
        bytes.append(0x0d)
        terminalView.send(data: bytes[...])
        focus()
    }

    nonisolated static func normalizedPrompt(_ rawPrompt: String) -> String {
        let printableScalars = rawPrompt.unicodeScalars.map { scalar -> Character in
            let isControl = scalar.value < 0x20 || (scalar.value >= 0x7f && scalar.value <= 0x9f)
            return isControl ? " " : Character(scalar)
        }
        return String(printableScalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func stop(preservingSessionStatus: Bool = false) -> Bool {
        guard terminalView.process.running else { return false }
        didRequestStop = true
        preservesSessionStatusOnStop = preservingSessionStatus
        if !preservingSessionStatus {
            session?.status = .stopped
        }
        terminalView.terminate()
        return true
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
