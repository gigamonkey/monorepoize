# Next steps

As of 2026-07-13 there are no active plans. The continuous-upstream-sync work
is implemented and merged (see `done/continuous-upstream-sync.md`): `update` now
has a merge mode (`--merge`, or `build`/`add --sync=merge`) that subtree-merges
upstream changes into a monorepo subdirectory the monorepo also edits, tracked
via `.monorepoize/modes` and `.monorepoize/synced`. Replay mode is unchanged
except that a conflicted sync no longer strands commits.

## Open follow-ups (optional, nothing blocking)

- **`--dry-run` conflict prediction.** Dry-run currently reports only how many
  commits are pending, not whether merge mode will conflict. If a preview of
  conflicts is wanted, add the `git merge-tree --write-tree` path sketched in
  `done/continuous-upstream-sync.md` (guard on git ≥ 2.38; skip on older git).

- **Monorepo → upstream push-back.** Deliberately out of scope but not
  precluded: pushing monorepo-side changes in a `name/` subdir back to the
  original repo via `git subtree split --prefix=name` + push. The current design
  keeps this feasible (SHA-preserving mirror, real upstream ancestry, no
  squash/rewrite); see the Non-goals section of the done plan for the
  constraints to preserve if this is ever built.

## Reminder

Run the `test/` suite (`subtree-merge.sh`, `subtree-merge-edge-cases.sh`,
`update-merge.sh`) after touching `update`, `monorepo.sh`, `build`, or `add`.
