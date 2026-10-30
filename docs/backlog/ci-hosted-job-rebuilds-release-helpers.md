---
worth: maybe
where: project.yml
added: 2026-10-30
---
# CI's hosted job spends about 6 minutes before its tests start

After #845 split `Build app`, the `App-hosted tests` job sets the CI critical path. On run 41128089118 it
took 609s: the `Application-hosted unit tests` step was 554s, of which about 184s ran the 1546 tests,
leaving about 370s for setup, building and test-harness overhead. The app target's "Bundle helper
executables" phase runs `swift build -c release` for `agtermctl` and `agterm-session-host` in every
configuration, Debug included, and on a fresh runner nothing is cached for it. That phase took about
105s inside the Release build; its cost in the hosted job has not been measured separately.

Possible levers, none decided: build the helpers in debug configuration for Debug builds, which changes
what the hosted tests exercise; or cache `agtermCore/.build` between runs, which ties correctness to a
cache key. Either needs a measured CI run to show it saves more than it costs.
