import Foundation
import agtermCore

/// SnapshotCandidate is a clicked file an `open` selector took, checked and measured off the main actor.
struct SnapshotCandidate: Sendable, Equatable {
    let file: String
    let name: String
    let size: Int
}

extension ServerStreams {
    /// maxSnapshotSelectors bounds the selectors one click may carry; each is a file name, so 255 bytes at most.
    static let maxSnapshotSelectors = 32

    /// snapshotSelectors are the `open` selectors a click asks to be answered by, empty unless it carries an id and its
    /// viewer listed `link.snapshot`: a viewer that cannot take a snapshot would lose the click to one. Selectors are
    /// another host's text, so malformed ones are dropped.
    func snapshotSelectors(_ click: PresentationLinkClick, from sender: Int) -> [OpenerSelector] {
        guard click.click != nil, let openers = click.openers,
              presentationHub.supports(PresentationHub.linkSnapshotKind, owner: sender) else { return [] }
        return openers.prefix(Self.maxSnapshotSelectors).filter { $0.utf8.count <= 255 }.compactMap(OpenerSelector.parse)
    }

    /// snapshotCandidate is the file a resolved route names when a selector takes its name and it is a regular file
    /// within the cap of the page it would open as; nil sends the click on to its page. It reads nothing but the
    /// descriptor, so it runs before the page check.
    nonisolated static func snapshotCandidate(_ route: LinkPolicy.Route, selectors: [OpenerSelector]) -> SnapshotCandidate? {
        guard !selectors.isEmpty, let file = LinkPolicy.openerFile(for: route, source: .detected, intent: .normal) else { return nil }
        let name = file.lastPathComponent
        let path = file.path(percentEncoded: false)
        guard selectors.contains(where: { $0.matches(name) }), let cap = LinkPolicy.previewBytes(forFileName: name),
              case .success(let size) = BoundedFile.size(path: path, maxBytes: cap) else { return nil }
        return SnapshotCandidate(file: path, name: name, size: size)
    }

    /// offerSnapshot answers click `click` from viewer `sender` with a one-time claim on `candidate`.
    func offerSnapshot(_ candidate: SnapshotCandidate, click: UUID, to sender: Int) {
        let token = snapshotBook.offer(file: candidate.file, name: candidate.name, size: candidate.size)
        presentationHub.send(.linkSnapshot(PresentationLinkSnapshot(click: click, token: token, name: candidate.name,
                                                                    size: candidate.size)), toOwner: sender)
    }
}
