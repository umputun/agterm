import Darwin
import Foundation
import agtermCore

/// `events.stream`: admission (reservation + anchor) and the accept thread's `events.read` fast
/// path. The push fan-out itself is `EventStreamHub` in agtermCore, tapped into the library in
/// `init`.
@MainActor
extension ControlServer {
    /// The stream open in one main-actor hop: reserve a slot FIRST so the anchor read cannot miss
    /// an event to the open window, then dispatch the anchor exactly as `events.read` answers it,
    /// cursor failures included. A non-ok reply releases the reservation; the returned id is nil
    /// then and for a full hub, the reply carrying the reason.
    func eventsStreamAdmission(_ request: ControlRequest) async -> (response: ControlResponse, reservation: UUID?) {
        let kinds: Set<ControlEventKind>?
        if case .success(let options) = ControlEventRequest.parse(request.args) { kinds = options.kinds } else { kinds = nil }
        guard let reservation = eventStreamHub.reserve(kinds: kinds) else {
            return (ControlResponse(ok: false, error: EventStreamHub.capacityRefusal), nil)
        }
        let response = await dispatch(request)
        guard response.ok, response.result?.events != nil else {
            eventStreamHub.release(reservation)
            return (response, nil)
        }
        return (response, reservation)
    }

    /// The reply is on the wire: hand the reserved slot its connection. The anchor batch covered
    /// `anchor.next`, so buffered frames past it flush in order behind the reply. False when the
    /// reservation was dropped while pending: the stream is not adopted and the caller closes.
    func commitEventStream(reservation: UUID, descriptor: Int32, anchor: ControlEventBatch) -> Bool {
        eventStreamHub.commit(reservation, descriptor: descriptor, cursor: anchor.next)
    }

    /// A reply that could not be written abandons its reservation; the accept loop's defer still
    /// owns closing the descriptor.
    func abandonEventStreamReservation(_ reservation: UUID) {
        eventStreamHub.release(reservation)
    }

    /// `events.read` answered from the ring's tail snapshot with no main-actor hop: every outcome
    /// that needs no entry data — the bootstrap anchor, the at-tail empty page, and the three cursor
    /// errors, byte-identical to `readEvents`. A cursor behind the tail may have matching entries,
    /// which only the ring knows; nil falls through to the main actor.
    nonisolated func fastPathEventsReadResponse(for request: ControlRequest) -> ControlResponse? {
        let options: ControlEventReadOptions
        switch ControlEventRequest.parse(request.args) {
        case .success(let parsed): options = parsed
        case .failure(let error): return ControlResponse(ok: false, error: error)
        }
        let tail = controlEventTail.read()
        let anchor = ControlEventBatch(run: tail.run, next: tail.next, items: [])
        guard let cursor = options.cursor else {
            return ControlResponse(ok: true, result: ControlResult(events: anchor))
        }
        guard cursor.run == tail.run else {
            return ControlResponse(ok: false, result: ControlResult(events: anchor), error: ControlEventReadError.runChanged.rawValue)
        }
        guard cursor.after <= tail.next else {
            return ControlResponse(ok: false, result: ControlResult(events: anchor), error: ControlEventReadError.cursorAhead.rawValue)
        }
        if let oldest = tail.oldest, cursor.after < oldest - 1 {
            return ControlResponse(ok: false, result: ControlResult(events: anchor), error: ControlEventReadError.cursorExpired.rawValue)
        }
        guard cursor.after == tail.next else { return nil }
        return ControlResponse(ok: true, result: ControlResult(events: anchor))
    }
}
