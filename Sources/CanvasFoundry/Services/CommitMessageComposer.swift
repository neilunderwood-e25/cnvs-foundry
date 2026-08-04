import Foundation

/// Derives a commit message from the files being committed. Deterministic and
/// offline by design — like the command bar, it describes exactly what is
/// staged and can never invent intent the diff doesn't show.
enum CommitMessageComposer {
    static func compose(for files: [GitWorkingFile]) -> String {
        guard !files.isEmpty else { return "" }

        let subject = subjectLine(for: files)
        guard files.count > 1 else { return subject }

        // Body lists every file so multi-file commits stay reviewable from the
        // log alone.
        let body = files
            .map { "- \($0.statusLabel): \($0.path)" }
            .joined(separator: "\n")
        return subject + "\n\n" + body
    }

    private static func subjectLine(for files: [GitWorkingFile]) -> String {
        if files.count == 1, let file = files.first {
            let name = (file.path as NSString).lastPathComponent
            return "\(verb(for: file)) \(name)"
        }

        let verbs = Set(files.map(verb(for:)))
        let action = verbs.count == 1 ? verbs.first! : "Update"

        let areas = Set(files.map(topLevelArea)).sorted()
        let location: String
        switch areas.count {
        case 1: location = areas[0]
        case 2: location = "\(areas[0]) and \(areas[1])"
        default: location = "\(areas.count) areas"
        }

        return "\(action) \(location) (\(files.count) files)"
    }

    private static func verb(for file: GitWorkingFile) -> String {
        switch file.statusLabel {
        case "untracked", "added": "Add"
        case "deleted": "Remove"
        case "renamed": "Rename"
        default: "Update"
        }
    }

    private static func topLevelArea(_ file: GitWorkingFile) -> String {
        let components = file.path.split(separator: "/")
        guard components.count > 1 else { return "project root" }
        return String(components[0])
    }
}
