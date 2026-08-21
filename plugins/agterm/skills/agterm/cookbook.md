# agterm cookbook

The cookbook is a directory of installable `agtermctl` workflows kept in the agterm repository, one
directory per recipe. It is NOT bundled with this skill, so unless the session sits in an agterm
checkout it has to be fetched.

Two uses, same acquisition path:

- **Install a recipe** the user asked for.
- **Read one as reference** when a workflow is hard to compose — a recipe is a working solution to a
  real sequencing problem, so follow how it drives the commands instead of inventing a sequence.
  Nothing is installed in this case.

## Where it is

`umputun/agterm`, directory `cookbook/`, browsable at
`https://github.com/umputun/agterm/tree/master/cookbook`. The index is `cookbook/README.md`.

Never recite recipe names from memory. Recipes are added and changed independently of this skill, so
a fetched index is the only current list; anything not in it does not exist. Never assemble a recipe
URL from a name — the only URL you may fetch for a recipe is one the index linked.

Use the agent's own URL retrieval for the single-file fetches. Materializing a directory needs a shell
download, which is one archive fetch, not one per file — ask before it.

## Listing

Fetch `https://raw.githubusercontent.com/umputun/agterm/master/cookbook/README.md` and report it as it
stands. It groups recipes by what they
are for and gives each one's minimum agterm version and its dependencies. Answer "what can I install"
from that fetch alone — no recipe directory is needed to list.

## Acquiring one

Anything that ends in files on disk pins first, so the index you read and the payload you copy come
from the same tree. Every URL below is derivable without knowing any recipe name — `<sha>` is the one
you resolved in step 1, and nothing else is ever interpolated:

1. Resolve `master` to one commit SHA:
   `https://api.github.com/repos/umputun/agterm/commits/master` (the `sha` field).
2. Fetch the index at that SHA:
   `https://raw.githubusercontent.com/umputun/agterm/<sha>/cookbook/README.md`.
3. Resolve the requested name only against links in that index. A name that does not appear there is
   not a recipe; say so rather than guessing. Check that the linked target is a direct child of
   `cookbook/` — anything reaching outside it is not a recipe either.
4. Materialize from the same SHA: download the pinned repository snapshot
   `https://github.com/umputun/agterm/archive/<sha>.tar.gz` into a temp dir and take the one directory
   from it. This is the whole repo at that commit, NOT a per-recipe URL — never construct one of those.
5. Read `Requirements` and `Setup` from what was acquired, never from memory of the index row.
6. Read the payload itself before copying or binding it. A script copied unread is a script the user
   runs on the next keypress.

A local checkout is used instead only when the session sits in an actual agterm repository: a git
repo whose root holds `cookbook/` alongside `agtermCore/` and `project.yml`, not merely a directory
containing `cookbook/`. State the path and whether the tree is dirty before using anything out of it.
A dirty tree is not a blocker: testing a local edit is a normal case.

## Requirements

Every recipe states a minimum agterm version. `agtermctl version` reports the version of the app
serving the socket — but **address the socket explicitly**, because `agtermctl` never reads
`AGTERM_SOCKET` and a bare invocation resolves the default path, which may be a DIFFERENT app than the
one that spawned this session:

- For an interactive check from a session shell, use
  `agtermctl version --socket "$AGTERM_SOCKET"`.
- Inside an automated preflight launched from the keymap or the palette, use
  `agtermctl version --json --socket "$AGT_SOCKET"` and extract only `.result.app.version` with the
  JSON parser the recipe already requires. Never compare the human output: it also includes the client
  path and may include a parenthesized commit.
- Fall back to the default socket only when neither variable is set. An automated check still uses
  `agtermctl version --json` and extracts only `.result.app.version`.

`$TERM_PROGRAM_VERSION` carries the same number in a session shell, and is the fallback on a release
too old to have the `version` command, along with the About panel. It is ABSENT in a keymap- or
palette-launched process, which inherits the app's launch environment rather than a terminal
surface's — so a recipe preflight cannot use it.

Check the recipe's other requirements too (`jq`, `fzf`, `python3`, a particular shell, a named agent)
and report what is missing before installing rather than after.

## Installing

Recipes are third-party scripts that run on the user's machine against the user's own sessions, and
several close sessions or delete workspaces. Show what a recipe does and what it needs before
installing it. Follow the recipe's own `Setup`; never invent a procedure it does not describe.

Every file an install touches is merged, never replaced:

- Read the file first and show the exact line or block to be added.
- Add only if absent.
- Stop and ask when the command name already exists with different content, or the chord is already
  taken. Do not pick a different chord unprompted.
- Preserve unrelated lines and comments. This covers `keymap.conf`, shell rc files, and agent settings
  alike.
- Never overwrite an existing script payload without comparing it and putting the difference to the
  user.

Do not run an acquired script as part of installing it.

Applying a new keymap entry needs `agtermctl keymap reload` (or File ▸ Reload Keymap); say so.

## Contributing

`cookbook/CONTRIBUTING.md` in the repository holds the rules for adding a recipe. Fetch it when asked;
do not summarize them from memory.
