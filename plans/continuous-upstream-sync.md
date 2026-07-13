# Continuous upstream sync into a live monorepo section

## Goal

Today `update` can fold new upstream commits back into a monorepo, but it was
designed for the *archive* case: the monorepo itself never touches the
incorporated `name/` subdirectory, so folding upstream in is a clean, linear
replay. We want to support the *live* case: after a repo is incorporated,
**both** the original repo **and** the corresponding `name/` section of the
monorepo keep receiving commits, and we still want to keep pulling upstream
changes in indefinitely, resolving overlaps like any normal merge.

This plan describes how to augment the tooling to do that without breaking the
SHA-preservation and ref-naming invariants that `extract` and `retire` depend
on.

## Recap of the current model

When repo `foo` is incorporated (`incorporate` + `pushdown_one` in
`monorepo.sh`):

- `foo`'s branches/tags are fetched unrewritten into `foo/<branch>` /
  `foo/<tag>` — a **pure-upstream mirror** with original SHAs. `extract`,
  `retire`, and `constituent_names` all rely on this.
- `foo/<default>`'s content is moved into a `foo/` subdirectory and merged into
  the monorepo default branch via `git merge --allow-unrelated-histories`. This
  merge makes the original upstream tip an **ancestor of `main`**.
- The source URL is recorded in `.monorepoize/sources`.

`update` then, per repo:

1. Force-fetches upstream onto `foo/<branch>` (mirror advances to the new tip).
2. Computes `oldtip..newtip` and replays *just those commits* onto the `foo/`
   subdir of `main` with `git format-patch | git am --3way --directory=foo`.

Step 2 is a **rebase/replay** model, not a merge model. That is the root of the
problems below.

## Why the current `update` breaks when the monorepo side also changes

1. **Replay assumes `main:foo/` equals the upstream content at `oldtip`.**
   `format-patch oldtip..newtip` produces patches against *upstream* trees. If
   the monorepo has independently edited files under `foo/`, those patches no
   longer apply against the diverged subdir and `am` conflicts — even on hunks
   that a real 3-way merge would resolve automatically.

2. **Conflicts are re-hit forever.** `am` applies each patch independently and
   records no merge relationship. A one-time overlap between a monorepo edit and
   an upstream edit conflicts on *this* update and on *every future* update,
   because nothing remembers that it was already reconciled. A merge records the
   resolution once, in the merge commit; replay cannot.

3. **A conflict silently strands commits (latent bug).** `oldtip` is read from
   the mirror ref *after* it has been force-fetched to `newtip`. On conflict,
   `update` does `git am --abort` and leaves `main` unchanged but the mirror at
   `newtip`. The next run computes `oldtip == newtip` → reports **"up to
   date"** and never applies those commits. The integrated position is
   conflated with the mirror position; they must be tracked separately.

4. **Upstream merge commits are refused outright.** `update` skips/dies when
   `oldtip..newtip` contains any merge (`format-patch`/`am` can't reproduce
   merges). A *live* upstream repo almost always accumulates merge commits (PR
   merges), so replay is effectively unusable for an actively developed source.

5. **No merge base means no 3-way anything.** There is no recorded common
   ancestor tying `main:foo/` to the upstream history, so genuine concurrent
   development can never be reconciled correctly.

## Design: merge-based (subtree) sync

Switch the integration step from *replay* to a *recorded subtree merge*, while
keeping the pure-upstream mirror branch exactly as-is.

### What stays the same

- `foo/<branch>` / `foo/<tag>` remain the byte-for-byte upstream mirror. The
  fetch in step 1 is unchanged. `extract`, `retire`, `constituent_names`,
  `.monorepoize/sources` are all untouched.

### What changes

Replace step 2 with a subtree merge of the mirror tip into `main` under `foo/`:

- The merge's **base** is the last upstream commit that was integrated; **ours**
  is `main` (monorepo edits under `foo/` and everything else); **theirs** is the
  new mirror tip `foo/<branch>`, shifted into the `foo/` prefix.
