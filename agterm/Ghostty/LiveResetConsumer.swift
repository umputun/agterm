import agtermCore
import Darwin
import Foundation
import os

/// The launch half of the Live sessions reset: consume the marker before any kill, narrow it against this
/// launch's own claims and listing, end the confirmed daemons in one batch, and wait for their leaders.
/// Survivors are recorded on the spawn context so their panes start neither their replay nor their
/// durable command.
@MainActor
enum LiveResetConsumer {
    private static let logger = Logger(subsystem: "com.umputun.agterm", category: "LiveResetConsumer")

    struct Dependencies {
        let markerStore: LiveResetMarkerStore
        let probe: LiveAttributionProbe
        var poll = ZmxClient.LeaderPoll()
        var isAlive: (pid_t) -> Bool = { Darwin.kill($0, 0) == 0 || errno == EPERM }
        var budget: Duration = .seconds(15)
        var listTimeout: TimeInterval = 3
        var killTimeout: TimeInterval = 5
    }

    /// Nil when no marker was armed; an unreadable or undecodable marker is discarded and kills nothing.
    static func run(_ deps: Dependencies, library: WindowLibrary, client: ZmxClient,
                    context: agtermApp.LaunchSpawnContext) -> LiveReset.Outcome? {
        let marker: LiveReset.Marker
        do {
            guard let consumed = try deps.markerStore.consume() else { return nil }
            marker = consumed
        } catch {
            logger.error("live sessions reset marker discarded: \(String(describing: error), privacy: .public)")
            return nil
        }
        let deadline = deps.poll.now().advanced(by: deps.budget)
        func remaining() -> TimeInterval {
            let left = deps.poll.now().duration(to: deadline)
            return max(0, Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18)
        }
        let claims = library.paneClaims()
        let claimed: Set<UUID>? = claims.complete ? Set(claims.claims.map(\.paneIdentity)) : nil
        let records = client.sessionRecords(timeout: min(deps.listTimeout, max(remaining(), 0.1)))
        let narrowed = LiveReset.narrow(marker: marker, claimed: claimed, records: records,
                                        classify: deps.probe.classifier(endpoint: client.endpoint))
        let kill = narrowed.kill
        var survivors: Set<pid_t> = []
        if !kill.isEmpty {
            // a batch that could not start before the budget ran out is treated like one whose result is
            // unknown: every selected leader stays suppressed rather than restored
            let timeout = min(deps.killTimeout, remaining())
            if timeout <= 0 {
                logger.error("live sessions reset: the budget expired before the kill; leaving every selected pane suppressed")
                survivors = Set(kill.map(\.leaderPID))
            } else {
                if !client.killBatch(names: kill.map(\.daemon), timeout: timeout) {
                    logger.error("live sessions reset: the batched kill did not complete; polling every leader anyway")
                }
                survivors = ZmxClient.leadersExited(Set(kill.map(\.leaderPID)), deadline: deadline, poll: deps.poll, isAlive: deps.isAlive)
            }
        }
        let outcome = LiveReset.outcome(narrowed: narrowed, survivors: survivors, inventoryFailed: narrowed.inventoryFailed)
        context.suppressedLaunchPayloads = Set(outcome.unconfirmed)
        deps.markerStore.removeConsumed()
        logger.info("live sessions reset: \(outcome.panes.killed) killed, \(outcome.panes.gone) gone, \(outcome.panes.skipped) skipped, \(outcome.unconfirmed.count) unconfirmed")
        return outcome
    }
}

/// The launch steps that must follow one another once the library exists: the reset consumer, then the
/// ordinary reap over the inventory the library collected, then the foreground resolver's refresh.
@MainActor
enum LaunchOrchestration {
    struct Inputs {
        let library: WindowLibrary
        let client: ZmxClient
        let resolver: ZmxForegroundResolver
        let context: agtermApp.LaunchSpawnContext
        let launchDecision: RestoreLaunchDecision
    }

    /// A launch that did not get Live cannot suppress a survivor's ordinary seed, so a marker found by it
    /// is discarded rather than consumed: nothing is killed and the panes restore as that mode restores them.
    static func run(_ inputs: Inputs, consumer: LiveResetConsumer.Dependencies?) -> LiveReset.Outcome? {
        let live = inputs.launchDecision.requested == .live && inputs.launchDecision.active == .live
        let outcome: LiveReset.Outcome? = consumer.flatMap {
            guard live else {
                $0.markerStore.remove()
                return nil
            }
            return LiveResetConsumer.run($0, library: inputs.library, client: inputs.client, context: inputs.context)
        }
        inputs.context.runningNames = inputs.client.reap(knownPaneIdentities: inputs.context.launchInventory,
                                                         launchDecision: inputs.launchDecision).runningNames
        inputs.resolver.noteLifecycleChange()
        return outcome
    }
}
