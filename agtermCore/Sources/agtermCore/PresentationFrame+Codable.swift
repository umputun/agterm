import Foundation

extension PresentationFrame: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, gen, rev, hello, snapshot, status, context, info, layout, hud, notify, message, mail, companions, sound, ask, pick, overlay, page, respawn, link,
             pending, lead
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gen = try container.decode(Int.self, forKey: .gen)
        rev = try container.decode(Int.self, forKey: .rev)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "hello": body = .hello(try container.decode(PresentationHello.self, forKey: .hello))
        case "ping": body = .ping
        case "ack": body = .ack
        case "snapshot": body = .snapshot(try container.decode(PresentationSnapshot.self, forKey: .snapshot))
        case "status": body = .status(try container.decodeIfPresent(PresentationStatus.self, forKey: .status))
        case "context": body = .context(try container.decodeIfPresent(String.self, forKey: .context))
        case "info": body = .info(try container.decodeIfPresent(PresentationInfo.self, forKey: .info))
        case "layout": body = .layout((try? container.decode(PresentationLayout.self, forKey: .layout)) ?? .invalid)
        case "hud": body = .hud(try container.decodeIfPresent(PresentationHud.self, forKey: .hud))
        case "notify": body = .notify(try container.decode(PresentationNotify.self, forKey: .notify))
        case "message": body = .message(try container.decode(PresentationMessage.self, forKey: .message))
        case "mail": body = .mail(try container.decode(PresentationMail.self, forKey: .mail))
        case "companions": body = .companions(try container.decode(PresentationCompanions.self, forKey: .companions))
        case "sound": body = .sound(try container.decode(PresentationSound.self, forKey: .sound))
        case "presenter.acquire": body = .presenterAcquire
        case "presenter.granted": body = .presenterGranted
        case "presenter.refused": body = .presenterRefused
        case "presenter.vacant": body = .presenterVacant
        case "ended": body = .ended
        case "lead.report": body = .leadReport(try container.decode(PresentationLeadReport.self, forKey: .lead))
        case "ask.request": body = .askRequest(try container.decode(PresentationAsk.self, forKey: .ask))
        case "ask.resolve": body = .askResolve(try container.decode(PresentationAskAnswer.self, forKey: .ask))
        case "ask.rejected": body = .askRejected(try container.decode(PresentationAskRef.self, forKey: .ask))
        case "ask.dismiss": body = .askDismiss(try container.decode(PresentationAskRef.self, forKey: .ask))
        case "pick.request": body = .pickRequest(try container.decode(PresentationPick.self, forKey: .pick))
        case "pick.resolve": body = .pickResolve(try container.decode(PresentationPickAnswer.self, forKey: .pick))
        case "pick.rejected": body = .pickRejected(try container.decode(PresentationPickRef.self, forKey: .pick))
        case "pick.dismiss": body = .pickDismiss(try container.decode(PresentationPickRef.self, forKey: .pick))
        case "overlay.request": body = .overlayRequest(try container.decode(PresentationOverlay.self, forKey: .overlay))
        case "overlay.rejected":
            body = .overlayRejected(try container.decode(PresentationOverlayChange.self, forKey: .overlay))
        case "overlay.close": body = .overlayClose(try container.decode(PresentationOverlayChange.self, forKey: .overlay))
        case "overlay.resize": body = .overlayResize(try container.decode(PresentationOverlayChange.self, forKey: .overlay))
        case "overlay.closed": body = .overlayClosed(try container.decode(PresentationOverlayChange.self, forKey: .overlay))
        case "page.request": body = .pageRequest(try container.decode(PresentationPage.self, forKey: .page))
        case "page.rejected": body = .pageRejected(try container.decode(PresentationPageChange.self, forKey: .page))
        case "page.close": body = .pageClose(try container.decode(PresentationPageChange.self, forKey: .page))
        case "page.closed": body = .pageClosed(try container.decode(PresentationPageChange.self, forKey: .page))
        case "page.command": body = .pageCommand(try container.decode(PresentationPageCommand.self, forKey: .page))
        case "page.state": body = .pageState(try container.decode(PresentationPageState.self, forKey: .page))
        case "page.result": body = .pageResult(try container.decode(PresentationPageResult.self, forKey: .page))
        case "pane.respawn": body = .respawn(try container.decode(PresentationRespawns.self, forKey: .respawn))
        case "link.click": body = .linkClick(try container.decode(PresentationLinkClick.self, forKey: .link))
        case "link.refused": body = .linkRefused(try container.decode(PresentationLinkRefusal.self, forKey: .link))
        case "link.snapshot": body = .linkSnapshot(try container.decode(PresentationLinkSnapshot.self, forKey: .link))
        case "status.clear": body = .statusClear(try container.decode(PresentationStatusClear.self, forKey: .status))
        case "status.seen": body = .statusSeen(try container.decode(PresentationSeen.self, forKey: .status))
        case "pending.chunk": body = .pendingChunk(try container.decode(PresentationPendingChunk.self, forKey: .pending))
        case "pending.commit": body = .pendingCommit
        default: body = .unknown(kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(body.kind, forKey: .kind)
        try container.encode(gen, forKey: .gen)
        try container.encode(rev, forKey: .rev)
        switch body {
        case .hello(let hello): try container.encode(hello, forKey: .hello)
        case .snapshot(let snapshot): try container.encode(snapshot, forKey: .snapshot)
        case .status(let status): try container.encodeIfPresent(status, forKey: .status)
        case .context(let context): try container.encodeIfPresent(context, forKey: .context)
        case .info(let info): try container.encodeIfPresent(info, forKey: .info)
        case .layout(let layout): try container.encode(layout, forKey: .layout)
        case .hud(let hud): try container.encodeIfPresent(hud, forKey: .hud)
        case .notify(let notify): try container.encode(notify, forKey: .notify)
        case .message(let message): try container.encode(message, forKey: .message)
        case .mail(let mail): try container.encode(mail, forKey: .mail)
        case .companions(let companions): try container.encode(companions, forKey: .companions)
        case .sound(let sound): try container.encode(sound, forKey: .sound)
        case .askRequest(let ask): try container.encode(ask, forKey: .ask)
        case .askResolve(let answer): try container.encode(answer, forKey: .ask)
        case .askRejected(let ref), .askDismiss(let ref): try container.encode(ref, forKey: .ask)
        case .pickRequest(let pick): try container.encode(pick, forKey: .pick)
        case .pickResolve(let answer): try container.encode(answer, forKey: .pick)
        case .pickRejected(let ref), .pickDismiss(let ref): try container.encode(ref, forKey: .pick)
        case .overlayRequest(let overlay): try container.encode(overlay, forKey: .overlay)
        case .overlayRejected(let change), .overlayClose(let change), .overlayResize(let change),
             .overlayClosed(let change):
            try container.encode(change, forKey: .overlay)
        case .pageRequest(let page): try container.encode(page, forKey: .page)
        case .pageRejected(let change), .pageClose(let change), .pageClosed(let change):
            try container.encode(change, forKey: .page)
        case .pageCommand(let command): try container.encode(command, forKey: .page)
        case .pageState(let state): try container.encode(state, forKey: .page)
        case .pageResult(let result): try container.encode(result, forKey: .page)
        case .respawn(let respawns): try container.encode(respawns, forKey: .respawn)
        case .linkClick(let click): try container.encode(click, forKey: .link)
        case .linkRefused(let refusal): try container.encode(refusal, forKey: .link)
        case .linkSnapshot(let snapshot): try container.encode(snapshot, forKey: .link)
        case .statusClear(let clear): try container.encode(clear, forKey: .status)
        case .statusSeen(let seen): try container.encode(seen, forKey: .status)
        case .pendingChunk(let chunk): try container.encode(chunk, forKey: .pending)
        case .leadReport(let report): try container.encode(report, forKey: .lead)
        case .ping, .ack, .presenterAcquire, .presenterGranted, .presenterRefused, .presenterVacant, .ended, .unknown, .pendingCommit: break
        }
    }
}
