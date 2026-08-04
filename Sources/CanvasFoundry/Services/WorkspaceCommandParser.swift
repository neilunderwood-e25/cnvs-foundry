import Foundation

/// Turns a line like "add 3 claude agents and one code agent" into commands.
///
/// Deliberately a grammar rather than a model: the vocabulary is small and
/// closed, so this stays instant, offline, deterministic, and unable to invent
/// an action that was never asked for. Speech synonyms are folded in here so the
/// same table serves typed and (later) dictated input.
enum WorkspaceCommandParser {
    /// Agent creation is expensive — each one is a git worktree plus a process —
    /// so a fat-fingered or mis-heard number cannot run away.
    static let maximumAgentsPerCommand = 8

    static func parse(_ input: String, knownAgentNames: [String] = []) -> WorkspaceCommandPlan {
        var plan = WorkspaceCommandPlan()

        for clause in clauses(in: input) where !clause.isEmpty {
            if let command = matchClearDrawings(clause) {
                plan.commands.append(command)
            } else if let command = matchResetView(clause) {
                plan.commands.append(command)
            } else if let outcome = matchCreateAgents(clause) {
                plan.commands.append(outcome.command)
                if let note = outcome.note { plan.notes.append(note) }
            } else if let command = matchFocusAgent(clause, knownAgentNames: knownAgentNames) {
                plan.commands.append(command)
            } else if let command = matchBackground(clause) {
                plan.commands.append(command)
            } else if let command = matchTool(clause) {
                plan.commands.append(command)
            } else {
                plan.unrecognized.append(clause.joined(separator: " "))
            }
        }

        return plan
    }

    // MARK: - Tokenising

    private static let clauseSeparators: Set<String> = ["and", "then", "plus", "also"]

    /// Splits input into token lists, one per clause. Commas and "+" are folded
    /// into "and" first so "2 claude, 1 codex" reads as two requests.
    static func clauses(in input: String) -> [[String]] {
        let normalized = input
            .lowercased()
            .replacingOccurrences(of: ",", with: " and ")
            .replacingOccurrences(of: ";", with: " and ")
            .replacingOccurrences(of: "+", with: " and ")
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "open ai", with: "openai")

        let words = normalized
            .split { !$0.isLetter && !$0.isNumber && $0 != "-" }
            .map(String.init)

