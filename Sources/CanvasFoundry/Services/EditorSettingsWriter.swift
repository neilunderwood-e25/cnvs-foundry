import Foundation

/// Keeps a project's `.vscode/settings.json` compatible with in-repo worktrees.
///
/// VS Code and Cursor discover repositories by scanning workspace subfolders,
/// but only to `git.repositoryScanMaxDepth` levels — and the default is 1.
/// Agent worktrees live at depth 3 (`.foundry/worktrees/<agent>`), so without
/// this setting the Source Control panel never sees their changes.
enum EditorSettingsWriter {
    static let scanDepthKey = "git.repositoryScanMaxDepth"
    /// `.foundry` (1) → `worktrees` (2) → `<agent>` (3).
    static let requiredScanDepth = 3

    /// Merges the scan depth into `.vscode/settings.json`, creating the file if
    /// needed. Existing keys are preserved; an existing depth is only ever
    /// raised (with -1 meaning unlimited, which is left alone). A file that
    /// fails to parse — JSONC comments, trailing commas — is left untouched
    /// rather than risk mangling hand-written configuration.
    @discardableResult
    static func ensureRepositoryScanDepth(projectRoot: URL) throws -> Bool {
        let settingsDir = projectRoot.appendingPathComponent(".vscode", isDirectory: true)
        let settingsURL = settingsDir.appendingPathComponent("settings.json", isDirectory: false)

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = parsed as? [String: Any] else {
                NSLog(
                    "Canvas Foundry left %@ untouched: not plain JSON. Add \"%@\": %d manually so the editor can discover agent worktrees.",
                    settingsURL.path,
                    scanDepthKey,
                    requiredScanDepth
                )
                return false
            }
            settings = dictionary
        }

        if let existing = settings[scanDepthKey] as? Int,
           existing == -1 || existing >= requiredScanDepth {
            return false
        }

        settings[scanDepthKey] = requiredScanDepth

        try FileManager.default.createDirectory(
            at: settingsDir,
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsURL, options: .atomic)
        return true
    }
}
