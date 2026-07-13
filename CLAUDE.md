# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A set of bash scripts that combine multiple git repos into one monorepo while
preserving full history — every original commit keeps its original SHA — and
that maintain, update, and invert that combination. There is no build step, no
test suite, and no CI; the scripts are run directly (`./build`, `./update`,
etc.). The README documents user-facing behavior in detail and should be kept
in sync when changing a script's interface.

## Core model (what every script relies on)

When a source repo `foo` is incorporated into a monorepo:

- All of `foo`'s branches and tags are fetched **unrewritten** into the
  monorepo as `foo/<branch>` and `foo/<tag>` (done in `incorporate` via a
  temporary remote with `+refs/heads/*:refs/heads/foo/*` fetch refspecs).

- `foo`'s default-branch content is then "pushed down" into a `foo/`
  subdirectory and merged into the monorepo's default branch
  (`pushdown_one`: `git mv` everything into a temp dir, rename it to `foo/`,
  merge with `--allow-unrelated-histories -X no-renames`).

- The source URL is recorded as a `name url` line in the committed
  `.monorepoize/sources` file (`stage_source`).

Everything else is derived from these invariants: `extract` recovers an
original repo byte-for-byte by fetching `foo/*` refs with the prefix stripped;
`update` fetches new upstream commits onto `foo/<branch>` (same SHAs) and
replays them onto the `foo/` subdir with `git format-patch | git am
--directory=foo` (linear history only — ranges containing merges are
refused/skipped); `constituent_names` discovers repo names from the `<name>/`
branch namespaces. Don't break the SHA-preservation or ref-naming scheme —
extraction and updating both depend on them.

## Layout

- `monorepo.sh` — shared function library sourced by everything else
  (`incorporate`, `pushdown`, `pushdown_one`, `constituent_names`,
  `stage_source`, ...). Not run directly.

- `build`, `add`, `extract`, `update`, `pushdown`, `retire` — the commands;
  each has `--help` or a header comment. `retire` (archive/delete the original
  GitHub repos via `gh`) is the only one that touches the GitHub API; it
  refuses to retire a repo whose upstream tip isn't already in the monorepo.

- Helpers: `slow_push` (push refs one at a time from stdin, for repos too big
  to push in one pack), `mirror.sh` (mass `git clone --mirror` from a URL
  list), `repos.py` (list a GitHub org's repo SSH URLs via GraphQL; needs
  `GITHUB_TOKEN`; deps via `pipenv install`).

## Gotchas

- `monorepo.sh` sets `set -ex` at the top, so sourcing it turns on command
  tracing and changes error behavior. `extract` and `update` deliberately run
  `set +x; set -euo pipefail` right after sourcing it — do the same in any new
  script that sources it and wants quiet output.

- The `sleep 1` calls in `monorepo.sh` are intentional: they keep commit
  timestamps distinct/ordered during fast scripted commit sequences.

- `init_monorepo` sets `core.ignorecase false` so exact-case filenames survive
  building on macOS and using on Linux; `extract` likewise matches the `DIR`
  argument case-insensitively against constituent names.

- `*.repos` files, `*.json` files, and built monorepo directories in the repo
  root (e.g. `berkeley-high-cs-2024-25/`, `tmp/`) are the user's local working
  data, deliberately untracked. Don't commit or delete them.

- Scripts target both macOS and Linux bash; avoid GNU-only flags.

## Testing changes

There are no automated tests. Verify changes end-to-end in a scratch
directory: create a couple of throwaway source repos, list their paths in a
`name.repos` file, run `./build name.repos`, then exercise `add`/`update`/
`extract` against the result and check refs (`git branch -a`, `git tag`) and
that extracted SHAs match the originals.
