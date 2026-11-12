# CI flake record

Every intermittent CI failure investigated so far, with what it looks like in the log, what caused it, the
evidence, and the fix. Search this file for the failing test name or the error text before starting a new
investigation. Most entries come from the investigation in PR #968.

Each entry separates a demonstrated cause from one that is only consistent with the evidence.

## How these were found

- **Raw job logs name the failing test.** Read them with
  `gh api repos/umputun/agterm/actions/jobs/<job-id>/logs --allow-escape-sequences`. Without the flag `gh`
  refuses logs carrying terminal escapes.
- **A probe workflow repeats the suites on CI hardware.** A 3-vCPU `macos-26` runner fails tests that never
  fail on a 20-core Mac, so a local pass proves little. The temporary `flake-probe.yml` ran on every push to
  the branch, with `cancel-in-progress` concurrency and a 75-minute cap per job. Each job copied the setup
  steps, caches and environment of the matching `ci.yml` job, then looped the suite, counting failures and
  continuing past them:
  - teardown: `scripts/build.sh`, then `scripts/test-surface-teardown.py` 8 times with `--evidence` per
    iteration, in 4 shards;
  - core: `scripts/watchdog.sh swift test` 6 times in `agtermCore`, each run's output to its own log, in 4
    shards;
  - hosted: one `xcodebuild build-for-testing`, then `scripts/watchdog.sh xcodebuild test-without-building` 3
    times, in 2 shards.

  Each job printed the failure and summary lines of every run, ended with `failed runs: N of M`, and uploaded
  the full logs and evidence as an artifact, even after a failure.
  Probe run 43089788763 (42f2296f, before the core fixes) had one failure in 24 core runs (the DA double answer),
  none in 6 hosted runs, and one in 32 teardown iterations (`spam-8`). Three of its teardown jobs and two others
  show red only because the artifact upload failed during a GitHub Actions outage. Probe run 43109344255
  (3ec6ebfd, with the fixes) had no failure in 24 core runs, 6 hosted runs or 32 teardown iterations.
- **Local repetition with the suspected component swapped.** For example the DA test ran 24 times against the
  patched zmx and 24 times against the unpatched one.

## Core tests (`swift test` in `agtermCore`)

### `SessionHostServerTests.realHostStartupReplyAndClientlessControl`

- **Symptom.** `Expectation failed: controlMatches`, with
  `DA2 outcome="\u{1B}[?62;22c"` and `phase at emission=client-connected`.
- **Runs.** Job 125552897879 (2026-11-02); probe run 43089788763, job 130763495095 (core shard 2).
- **Cause, demonstrated.** A device-attributes (DA) query the shell wrote was answered twice. While no client has
  sent `Init`, the zmx daemon answers DA queries itself, and it also forwarded the query to an attach client that
  had connected but not yet sent `Init`. The session host's terminal behind that client answered it again. The
  probe script read one reply per phase, so the spare DA1 reply stayed in the tty input and phase 2 read it as
  its DA2 answer. A user can see the same race as stray `62;22c` at a prompt.
- **Evidence.** The CI message matches the mechanism: phase 2 received the DA1 reply. Locally, unpatched zmx
  failed 1 of 24 runs with the same message and patched zmx 0 of 24. The test's phase label only says whether
  `zmx list` counted a connected client when the query was written (`client-connected` in all 24 patched runs, 23
  of 24 unpatched runs, `clientless` in one); it does not show that `Init` was still pending, so it does not prove
  each run reached the race. With a failure rate near 1 in 24, 0 of 24 alone does not separate the two builds. The
  zmx unit test below pins the pre-`Init` relay deterministically, and `setup.sh` runs it before staging zmx.
- **Fix.** `scripts/zmx-patches/0006-single-da-answer.patch`: until a client sends `Init`, the daemon removes
  each DA query it answered from the output it forwards. A query split across two reads is forwarded unanswered,
  as before. Test: `a DA query the daemon answers is not forwarded until a client sent Init` in zmx's
  `loop.zig`.

### `SessionHostServerTests.paneAttachAfterTheCreatedCommandEndedStartsNoShell`

