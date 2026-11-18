import Foundation

/// OpenerSelector names the files an `open` rule takes: `*.ext` matches an extension case-insensitively, any other
/// name matches a file's basename exactly.
public enum OpenerSelector: Equatable, Hashable, Sendable {
    case `extension`(String)
    case basename(String)

    /// parse reads one selector, nil for a glob other than `*.ext` or a name holding a path separator.
    public static func parse(_ token: String) -> OpenerSelector? {
        let globs: Set<Character> = ["*", "?", "[", "]"]
        if token.hasPrefix("*.") {
            let ext = String(token.dropFirst(2))
            guard !ext.isEmpty, !ext.contains(where: { globs.contains($0) || $0 == "/" || $0 == "." }) else { return nil }
            return .extension(ext.lowercased())
        }
        guard !token.isEmpty, token != ".", token != "..",
              !token.contains(where: { globs.contains($0) || $0 == "/" }) else { return nil }
        return .basename(token)
    }

    /// text is the selector's canonical spelling, an extension lowercased (`*.MD` reads `*.md`).
    public var text: String {
        switch self {
        case .extension(let ext): "*.\(ext)"
        case .basename(let name): name
        }
    }

    /// matches says whether the selector takes a file named `name` (a basename).
    public func matches(_ name: String) -> Bool {
        switch self {
        case .extension(let ext): (name as NSString).pathExtension.lowercased() == ext
        case .basename(let basename): name == basename
        }
    }
}

/// FileOpener is one `open` line: the files it takes and the command a ⌘-click on one of them runs instead of the
/// built-in page. `command` carries the shell text and failure-panel options; its name is the selector list as
/// written, which is what a failure notice names.
public struct FileOpener: Equatable, Sendable {
    public let selectors: [OpenerSelector]
    public let command: CustomCommand
    public let line: Int

    public init(selectors: [OpenerSelector], command: CustomCommand, line: Int) {
        self.selectors = selectors
        self.command = command
        self.line = line
    }
}

public extension Keymap {
    /// opener returns the rule for a file named `name` (a basename); see `[FileOpener].opener(forFile:)`.
    func opener(forFile name: String) -> FileOpener? { openers.opener(forFile: name) }
}

public extension Array where Element == FileOpener {
    /// opener returns the rule for a file named `name` (a basename), a basename selector before an extension one;
    /// nil when no rule takes it.
    func opener(forFile name: String) -> FileOpener? {
        if let exact = first(where: { $0.selectors.contains(.basename(name)) }) { return exact }
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return first { $0.selectors.contains(.extension(ext)) }
    }
}

/// parseOpenLine reads the remainder of an `open` line: `<selectors> [failure-panel options] <shell...>`. The shell
/// text is run verbatim, so an `{AGT_` token is refused rather than left for a reader to expect expansion.
func parseOpenLine(_ rest: String, line: Int, openers: inout [FileOpener], diagnostics: inout [KeymapDiagnostic]) {
    let list = String(rest.prefix { !$0.isWhitespace })
    guard !list.isEmpty else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "open needs selectors and a shell line"))
        return
    }
    var selectors: [OpenerSelector] = []
    for token in list.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
        guard !token.isEmpty else {
            diagnostics.append(KeymapDiagnostic(line: line, message: "open '\(list)' has an empty selector; line skipped"))
            return
        }
        guard let selector = OpenerSelector.parse(token) else {
            diagnostics.append(KeymapDiagnostic(line: line,
                message: "open selector '\(token)' is neither *.ext nor a file name; line skipped"))
            return
        }
        if !selectors.contains(selector) { selectors.append(selector) }
    }
    let body = String(rest.dropFirst(list.count)).trimmingCharacters(in: .whitespaces)
    let subject = "open '\(list)'"
    guard let command = parseCommandOptions(body, name: list, subject: subject, line: line,
                                            diagnostics: &diagnostics) else { return }
    let first = String(command.command.prefix { !$0.isWhitespace })
    if let parsed = alternativeKeybinds(first), parsed.contains(where: { $0.keybind.first?.canStartShortcut == true }) {
        diagnostics.append(KeymapDiagnostic(line: line, message: "\(subject) takes no shortcut; line skipped"))
        return
    }
    guard !command.repeats else {
        diagnostics.append(KeymapDiagnostic(line: line, message: "\(subject) takes no --repeat; line skipped"))
        return
    }
    guard command.command.range(of: #"(^|[^$])\{AGT_"#, options: .regularExpression) == nil else {
        diagnostics.append(KeymapDiagnostic(line: line,
            message: "\(subject) shell text is run as written, so {AGT_...} is not expanded; use \"$AGT_PATH\" and $AGT_*; line skipped"))
        return
    }
    openers.append(FileOpener(selectors: selectors, command: command, line: line))
}

/// resolveOpeners applies last-wins per selector: a selector a later line repeats leaves the earlier line, which is
/// diagnosed, and a line left with none is dropped.
func resolveOpeners(_ parsed: [FileOpener], diagnostics: inout [KeymapDiagnostic]) -> [FileOpener] {
    var owner: [OpenerSelector: Int] = [:]
    for opener in parsed {
        for selector in opener.selectors { owner[selector] = opener.line }
    }
    return parsed.compactMap { opener in
        var kept: [OpenerSelector] = []
        for selector in opener.selectors {
            guard let later = owner[selector], later != opener.line else {
                kept.append(selector)
                continue
            }
            diagnostics.append(KeymapDiagnostic(line: opener.line,
                message: "open selector '\(selector.text)' is taken by line \(later); selector dropped"))
        }
        guard !kept.isEmpty else { return nil }
        return FileOpener(selectors: kept, command: opener.command, line: opener.line)
    }
}