- Git performs a normal 3-way merge of the `foo/` subtree. Conflicts appear only
  where both sides touched the same lines, are resolved in the working tree the
  normal way, and are **recorded in the merge commit** so they never re-surface.
- The merge commit has the upstream tip as a parent, so the upstream tip becomes
  an ancestor of `main` and is automatically the base for the *next* sync.
- Because we merge the upstream *tip* (not a linear patch range), upstream merge
  commits come along as ancestors for free — **the linear-history restriction
  disappears**.

### Establishing and tracking the merge base

Do not re-derive the base from ancestry alone (that is what makes the current
code fragile). Record it explicitly and use ancestry as the mechanism:

- Add a per-repo marker, e.g. `.monorepoize/synced` with `name upstream-sha`
  lines (or a `synced` column alongside `.monorepoize/sources`), updated on each
  successful sync to the upstream tip just integrated. This is the source of
  truth for "how far upstream we have merged," decoupled from the mirror ref and
  from `main`'s shape. It also lets `--dry-run` and `--all` report accurately and
  kills failure mode #3.
- **Fresh incorporation** already leaves the original upstream tip as an ancestor
  of `main` (the `--allow-unrelated-histories` merge in `pushdown_one`), so the
  first sync's base is correct with no extra work; record that tip as the initial
  `synced` value in `add`/`build`.
- **Migrating an existing monorepo** that was previously updated via `am`: `main`
  is *not* an ancestor-descendant of the current mirror tip, so a naive first
  subtree merge would try to re-merge everything already replayed. Establish a
  clean baseline once with `git merge -s ours <foo/branch tip>`: this records the
  current mirror tip as merged **without changing `main`'s tree**, sets the base
  for all future syncs, and is content-safe (if the subdir was never touched, the
  trees already match; if it was, `-s ours` correctly keeps the monorepo's
  version and only future upstream deltas get merged). Expose this as an explicit
  step (e.g. `update --establish-baseline NAME`, or automatic on first `--merge`
  when divergence is detected).

### Merge mechanics (to validate during implementation)

Subtree merges have several equivalent incantations with real reliability
differences; pick one in a spike and lock it in:

- `git subtree merge --prefix=foo <mirror-tip>` — highest level; git-subtree is a
  contrib script but ships with standard git. Verify it is present and that it
  does *not* rewrite our mirror or inject squash metadata we don't want.
- `git merge -s recursive -X subtree=foo <mirror-tip>` — relies on the recursive
  strategy's prefix-shift; robust when the prefix is given explicitly (don't rely
  on auto-detection).
- `git merge-tree --write-tree` (git ≥ 2.38) three-way on the `foo/` subtree,
  then commit the result manually with the upstream tip as a second parent — the
  most explicit and scriptable, no working-tree churn, but requires newer git and
  more plumbing.

Recommendation: prototype the recursive `-X subtree=foo` form first (fewest
dependencies), fall back to explicit `merge-tree` plumbing if prefix detection
misbehaves. Note that `pushdown_one`'s `-X no-renames` is specific to the
initial unrelated-history merge and should **not** be carried into sync merges,
where rename detection is desirable.

## Sync mode: opt-in per repo, backward compatible

Merge-based and replay-based integration produce different history shapes (merge
commits with the upstream DAG as ancestors vs. flat replayed commits), and pure
archives may prefer the flat shape. So:

- Record a per-repo sync mode in `.monorepoize/` (default `replay` for existing
  monorepos → no behavior change; `merge` for repos opted in).
- `add`/`build` gain a flag (e.g. `--sync=merge`) to mark a repo as actively
  tracked from the start, recording the initial `synced` tip.
- `update` reads the mode and dispatches; `--merge` on the command line switches
  a repo to merge mode (triggering baseline establishment) and updates the
  marker. `--all` respects each repo's recorded mode.

## Conflict UX

Merge-based sync makes conflicts first-class and recoverable, unlike the current
abort-and-strand behavior:

