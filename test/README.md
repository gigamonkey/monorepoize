# Tests

There is no CI and no test framework here — these are self-contained bash
scripts you run by hand, matching how the tools themselves are run. Each script
creates its own throwaway repos under a `mktemp` directory, uses an **isolated
git config** (it never reads or writes your real `~/.gitconfig` or commit
identity — see `lib.sh`), cleans up on exit, and exits with the number of failed
checks (`0` = all passed).

```
./test/subtree-merge.sh
./test/subtree-merge-edge-cases.sh
```

## What they cover

These validate the git merge primitive that the continuous-upstream-sync plan
(`plans/continuous-upstream-sync.md`) depends on: **`git merge -X subtree=<name>`**
for folding new upstream commits into a monorepo's `<name>/` subdirectory when
*both* the upstream repo and the monorepo section have diverged. The tricky part
is the shape mismatch — the monorepo keeps content under `<name>/` while the
upstream mirror keeps it at the repo root — so these check that the subtree
strategy reconciles a prefixed `ours` against a root-level base/theirs.

- `subtree-merge.sh` — core scenarios: clean concurrent divergence; an
  overlapping conflict that is resolved once and then *not* replayed on the next
  sync; an upstream range containing a merge commit; baseline establishment via
  `git merge -s ours` (the migration path); and the `extract` SHA-preservation
  invariant.

- `subtree-merge-edge-cases.sh` — multi-repo confinement (syncing one repo
  leaves a sibling subdir byte-identical), upstream deletions, and the
  `git merge-tree --write-tree` plumbing fallback (skipped automatically on git
  < 2.38).

Both build the monorepo with the real `./build`, so they also smoke-test that
path. They exercise the *primitive*, not a `update --merge` command — that
command does not exist yet; these are the guard rails for implementing it.

## Requirements

`bash` and `git`. The `merge-tree --write-tree` portion needs git ≥ 2.38 and is
skipped (not failed) on older git. Scripts avoid GNU-only flags so they run on
both macOS and Linux.
