---
worth: yes
added: 2026-11-11
---
# agtermCore Unit tests fail intermittently in CI, test unknown

The `Unit tests` job (`swift test` under `scripts/watchdog.sh`) failed in five runs over two days, on unrelated
branches:

- 42796100292 (feat/session-go-ordinal, 2026-11-10)
- 42881904041 (flat-flagged-selection-pill, 2026-11-10)
- 42883406544 (follower-poll-cpu, 2026-11-10)
- 42929932710 (subagent-status-owner, 2026-11-11)
- 43071053355 (docs-command-runs-through-bash, PR #965, 2026-11-11)

Four runs on linux-remote-server (42712267063, 42718862438, 42724427691, 42737362694) also failed there and
were not examined.

None of these logs names the failing test. Two parameterized ask cases printed a 65 KB argument line, and the
Actions log dropped everything after it, failures and the summary included. 4ebd6e52 (#966) shortened those
lines, and the next CI run logged 6078 passed tests and the summary. Each failed run uploaded a `test-hang`
artifact under 1 KB, so whether the step crashed or the watchdog fired is not established.

The next red `Unit tests` run is where to start: its log now reaches the failure.
