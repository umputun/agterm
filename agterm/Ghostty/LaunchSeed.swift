import agtermCore
import Foundation

/// What a pane spawns with: the exec `command`, the `initialInput` typed into a login shell, and whether a
/// command's exit holds on libghostty's "press any key" prompt. `command` and `initialInput` are mutually
/// exclusive.
struct LaunchSeed: Equatable {
    let command: String?
    let initialInput: String?
    let waitAfterCommand: Bool
}

/// A pane's seed, computed at SPAWN time rather than at construction, so the captured argv and the
/// `session.restore` pin stay on the `Session` — clearable and preservable — throughout the wait for a
/// spawn permit. `shouldPace` answers "would this pane start a program" without consuming anything.
struct LaunchSeedProvider {
    let shouldPace: Bool
    /// Takes the pane's LIVE role, never the one it was built in: `session.swap` moves a mounted surface to
    /// the other slot and swaps the pending payloads with it, so a captured role would read the other
    /// terminal's argv.
    let resolve: @MainActor (StatusPane) -> LaunchSeed
}

/// The launch-wide inputs a pane's seed is decided against: whether this process replays commands at all,
/// the user's `restore-denylist.conf`, and the daemon names the launch reap observed alive. `runningNames`
/// is a SCHEDULING hint only: nil (the list failed) paces every replaying live pane, and a name that died
/// between the list and the attach merely spawns unpaced.
struct LaunchSeedPolicy {
    let restoreEnabled: Bool
    let denylist: Set<String>
    let runningNames: Set<String>?
}

extension LaunchSeedProvider {
    /// The provider for one restored or created pane. `resolve` is the factory's own seed computation for
    /// this disposition, so `ZmxLaunch.surfaceSeed` and `CommandRestore.restorePlan` precedence is
    /// unchanged; only when it runs moves. The session is captured WEAKLY: the view it ends up on is held
    /// by that session, so a strong capture would leak every pane destroyed before it spawned.
    @MainActor
    static func pane(session: Session, pane: StatusPane, disposition: ZmxLaunch.Disposition,
                     policy: LaunchSeedPolicy) -> LaunchSeedProvider {
        let paces = shouldPace(session: session, pane: pane, disposition: disposition, policy: policy)
        return LaunchSeedProvider(shouldPace: paces) { [weak session] livePane in
            guard let session else { return unownedSeed(disposition: disposition) }
            return seed(session: session, pane: livePane, disposition: disposition, policy: policy)
        }
    }

    @MainActor
    private static func seed(session: Session, pane: StatusPane, disposition: ZmxLaunch.Disposition,
                             policy: LaunchSeedPolicy) -> LaunchSeed {
        switch disposition {
        case .wrapped:
            guard let seed = ZmxLaunch.surfaceSeed(disposition: disposition, session: session, pane: pane,
                                                   denylist: policy.denylist)
            else { preconditionFailure("wrapped zmx disposition has no surface seed") }
            return LaunchSeed(command: seed.command, initialInput: seed.initialInput, waitAfterCommand: false)
        case .ordinary:
            let capture = session.takePendingForegroundCommand(pane: pane)
            let plan = CommandRestore.restorePlan(.init(
                wasRestored: session.wasRestored,
                restoreEnabled: policy.restoreEnabled,
                hadForeground: capture != nil,
                foregroundInput: restoreInitialInput(capture, policy: policy),
                initialCommand: durableCommand(session: session, pane: pane),
                restoreOverride: session.takePendingRestoreOverride(pane: pane),
                requestedWait: requestedWait(session: session, pane: pane)))
            return LaunchSeed(command: plan.command, initialInput: plan.initialInput,
                              waitAfterCommand: plan.waitAfterCommand)
        case .fallback:
            // live was requested and is unavailable: neither pending slot is read, so both stay armed for
            // the next launch, and the durable command is held back exactly as a restored rerun-off pane.
            let plan = CommandRestore.restorePlan(.init(
                wasRestored: session.wasRestored,
                restoreEnabled: false,
                hadForeground: false,
                foregroundInput: nil,
                initialCommand: durableCommand(session: session, pane: pane),
                restoreOverride: nil,
                requestedWait: requestedWait(session: session, pane: pane)))
            return LaunchSeed(command: plan.command, initialInput: plan.initialInput,
                              waitAfterCommand: plan.waitAfterCommand)
        }
    }