        var result: [[String]] = []
        var current: [String] = []
        for word in words {
            if clauseSeparators.contains(word) {
                if !current.isEmpty { result.append(current) }
                current = []
            } else {
                current.append(word)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: - Vocabulary

    /// Speech-friendly aliases. "code agent" for Codex and "cloud" for Claude are
    /// the mishearings that would otherwise dominate.
    static let providerAliases: [String: AgentProvider] = [
        "claude": .claude, "claud": .claude, "clause": .claude, "clawed": .claude,
        "cloud": .claude, "clod": .claude, "clode": .claude, "claudia": .claude,
        "codex": .codex, "code": .codex, "codec": .codex, "codecs": .codex,
        "coder": .codex, "codeex": .codex, "gpt": .codex, "openai": .codex
    ]

    private static let createVerbs: Set<String> = [
        "add", "create", "open", "launch", "start", "spin", "make", "new",
        "give", "need", "want", "run", "boot"
    ]

    private static let agentNouns: Set<String> = [
        "agent", "agents", "terminal", "terminals", "cli", "clis",
        "instance", "instances", "worker", "workers"
    ]

    private static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "couple": 2, "pair": 2, "few": 3, "several": 3, "dozen": 12
    ]

    private static let toolAliases: [String: CanvasTool] = [
        "select": .select, "selection": .select, "cursor": .select, "pointer": .select,
        "hand": .hand, "pan": .hand, "grab": .hand,
        "pen": .pen, "pencil": .pen, "freehand": .pen, "draw": .pen, "scribble": .pen,
        "rectangle": .rectangle, "rect": .rectangle, "box": .rectangle, "square": .rectangle,
        "ellipse": .ellipse, "circle": .ellipse, "oval": .ellipse,
        "line": .line,
        "arrow": .arrow,
        "text": .text, "note": .text, "label": .text,
        "eraser": .eraser, "erase": .eraser, "rubber": .eraser
    ]

    private static let toolVerbs: Set<String> = [
        "use", "pick", "grab", "switch", "choose", "activate", "select", "give"
    ]

    private static let focusVerbs: Set<String> = [
        "focus", "find", "show", "center", "centre", "jump", "reveal", "where",
        "go", "goto", "locate"
    ]

    private static let clearVerbs: Set<String> = [
        "clear", "erase", "wipe", "delete", "remove", "reset"
    ]

    private static let clearNouns: Set<String> = [
        "drawing", "drawings", "annotation", "annotations", "ink",
        "board", "sketch", "sketches", "whiteboard", "doodles"
    ]

    private static let resetVerbs: Set<String> = [
        "reset", "recenter", "recentre", "center", "centre", "fit", "home"
    ]

    private static let resetNouns: Set<String> = [
        "view", "canvas", "zoom", "screen", "viewport", "camera"
    ]

    // MARK: - Matchers

    private static func matchCreateAgents(
        _ tokens: [String]
    ) -> (command: WorkspaceCommand, note: String?)? {
        guard let provider = tokens.compactMap({ providerAliases[$0] }).first else {
            return nil
        }

        let requested = requestedCount(in: tokens)
        let hasCreateVerb = tokens.contains { createVerbs.contains($0) }
        let hasAgentNoun = tokens.contains { agentNouns.contains($0) }

        // A bare provider name is too ambiguous to act on — "claude" alone could
        // be anything, so require a verb, a noun, or a count.
        guard hasCreateVerb || hasAgentNoun || requested != nil else { return nil }

        let count = min(max(requested ?? 1, 1), maximumAgentsPerCommand)
        let note = (requested ?? 1) > maximumAgentsPerCommand
            ? "Capped at \(maximumAgentsPerCommand) agents per command"
            : nil
        return (.createAgents(provider: provider, count: count), note)
    }

    private static func matchFocusAgent(
        _ tokens: [String],
        knownAgentNames: [String]
    ) -> WorkspaceCommand? {
        let lookup = Dictionary(
            knownAgentNames.map { ($0.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let matched = tokens.compactMap({ lookup[$0] }).first else { return nil }
        let hasFocusVerb = tokens.contains { focusVerbs.contains($0) }
        guard hasFocusVerb || tokens.count == 1 else { return nil }
        return .focusAgent(name: matched)
    }

    private static func matchBackground(_ tokens: [String]) -> WorkspaceCommand? {
        // Providers win over backdrops, so "add codex" is never a theme change.
        guard !tokens.contains(where: { providerAliases[$0] != nil }) else { return nil }
        guard let background = tokens.compactMap({ CanvasBackground(rawValue: $0) }).first else {
            return nil
        }
        return .setBackground(background)
    }

    private static func matchTool(_ tokens: [String]) -> WorkspaceCommand? {
        guard let tool = tokens.compactMap({ toolAliases[$0] }).first else { return nil }
        let hasToolWord = tokens.contains("tool") || tokens.contains("tools")
        let hasToolVerb = tokens.contains { toolVerbs.contains($0) }
        // "circle" on its own is more likely a stray word than a tool switch.
        guard hasToolWord || hasToolVerb || tokens.count == 1 else { return nil }
        return .selectTool(tool)
    }

    private static func matchClearDrawings(_ tokens: [String]) -> WorkspaceCommand? {
        guard tokens.contains(where: { clearVerbs.contains($0) }),
              tokens.contains(where: { clearNouns.contains($0) }) else {
            return nil
        }
        return .clearDrawings
    }

    private static func matchResetView(_ tokens: [String]) -> WorkspaceCommand? {
        guard tokens.contains(where: { resetVerbs.contains($0) }) else { return nil }
        // "reset the drawings" is a clear, not a camera move.
        guard !tokens.contains(where: { clearNouns.contains($0) }) else { return nil }
        guard tokens.contains(where: { resetNouns.contains($0) }) || tokens.count == 1 else {
            return nil
        }
        return .resetView
    }

    /// First real quantity in the clause. An article directly before another
    /// quantity is skipped, so "a couple of agents" is two, not one.
    private static func requestedCount(in tokens: [String]) -> Int? {
        for (index, token) in tokens.enumerated() {
            guard let value = numberValue(token) else { continue }
            let isArticle = token == "a" || token == "an"
            let nextIsQuantity = index + 1 < tokens.count
                && numberValue(tokens[index + 1]) != nil
            if isArticle && nextIsQuantity { continue }
            return value
        }
        return nil
    }

    private static func numberValue(_ token: String) -> Int? {
        if let digits = Int(token) { return digits }
        return numberWords[token]
    }
}
