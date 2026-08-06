# Contributing a recipe

Send a workflow you actually run. A script written for the collection rather than for your own day is the wrong kind of submission: if it has not driven your own sessions for a while, it has not been tested where it matters.

Open a pull request against `master` with the recipe directory, its README, and the index row, all in one change.

These rules cover recipes. The project-wide rules for everything else are in [CONTRIBUTING.md](../CONTRIBUTING.md) at the repository root.

## Layout

One directory per recipe, kebab-case, named after what the recipe does rather than after its script (`park-and-resume`, not `agt-park`). It holds a `README.md` and the scripts, nothing else.

Name scripts by their language, because the extension decides what CI does with them:

- `.sh` is POSIX or bash. CI runs `shellcheck` over every one, and it has to be clean.
- `.zsh` is zsh. CI parses every one with `zsh -n`, so a syntax error is caught, but shellcheck cannot read zsh and nothing lints these. A parse is not a lint, so run `zsh -n` yourself and read the script over before sending.
- `.py` is Python 3. CI runs `ruff check` over every one, and it has to be clean. Say which Python version the recipe needs in *Requirements*, the same as any other external tool, and depend on the standard library unless the recipe genuinely cannot.

A recipe in another language is welcome, but say so in the pull request: nothing lints an extension CI does not know, and a recipe that arrives ungated is one the reader has to trust entirely on review.

Every script carries a shebang. A script whose *Setup* tells the reader to execute it is committed with the executable bit set; a shell function the reader pastes into `~/.zshrc` is committed without it, and its *Setup* says to add it to the shell config, never to run it. A perfectly good script committed non-executable passes every check and then fails on the reader's machine with "permission denied".

## The README template

Six headings, exactly these, in this order. CI checks that all six are present:

```markdown
# <Title>

<one-line summary>

<byline, when porting someone else's work>

## What it does
## Requirements
## Setup
## Usage
## How it works
## Limits
```

**Requirements** names the minimum agterm version the recipe needs, written as "X or later", plus any external tool it calls. Work out that minimum from the commands and flags the recipe uses rather than naming the version you happen to run, and say in the same line what shipped in it. The version is the contract: a recipe that breaks against a later agterm is fixed when someone reports it, and dropped if it stays broken and nobody claims it.

**Setup** is the exact steps, including where the file goes and how it is invoked or sourced. Anything machine-specific is a variable the reader sets, named and explained here.

**How it works** explains the mechanism, not the code line by line. The gotcha that cost you an hour belongs here.

**Limits** states destructive behavior in plain words. If the recipe closes sessions, deletes workspaces, or kills a running shell, say so in a sentence the reader cannot skim past. "Parking a project closes its shells" is that sentence; "state is not preserved" is not. Known caveats that are not destructive go here too.

When you are porting someone else's work, credit him by name with a link to his GitHub profile and to wherever you found it, as a byline under the summary line.

## Index row

Add a row to the table in [README.md](README.md) in the same pull request:

| recipe | what it does | needs |
|---|---|---|
| [project-switcher](project-switcher/) | show only one project's workspaces | 0.18.0, jq |

CI compares the directory set against the index in both directions, so a directory with no row fails, and a row pointing at a directory that does not exist fails too. The check matches the link by its trailing slash, so keep it.

## Rules for the scripts

Call the CLI through an overridable variable, `AGTERMCTL=${AGTERMCTL:-agtermctl}`, so a reader whose binary sits somewhere unusual can point at it without editing the script. A hardcoded path works on your machine and nowhere else. The exception is a recipe made of `keymap.conf` lines: those are copied into the reader's own config, which has no variable indirection, so they use bare command names.

Nothing personal reaches a committed file. No absolute paths under a home directory, no host names, IP addresses, user names, or internal project and service names carried over from wherever the script came from. Replace each with a variable the reader sets, documented in *Setup*, with a neutral default. This applies to comments and example output as much as to code.

Keep a recipe standing on its own. If two recipes share a gotcha, both explain it, rather than one pointing at the other.

## What review looks like

Every recipe is read before it is merged, for three things: whether its commands, flags, and JSON paths are right against the current control API; what it destroys, and whether the README says so; and whether anything private came along with it. Nothing is executed during review, because a recipe run against the default socket runs against the reviewer's live terminal with real work in it.

Expect questions on all three. A recipe that is correct but silent about closing sessions comes back for the *Limits* sentence, not as a rejection.

## License

Recipes ship under the MIT license that covers the rest of the repository. Send only work you are free to license that way, and say where a ported script came from.