- **Symptom.** `the pane's attach to an ended command kept running`; the stall report shows `waitpid` 0 and
  `p_stat` SRUN after about 3 s, an empty `zmx list` and host log.
- **Runs.** 41408692761, 41899293201, 42295772822, 42929932710, 43071053355 (job 130698798091, #965), plus three
  local full-suite runs under load. In the third (master `d3be266d`, 2026-11-11), the pty held zmx's
  `created` line and screen reset but not the payload's message. The stall report's `ps`, taken after the last
  `waitpid` poll and after the report drained the pty, found the attach client exiting (`?Es`) and its child a
  zombie. That snapshot does not show where the 3 s went. It is consistent with the mechanism below and does not
  confirm it independently.
- **Cause, demonstrated.** On exit `zmx attach` restores the terminal with `tcsetattr(TCSAFLUSH)`
  (`main.zig:1678` at `ZMX_REV`). On macOS that call blocks until the pty master reads the queued output. The test
  never read the pane's pty during its 3 s wait, so a client with output still queued could not exit.
- **Evidence.** A standalone reproduction (`zmx attach` to `sleep 0.3; exit 1`) stayed stuck 5.0 s with the
  master unread, 3 runs of 3, and exited 0.013 to 0.028 s after the master was drained. With the master read
  continuously it exited in 0.32 to 0.34 s.
- **Fix.** The test drains the pty on every poll of its wait loop and prints what it read in the stall report.

### `ServerStreamsTests.anAskPastItsDeadlineIsNotOfferedAndAnAnswerPastItEndsIt`

- **Symptom.** `askOutcome(late.id)` is nil (`unknown ask`) where `.cancelled` was expected.
- **Runs.** Jobs 129979777312 and 130065434882 (macOS), 130144100011 (Linux, on a probe branch that logged
  registry activity).
- **Cause, demonstrated.** `AskRegistry.shared` keeps 32 finished results for the whole test process, oldest
  dropped first. Tests in other suites running in parallel retained enough results to evict this test's
  result before it read it.
- **Evidence.** The probe log shows the cancelled ask retained, evicted 4.4 s later after 56 other retains, and
  read 36 ms after that as `unknown ask`. 412485cf removed the largest burst (33 retains from one pick test) but
  23 other retains still fell in the same window.
- **Fix.** `AppStore` takes an `askRegistry` (default `.shared`), sessions retain into the registry their ask
  was opened with, `ServerActions` reads the store's registry, and the test harness gives each server its own.
  The app keeps `.shared`. Test: `aFinishedAskIsRetainedInTheStoresRegistryOnly`.

### `ServerStreamsTests.aProgramOpenedOfflineIsOfferedWithATokenThatAClaimMustCarry`

- **Symptom.** The slot owner is nil and the claim is refused (`job not claimable`).
- **Runs.** Job 130225880817.
- **Cause, inferred.** An offered overlay job has a 30 s launch window measured on the real clock
  (`OverlayJobs.launchWindow`); its expiry ends the job, removes the slot and refuses a claim, which matches both
  failed expectations. The test ran in the start-of-run burst when every main-actor suite queues and took 60.9 s
  in all. `presenterGeneration` 1 rules out a lost presenter. Not every caller that can end a job was checked, and
  the run did not record the job's final state, so expiry is consistent with the failure, not shown to cause it.
  The fix removes that exposure either way.
- **Fix.** `ServerActions.init` takes the `OverlayJobs`; the harness freezes its clock at construction and
  exposes that instant as `jobClock`. `offeredPagesAndJobsReadBackTheirWindows` now expects the deadline to equal
  `jobClock` plus the launch window, with no wall-clock bound.

### `ServerLifecycleTests.aShellThatExitsClosesItsSession`

- **Symptom.** `eventually { session == nil }` false after 8 s.
- **Runs.** Job 130060166304.
- **Cause, two candidates.** (a) A `zmx list` cut short under load marked the live session ended for good; this is
  a product bug, fixed in dd3ff080 after that job's base. (b) The real shell exit, the 1 s observer tick and a
  contended main actor did not fit in 8 s. The log cannot tell them apart.
- **Fix.** The wait is 60 s, and `#expect(!session.ended)` makes a repeat of (a) name itself.

### `SshConnectionPoolTests` cases waiting in `held()` on Linux

- **Symptom.** `Expectation failed: await held()` in `callersArrivingDuringAStartShareIt`,
  `closingDuringACheckStartsNothing`, `aConnectionThatFinishesStartingAfterCloseIsEndedAtOnce` and
  `aPooledStreamOpensOnceItsConnectionAnswersAndKeepsWhatWasSentMeanwhile`, all 29 s after they started.
- **Runs.** Job 131405859872 (run 43281980528).
- **Cause, demonstrated.** `held()` gave the stub runner 5 s of wall-clock time to park. Every Linux run starts with
  a scheduling stall in which trivial `@MainActor` tests report 22 to 33 s, passing runs included, so the deadline
  could expire before the stub runner parked.
- **Evidence.** Reproduced in `swift:6.3.2-noble` pinned to 4 CPUs (aarch64, CI is x86_64), unprivileged, full
  suite with zmx. A trivial `ControlEventRingTests` case was reported started at +1.7 s, entered its body at
  +20.5 s and ran in microseconds. A nonisolated probe reached the main actor in 0.7 s, but its continuation
  after `MainActor.run` resumed 14.2 s later. Inside the stall a main-actor 5 ms `Task.sleep` woke after 16.7 s
  and a `Task.yield` after 5.5 s; afterwards both took milliseconds. The CPUs were saturated until about 14 s.
  A backtrace at 12 s showed concurrency worker threads held by synchronous test waits: six in
  `HudHelperTests.Run.waitForExit` (`Thread.sleep`) and one in `OverlayRunJobTests.FakeOrigin.frames`
  (`DispatchSemaphore.wait`). Skipping those two suites shortened the stall without removing it; one run per
  configuration was too noisy to size their share. The stall's full cause is not established: neither the worker
  count nor the number of queued tasks was measured.
- **Fix.** `held()` gives up after 1000 `Task.yield` retries instead of a deadline, so a stall slows it but cannot
  expire it. The startup stall itself remains.

### Linux test process killed by SIGPIPE

- **Symptom.** The Linux core tests job ends with signal 13 about 6 s after `swift test` starts, before any test
  reports a result.
- **Runs.** Job 130311162034 (run 42955991894).
- **Cause, unresolved.** The writer was not identified. Shipped code writes sockets without raising SIGPIPE; the
  unguarded writes were in test stubs. `StubServer` wrote its reply even after the client hung up.
- **Fix.** `StubServer` and `ScriptedStubServer` write through `UnixSocket.write` (`MSG_NOSIGNAL` on Linux), and
  `StubServer` sends no reply to a request cut off before its newline. If it recurs, a SIGPIPE handler that
  prints a backtrace names the writer.

### Linux watchdog hang in `OverlayRunJobTests.aCancelFromTheAppEndsTheProgramCanceled`

- **Symptom.** `scripts/watchdog.sh` kills the Linux core tests after 600 s.
- **Runs.** Job 129507459681 (run 42718862438, before #949 merged).
- **Cause, demonstrated.** The overlay job helper waited for its program's process group with `kill(-pid, 0)`. A
  zombie of that group under the container's PID 1 (`tail -f /dev/null`, which never reaps) kept the call
  succeeding forever.
- **Fix.** Already on master in #949 (b8a96b1b): `OverlayRunJob.onlyZombies` treats a group of zombies as ended.

### macOS watchdog hang with no test started

- **Symptom.** The watchdog fires while the log's last line is a compile step.
- **Runs.** Job 126194053249 (run 41715375849).
- **Cause, demonstrated.** The watchdog wrapped the compile too, which used up its 600 s.
- **Fix.** Already on master in 01993f65: CI builds the tests in a step of its own before the watched
  `swift test --enable-code-coverage`, which reuses that build.

### Unit tests log ends without naming a failing test

- **Symptom.** A red `Unit tests` job whose log, read through `gh run view --log` or `--log-failed`, stops
  mid-run with no failure line and no summary.
- **Cause, demonstrated.** Two parameterized ask cases printed a 65 KB argument line, and `gh run view` stops at
  it: for job 129484718181 it returns 16334 lines and no `✘`, while the raw job log
  (`gh api repos/umputun/agterm/actions/jobs/<id>/logs --allow-escape-sequences`) has 24189 lines with the
  failures and the summary. Read the raw job log first.
- **Fix.** Already on master in 4ebd6e52 (#966), which shortened those lines.

### Pre-merge runs of the `linux-remote-server` branch (#949)

- **Runs.** Jobs 129484718181, 129507459737, 129526370375 and 129569809198 (runs 42712267063, 42718862438,
  42724427691, 42737362694), four pushes within three hours on 2026-11-09, all in `AgtermServerTests`, the
  module that PR added.
- **`ServerStreamsTests` page and presenter tests** (the last three jobs). 27 to 46 issues per run, across
  `everyPageKindOpensInEveryLinkMode`, `aPageClosedOnThePresenterAfterItsChannelEndedIsEnded` and their
  neighbours, with `page not claimable` and `end of stream`; the runs took 111 to 116 s.
  Cause unresolved. [Inference] A page claim expiring on the real clock (`AppStore.pageClaimWindow`,
  enforced by `ServerStreams.schedulePageClaimExpiry`) would produce these messages, and so would a defect the
  branch fixed before the merge. The frozen job clock does not cover page claims.
- **`ServerLifecycleTests.aFishPaneLoadsTheShellIntegration`** (job 129484718181), at
  `ServerLifecycleTests.swift:191`: after 15 s the screen ends at the typed command with no output and no new
  prompt, so fish had not finished the command. One occurrence; cause unresolved. The test is unchanged since
  #949. Start here if it recurs.
- **Linux job 130225880873** (run 42929932710, branch `subagent-status-owner`) failed to compile
  `ClaudeStatusHookTests.swift` (`posix_openpt` not in scope). The branch fixed it before #959 merged; its final
  run 42940587374 passed the Linux job.

## App-hosted tests (`agtermTests`)

### `TextPageRenderingTests.testANearCapFileRendersInBoundedTime`

- **Symptom.** `XCTAssertLessThan failed: ("11.543139667 seconds") is not less than ("10.0 seconds") - big.diff`.
- **Runs.** 42883406544.
- **Cause, unresolved at stage level.** The timer covers writing and opening the file, escaping, WebContent
  startup, rendering and polling, and no stage was measured on the runner.
- **Fix.** The per-file bound and the page wait are 30 s, a coarse end-to-end ceiling for a pathological slowdown
  rather than a latency target.

### `ControlServerRemotePageTests.testATextActionOnAPageThatIsNotTextAnswersTheLocalRefusalAndAdvancesNoSequence`

- **Symptom.** `XCTAssertEqual failed: ("5") is not equal to ("1")` on the state frame count.
- **Runs.** 43224720127 (PR #978).
- **Cause, demonstrated.** The page is a URL on the restricted port 9. Its own load reports (loading, loading,
  failed `Not allowed to use restricted network port`, all at sequence 5) arrived after the baseline count;
  reproduced locally with the frames printed. The refused text actions sent none.
- **Fix.** The test waits for the load to end `failed` before it takes the baseline.

### `ControlServerRemotePageTests.testTextCommandsOnAReplicaAnswerAsLocallyAndReachTheOrigin`

- **Symptom.** `XCTAssertEqual failed: ("nil") is not equal to ("Optional("1 of 1")")`, then `the origin is told`
  times out.
- **Runs.** Local only, once in about 70 class runs.
- **Cause, demonstrated.** `text.js` posted a diff page's first changes report, and a seeded search's first
  report, before `ready`. A caller waiting for `textChanges` could step between the two messages while
  `TextPageBridge` still held its document pending, which answers `page not loaded`. A script polling `tree`
  for `text.changes` had the same window.
- **Fix.** The page holds the counts it reports during setup and sends them after `ready`.
  `TextPageRenderingTests` pins the message order for a diff with changes, one without, and a seeded search.

### Three earlier hosted failures, already fixed on master

- `HtmlOverlayViewTests` line 48 read the page title before it arrived; fixed in #949.
- `testTheBarFitsANarrowPageFollowingAndPaused` overflowed when the runner showed a scroll bar; fixed in b7884db7.
- `testAWrappedFollowingLogStaysAtItsEndWhenItNarrows` waited for a width a 17 px runner scroll bar never allows;
  fixed in the #934 squash.

A WebContent crash appears in passing hosted runs as well as failing ones and was not linked to any failure
above. That it follows the drag and paste tests releasing their named pasteboards is an inference.

## Release build job: surface teardown smoke

### `spam-8` stalls on `session new` (case retired)

- **Symptom.** `scripts/test-surface-teardown.py`, eight title producers: one `agtermctl session new`, `tree` or
  `session close` gets no reply, usually with two to seven producers running.
- **Runs.** 40747601941, 41121304109, 41408692761, 41424943333, 41481808137, 41525711638, 41899293201,
  41719380918, 41905113022, 42292892846, 42302198754, 42471836035, 42663853160, 42750078737, 42763210167,
  42906633733, 42881904041, 42883406544, 43075160902; probe run 43089788763 (teardown shard 3).
- **Cause, unresolved.** Every capture shows the runner saturated: the app at 170 to 183% CPU and the producers
  near 100% on 3 vCPUs. In the probe, the third `session new` (two producers running) took 3 to 18 s in 7 of 8
  runs; in the other it got no answer within 125 s, after the second took 16.7 s, at `vm.loadavg` 218 with even
  `ps` timing out after 10 s. At that capture `ps` showed the app's main thread at 0.2% CPU, which does not show
  where the earlier seconds went; which code consumed them is not established.
  Stack captures (`sample`, `spindump`) failed or came back unsymbolicated in every run.
- **Ruled out.** libghostty's read thread releases the terminal lock before its blocking app-mailbox push, so the
  stall is not that deadlock. `TitleAdmission` already drops a title identical to one still queued.
- **Fix: none; the case is retired.** The script runs one busy producer and eight idle surfaces and fails only on
  a call unanswered for 60 s. The other two cases stayed under 0.61 s in every probe run. The two teardown defects
  spam-8 guarded, the original deadlock on a full app mailbox and the quadratic drain of the deferred backlog
  fixed in #844, stay covered by the teardown patch's Zig tests. `setup.sh` now runs them after every libghostty
  build and before staging (85 tests), among them a producer blocked on the full app mailbox and teardown while
  another surface keeps producing; that last test now waits until its producer has filled the mailbox. Those
  tests do not cover what failed here: most stalls hit `session new` or `tree` before any close.
  The stall stays open in `docs/backlog/control-calls-stall-under-title-flood-on-ci.md`.

## Still open

Causes not found, left as backlog items with their capture steps:

- `docs/backlog/hosted-tests-hang-in-ci-until-job-timeout.md`
- `docs/backlog/fish-seam-payload-test-times-out-under-load.md`
- `docs/backlog/exit-capture-test-misses-a-120-ms-listing-in-full-runs.md`
- `docs/backlog/session-host-fixture-start-stalls-before-pidfile.md`
- `docs/backlog/control-calls-stall-under-title-flood-on-ci.md`, the `spam-8` stall, which the retired case no
  longer exercises

## CI speed changes in the same PR

- The app build's helper phase (`project.yml`) compiles `agtermctl` and `agterm-session-host` after the app,
  serially: 211 s of the hosted job's 418 s build step and 147 s of the Release job's 364 s in one measured run.
  `scripts/with-helper-prebuild.sh` starts them before the app compile in both jobs. The phase still runs and stays
  authoritative. A signalled `swift build` leaves its compiler jobs running, so the script removes them on any
  exit other than a completed prebuild.
- The plain fish login shell step runs `test-without-building` instead of `xcodebuild test`, which rebuilt the
  app for one test.