- On conflict, stop with the merge in progress (or a clearly reported detached
  state), tell the user which repo and which paths conflicted, and let them
  resolve + `git commit` / `--continue`. The mirror ref and the `synced` marker
  are only advanced on success, so a failed sync is re-runnable and never claims
  "up to date."
- In `--all`, a conflicting repo is reported and skipped without corrupting
  state; the run continues with the others.

## Extract / retire implications

- `extract` is unaffected: it still fetches the pure-upstream `foo/*` mirror and
  returns the original repo byte-for-byte. Note explicitly that this yields the
  *upstream* lineage, **not** the monorepo's evolved `foo/` subdir. If we ever
  want to extract the monorepo's current version of a subdir as standalone
  history, that is a *subtree split* (`git subtree split --prefix=foo`) — call it
  out as a separate future capability, not part of this plan.
- `retire`'s "is the upstream tip already in the monorepo?" check keeps working,
  and actually becomes more meaningful: with merge-based sync the upstream tip is
  a true ancestor of `main`.

## Non-goals (call out explicitly)

- **Monorepo → upstream push-back (true bidirectional).** This plan is one-way:
  pull upstream into a possibly-diverged monorepo section. Pushing monorepo-side
  changes back out to the original repo (subtree split + push) is a separate,
  larger effort and is out of scope. Mention it as a possible future direction.
- Rewriting history or changing the mirror/ref-naming scheme.

## Implementation steps

1. **Spike the merge primitive** in a scratch repo (see Testing) to choose among
   `subtree merge` / `-X subtree` / `merge-tree`. This decision gates the rest.
2. **Add the `synced` marker** and a helper in `monorepo.sh` to read/upsert it
   (mirror `stage_source`). Record the initial tip in `add`/`build`.
3. **Add sync-mode metadata** + `add`/`build` flag.
4. **Refactor `update`'s `update_one`** to separate "advance mirror" from
   "integrate," track the integrated position via the marker (fixing #3), and
   dispatch on sync mode. Keep the existing replay path intact for `replay` mode.
5. **Implement the merge path**, including baseline establishment
   (`merge -s ours`) for first-time/migrating repos, and the linear-merge-commit
   restriction lifted for merge mode.
6. **Rework conflict handling** and `--dry-run` / `--all` reporting around the
   marker.
7. **Update `README.md` and `CLAUDE.md`** — the "Updating a repo" section, the
   core-model description of `update` (currently states `format-patch | am`
   linear-only), and the new sync-mode/marker files.

## Testing

No automated tests exist; verify end-to-end in a scratch dir per `CLAUDE.md`:

- Create a throwaway source repo, `build` a monorepo from it.
- **Concurrent divergence:** commit to `foo/` in the monorepo *and* commit
  upstream, touching different files → sync merges cleanly, both changes present.
- **Overlapping conflict:** both sides edit the same lines → sync stops with a
  real conflict; resolve once; a *subsequent* upstream change syncs without
  re-hitting the old conflict (proves resolution is remembered — the core win).
- **Upstream with a merge commit** → merge-mode sync succeeds (replay would have
  refused).
- **Migration:** take a monorepo already advanced via the old `am` path, run the
  baseline establishment, then a normal sync → correct, no duplicate commits.
- Confirm `extract` still reproduces original upstream SHAs after several syncs.

## Open questions / decisions for the user

1. **Default going forward:** keep `replay` the default and require opt-in to
   `merge`, or flip new incorporations to `merge` by default? (Recommendation:
   opt-in per repo, so nothing changes for existing archive monorepos.)
2. **History shape:** is bringing the full upstream DAG (including its merge
   commits) into `main`'s ancestry acceptable, or do you want to keep `main`'s
   log flat and see upstream history only via the `foo/<branch>` mirror?
3. **git-subtree availability:** OK to depend on the contrib `git subtree`
   command, or prefer the more portable `merge-tree` plumbing?
4. **Push-back:** confirm bidirectional (monorepo → upstream) is genuinely out of
   scope for now.
