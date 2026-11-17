import Foundation
import agtermCore

extension ControlServer {
    /// pasteText is the text a paste of `offer` inserts into `surface` once its files or image are copied: an image is
    /// saved on this Mac for a program running here, and files or an image go to the origin for one running there. The
    /// copy shows in a panel over the pane's row, and a failure there or as a notification.
    func pasteText(_ offer: PasteOffer, for surface: GhosttySurfaceView) async -> Result<String, PasteFailure> {
        let hud = pasteHud(for: surface)
        let result = if let origin = surface.linkClickRemoteSession {
            await sendPaste(offer, row: origin, hud: hud)
        } else {
            await stagePaste(offer)
        }
        switch result {
        case .success: hud.close()
        case .failure(let failure): hud.fail(failure.reason)
        }
        return result
    }

    /// reportPasteRefusal shows why a paste into `surface` did nothing, over its row or as a notification.
    func reportPasteRefusal(_ reason: String, for surface: GhosttySurfaceView) {
        pasteHud(for: surface).fail(reason)
    }

    private func pasteHud(for surface: GhosttySurfaceView) -> RemoteAttachHud {
        let row = surface.linkClickRemoteSession ?? surface.session?.id ?? surface.scratchOwner?.id ?? surface.focusSession?.id
        let window = row.flatMap { library.store(forSession: $0) }.flatMap { library.windowID(for: $0) }
        return RemoteAttachHud(attacher: self, session: row?.uuidString, window: window?.uuidString ?? "", action: "Paste")
    }

    private func stagePaste(_ offer: PasteOffer) async -> Result<String, PasteFailure> {
        guard case .image(let image) = offer.action else { return .failure(PasteFailure("nothing to paste")) }
        let staging = PasteTransfer.shared.staging
        let name = PasteOffer.imageName(at: Date())
        return await Task.detached(priority: .userInitiated) {
            Result { ShellEscape.path(try staging.stage(image: image, name: name)) }
                .mapError { PasteFailure(String(describing: $0)) }
        }.value
    }

    private func sendPaste(_ offer: PasteOffer, row: UUID, hud: RemoteAttachHud) async -> Result<String, PasteFailure> {
        guard let host = library.store(forSession: row)?.session(withID: row)?.remoteHost else {
            return .failure(PasteFailure("the origin cannot be reached for this paste"))
        }
        let pool = catalogPool(forSession: row)
        let user = "paste:\(UUID().uuidString)"
        let controlPath = pool?.lease(user)
        defer { pool?.release(user) }
        guard let command = try? RemoteSession.pasteReceiveCommand(host: host, controlPath: controlPath) else {
            return .failure(PasteFailure("the origin cannot be reached for this paste"))
        }
        hud.progress("copying to \(host)")
        let runner = PasteTransfer.shared.runner
        let reply = await Task.detached(priority: .userInitiated) {
            await Self.send(offer, command: command, runner: runner)
        }.value
        guard let paths = reply.paths else { return .failure(PasteFailure(reply.error ?? "the paste could not be copied")) }
        let text: String? = if case .image = offer.action {
            paths.count == 1 ? ShellEscape.path(paths[0]) : nil
        } else {
            offer.insertText(filePaths: paths)
        }
        return text.map { .success($0) } ?? .failure(PasteFailure("the origin answered for a different paste"))
    }

    /// send bundles `offer` into a private temporary file and runs `command` with it on standard input, allowing 15
    /// seconds plus one per megabyte. The file goes on every outcome.
    nonisolated private static func send(_ offer: PasteOffer, command: [String],
                                         runner: any RemoteInputCommandRunner) async -> PasteStaging.Reply {
        let entries: [PasteBundle.Entry]
        let bundle: URL
        do {
            entries = switch offer.action {
            case .image(let image): try PasteBundle.entries(image: image, name: PasteOffer.imageName(at: Date()))
            default: try PasteBundle.entries(files: offer.fileURLs)
            }
            bundle = try PasteBundle.temporaryFile(entries)
        } catch {
            return PasteStaging.Reply(error: String(describing: error))
        }
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let megabytes = Double(entries.reduce(0) { $0 + $1.header.size }) / 1_000_000
        return PasteStaging.Reply(result: await runner.run(command, deadline: 15 + megabytes, input: bundle))
    }
}
