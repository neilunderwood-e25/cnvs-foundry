import Foundation

struct CommandResult: Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

enum ShellRunnerError: LocalizedError {
    case couldNotLaunch(String)

    var errorDescription: String? {
        switch self {
        case .couldNotLaunch(let message): message
        }
    }
}

struct ShellRunner: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil
    ) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectoryURL
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                throw ShellRunnerError.couldNotLaunch(error.localizedDescription)
            }

            let outputTask = Task.detached {
                outputPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let errorTask = Task.detached {
                errorPipe.fileHandleForReading.readDataToEndOfFile()
            }
            process.waitUntilExit()
            let output = await outputTask.value
            let error = await errorTask.value

            return CommandResult(
                exitCode: process.terminationStatus,
                standardOutput: String(decoding: output, as: UTF8.self),
                standardError: String(decoding: error, as: UTF8.self)
            )
        }.value
    }
}