    /// Whether this pane's seed would start a program, peeking the slots its disposition will read without
    /// consuming any of them. Only a RESTORED pane qualifies: fresh and runtime panes are never queued, so
    /// their host attachment must not wait on a permit.
    @MainActor
    private static func shouldPace(session: Session, pane: StatusPane, disposition: ZmxLaunch.Disposition,
                                   policy: LaunchSeedPolicy) -> Bool {
        guard session.wasRestored else { return false }
        switch disposition {
        case .wrapped(let configuration):
            // an observed daemon is attached to, which runs no program.
            if policy.runningNames?.contains(configuration.daemonName) == true { return false }
            // the pending `session.restore` pin is deliberately absent: `surfaceSeed` never reads it.
            if let capture = peekCapture(session: session, pane: pane) {
                return CommandRestore.shouldRestore(argv: capture, denylist: policy.denylist)
            }
            return durableCommand(session: session, pane: pane) != nil
        case .ordinary:
            let capture = peekCapture(session: session, pane: pane)
            let plan = CommandRestore.restorePlan(.init(
                wasRestored: true,
                restoreEnabled: policy.restoreEnabled,
                hadForeground: capture != nil,
                foregroundInput: restoreInitialInput(capture, policy: policy),
                initialCommand: durableCommand(session: session, pane: pane),
                restoreOverride: peekRestoreOverride(session: session, pane: pane),
                requestedWait: false))
            return plan.command != nil || plan.initialInput != nil
        case .fallback:
            return false
        }
    }

    /// The seed for a view whose session is already gone: a plain shell, or a bare attach for a wrapped
    /// pane, since the daemon name is the only thing left that can be honored.
    private static func unownedSeed(disposition: ZmxLaunch.Disposition) -> LaunchSeed {
        guard case .wrapped(let configuration) = disposition else {
            return LaunchSeed(command: nil, initialInput: nil, waitAfterCommand: false)
        }
        return LaunchSeed(command: configuration.command, initialInput: nil, waitAfterCommand: false)
    }

    /// The `initial_input` for a restored pane: the captured foreground argv re-rendered as a shell command
    /// line + newline, or nil outside rerun mode or when `shouldRestore` refuses the argv — a denylisted
    /// basename, a control character, or a lossily-decoded byte (→ plain shell).
    private static func restoreInitialInput(_ argv: [String]?, policy: LaunchSeedPolicy) -> String? {
        guard policy.restoreEnabled, let argv,
              CommandRestore.shouldRestore(argv: argv, denylist: policy.denylist) else { return nil }
        return CommandRestore.shellQuotedLine(argv) + "\n"
    }

    @MainActor
    private static func peekCapture(session: Session, pane: StatusPane) -> [String]? {
        switch pane {
        case .left: session.pendingForegroundCommand
        case .right: session.pendingSplitForegroundCommand
        case .scratch: nil
        }
    }

    @MainActor
    private static func peekRestoreOverride(session: Session, pane: StatusPane) -> String? {
        switch pane {
        case .left: session.pendingRestoreCommand
        case .right: session.pendingSplitRestoreCommand
        case .scratch: nil
        }
    }

    @MainActor
    private static func durableCommand(session: Session, pane: StatusPane) -> String? {
        switch pane {
        case .left: session.initialCommand
        case .right: session.splitInitialCommand
        case .scratch: nil
        }
    }

    @MainActor
    private static func requestedWait(session: Session, pane: StatusPane) -> Bool {
        switch pane {
        case .left: session.commandWait
        case .right: session.splitCommandWait
        case .scratch: false
        }
    }
}
