import Foundation

@MainActor
final class AgentProcessController {
    private weak var session: AgentSession?
    private var process: Process?
    private var outputPipe: Pipe?

    init(session: AgentSession) {
        self.session = session
    }

    func start(in directory: URL) throws {
        guard let session, process == nil else { return }

        let launchPlan = session.provider.launchPlan(prompt: session.prompt)
        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [launchPlan.executable] + launchPlan.arguments
        process.currentDirectoryURL = directory
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = Pipe()

        var environment = ProcessInfo.processInfo.environment
        let additions = ["/opt/homebrew/bin", "/usr/local/bin"]
        let currentPath = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = (additions + [currentPath]).joined(separator: ":")
        environment["TERM"] = "xterm-256color"
        process.environment = environment

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.session?.appendOutput(text)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self, let session = self.session else { return }
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.outputPipe = nil

                if session.status == .stopped { return }
                if process.terminationStatus == 0 {
                    session.status = .completed
                } else {
                    let reason = process.terminationStatus == 127
                        ? "CLI not found. Install \(session.provider.shortName) and ensure it is on PATH."
                        : "Agent exited with status \(process.terminationStatus)."
                    session.status = .failed(reason)
                    session.appendOutput("\n[Canvas Foundry] \(reason)\n")
                }
            }
        }

        self.process = process
        self.outputPipe = outputPipe
        session.status = .working
        session.appendOutput("[Canvas Foundry] \(session.provider.displayName) · \(directory.path)\n\n")

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            self.outputPipe = nil
            session.status = .failed(error.localizedDescription)
            throw error
        }
    }

    func stop() {
        guard let process else { return }
        session?.status = .stopped
        session?.appendOutput("\n[Canvas Foundry] Stopped by user.\n")
        process.terminate()
    }
}
