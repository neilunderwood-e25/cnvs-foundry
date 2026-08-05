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
        let normalized = normalizeSpeechArtifacts(in: input)

        if let command = matchCreateAgentWithPrompt(tokens(in: normalized)) {
            plan.commands.append(command)
            return plan
        }

        // A prompt commonly contains conjunctions ("inspect and fix"), so
        // targeted-agent requests are matched against the whole utterance before
        // the generic multi-command clause splitter sees it.
        if let command = matchSendPrompt(
            tokens(in: normalized),
            knownAgentNames: knownAgentNames
        ) {
            plan.commands.append(command)
            return plan
        }

        for clause in clauses(in: normalized) where !clause.isEmpty {
            if let command = matchClearDrawings(clause) {
                plan.commands.append(command)
            } else if let command = matchResetView(clause) {
                plan.commands.append(command)
            } else if let outcome = matchCreateAgents(clause) {
                plan.commands.append(outcome.command)
                if let note = outcome.note { plan.notes.append(note) }
            } else if let command = matchAgentLifecycle(
                clause,
                knownAgentNames: knownAgentNames
            ) {
                plan.commands.append(command)
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

    /// Cleans up a few high-confidence dictation artifacts before tokenising.
    /// Keep this conservative: uncertain language should be rejected by the
    /// grammar rather than silently turned into a different action.
    static func normalizeSpeechArtifacts(in input: String) -> String {
        let clauseMarker = "foundryclauseseparator"
        var words = input
            .lowercased()
            .replacingOccurrences(of: ",", with: " \(clauseMarker) ")
            .replacingOccurrences(of: ";", with: " \(clauseMarker) ")
            .replacingOccurrences(of: "+", with: " \(clauseMarker) ")
            .replacingOccurrences(of: "&", with: " \(clauseMarker) ")
            .replacingOccurrences(of: "code x", with: "codex")
            .replacingOccurrences(of: "code ex", with: "codex")
            .split { !$0.isLetter && !$0.isNumber && $0 != "-" }
            .map(String.init)

        // Dictation can retain a false-started number: "one, two more Claude
        // agents". When two quantities are adjacent and explicitly followed by
        // "more", the last quantity is the corrected one. We do not apply this
        // to a bare "one two" because that could mean twelve.
        let quantityWords = Set(numberWords.keys)
        var index = 0
        while index + 2 < words.count {
            let firstIsQuantity = Int(words[index]) != nil || quantityWords.contains(words[index])
            let secondIsQuantity = Int(words[index + 1]) != nil
                || quantityWords.contains(words[index + 1])
            if firstIsQuantity, secondIsQuantity, words[index + 2] == "more" {
                words.remove(at: index)
            } else {
                index += 1
            }
        }
        return words
            .map { $0 == clauseMarker ? "and" : $0 }
            .joined(separator: " ")
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

    private static func tokens(in input: String) -> [String] {
        input
            .split { !$0.isLetter && !$0.isNumber && $0 != "-" }
            .map(String.init)
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

    private static let promptVerbs: Set<String> = ["tell", "ask", "send"]

    private static let stopVerbs: Set<String> = [
        "stop", "pause", "halt", "terminate"
    ]

    private static let resumeVerbs: Set<String> = [
        "resume", "relaunch", "restart", "continue", "wake"
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

        // Never discard a task tail and accidentally open idle agents. The
        // single-agent form is handled by matchCreateAgentWithPrompt; multiple
        // agents with one shared task are intentionally unsupported for now.
        if let providerIndex = tokens.firstIndex(where: { providerAliases[$0] != nil }),
           tokens[(providerIndex + 1)...].contains("to") {
            return nil
        }

        let count = min(max(requested ?? 1, 1), maximumAgentsPerCommand)
        let note = (requested ?? 1) > maximumAgentsPerCommand
            ? "Capped at \(maximumAgentsPerCommand) agents per command"
            : nil
        return (.createAgents(provider: provider, count: count), note)
    }

    private static func matchCreateAgentWithPrompt(
        _ tokens: [String]
    ) -> WorkspaceCommand? {
        guard let providerIndex = tokens.firstIndex(where: { providerAliases[$0] != nil }),
              let provider = providerAliases[tokens[providerIndex]],
              tokens.contains(where: { createVerbs.contains($0) }),
              let taskSeparator = tokens.indices.first(where: {
                  $0 > providerIndex && tokens[$0] == "to"
              }),
              taskSeparator + 1 < tokens.count else {
            return nil
        }

        // One initial task maps to one isolated agent. Reject counts greater
        // than one instead of cloning a vague task across several worktrees.
        guard (requestedCount(in: Array(tokens[...taskSeparator])) ?? 1) == 1 else {
            return nil
        }
        let prompt = tokens[(taskSeparator + 1)...].joined(separator: " ")
        guard !prompt.isEmpty else { return nil }
        return .createAgentWithPrompt(provider: provider, prompt: prompt)
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

    private static func matchAgentLifecycle(
        _ tokens: [String],
        knownAgentNames: [String]
    ) -> WorkspaceCommand? {
        guard let verbIndex = tokens.firstIndex(where: {
            stopVerbs.contains($0) || resumeVerbs.contains($0)
        }) else { return nil }

        // Allow natural filler between verb and name: “restart the agent Reese”.
        for start in tokens.indices where start > verbIndex {
            guard let match = agentName(
                startingAt: start,
                in: tokens,
                knownAgentNames: knownAgentNames
            ) else { continue }
            if stopVerbs.contains(tokens[verbIndex]) {
                return .stopAgent(name: match.name)
            }
            return .resumeAgent(name: match.name)
        }
        return nil
    }

    private static func matchSendPrompt(
        _ tokens: [String],
        knownAgentNames: [String]
    ) -> WorkspaceCommand? {
        guard !tokens.isEmpty, !knownAgentNames.isEmpty else { return nil }

        // Natural English puts the target last for “say hi to Reese”.
        if let sayIndex = tokens.firstIndex(of: "say") {
            for toIndex in tokens.indices.reversed()
            where toIndex > sayIndex && tokens[toIndex] == "to" {
                let targetTokens = Array(tokens[(toIndex + 1)...])
                guard let name = exactAgentName(
                    matching: droppingPoliteSuffix(from: targetTokens),
                    knownAgentNames: knownAgentNames
                ) else { continue }
                let prompt = tokens[(sayIndex + 1)..<toIndex].joined(separator: " ")
                if !prompt.isEmpty {
                    return .sendPrompt(name: name, prompt: prompt)
                }
            }
        }

        // “Tell/ask Reese to …” and “send [to] Reese …” put the target first.
        guard let verbIndex = tokens.firstIndex(where: { promptVerbs.contains($0) }) else {
            return nil
        }
        var targetStart = verbIndex + 1
        if targetStart < tokens.count, tokens[targetStart] == "to" {
            targetStart += 1
        }
        guard let match = agentName(
            startingAt: targetStart,
            in: tokens,
            knownAgentNames: knownAgentNames
        ) else { return nil }

        var promptStart = match.endIndex
        if promptStart < tokens.count, tokens[promptStart] == "to" {
            promptStart += 1
        }
        guard promptStart < tokens.count else { return nil }
        let prompt = tokens[promptStart...].joined(separator: " ")
        guard !prompt.isEmpty else { return nil }
        return .sendPrompt(name: match.name, prompt: prompt)
    }

    private static func agentName(
        startingAt start: Int,
        in tokens: [String],
        knownAgentNames: [String]
    ) -> (name: String, endIndex: Int)? {
        guard start < tokens.count else { return nil }
        let candidates = knownAgentNames
            .map { name in (name, self.tokens(in: name.lowercased())) }
            .sorted { $0.1.count > $1.1.count }

        for (name, nameTokens) in candidates where !nameTokens.isEmpty {
            let end = start + nameTokens.count
            guard end <= tokens.count else { continue }
            if Array(tokens[start..<end]) == nameTokens {
                return (name, end)
            }
        }
        return nil
    }

    private static func exactAgentName(
        matching tokens: [String],
        knownAgentNames: [String]
    ) -> String? {
        knownAgentNames.first {
            self.tokens(in: $0.lowercased()) == tokens
        }
    }

    private static func droppingPoliteSuffix(from tokens: [String]) -> [String] {
        guard tokens.last == "please" else { return tokens }
        return Array(tokens.dropLast())
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
