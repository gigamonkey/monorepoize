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

## Relationship to submodules, subtree, and prior art

The obvious question about continuous syncing is "isn't this just git
submodules?" It is not — and knowing *which* tool this resembles keeps the
implementation honest.

- **Submodules solve the opposite problem.** A submodule is a *pointer*: the
  superproject stores a gitlink recording "at `foo/`, use commit X of repo Y,"
  and the sub-repo's objects and history stay in a separate repository. The
  boundary is preserved and referenced. Monorepoize *dissolves* the boundary —
  files live directly in the one tree under `foo/`, every original commit is
  imported into the one object store (with its original SHA), one clone, one
  worktree, one history graph. Choosing this model over submodules is
  deliberate: the separation submodules enforce (recursive init, per-consumer
  access to every sub-repo, detached-HEAD footguns, no atomic cross-repo
  commits) is exactly the tax a monorepo exists to avoid.

- **The real relative is `git subtree`.** Vendoring another repo's content into
  a subdirectory and merging updates in over time is conceptually what
  `git subtree merge` / `git subtree pull` do, and the sync design here builds on
  the same *merge machinery*. Two caveats, though. First, the `git subtree`
  **command** is a `contrib/` script, not core git, and is **not guaranteed to be
  installed** (e.g. absent on stock macOS Xcode git); only the underlying
  strategy — `git merge -X subtree=<path>` and the `git read-tree` /
  `git merge-tree` plumbing — is core and always present. So we build on the core
  machinery, not the contrib command (see Merge mechanics; this is decision 3).
  Second, because the command may be absent, "worse than just calling
  `git subtree` directly" is not even a fair baseline everywhere — the wrapper
  also papers over that portability gap.

- **What justifies the custom layer** — the genuinely novel parts subtree does
  not give you, and the reason this is a wrapper rather than a fork of subtree:

  1. **SHA-preserving mirror branches** (`foo/<branch>` / `foo/<tag>`) that
     `extract` and `retire` depend on; plain subtree keeps no such mirror.
  2. **Many repos at once**, with namespaced branches/tags and recorded
     provenance (`.monorepoize/sources`).
  3. **Round-tripping** — `extract` reproduces a standalone repo byte-for-byte.

  Other tools in this space (`git-vendor`, Google's `copybara`, `josh`) confirm
  it is well-trodden ground; none combine SHA preservation, multi-repo
  incorporation, and byte-exact extraction the way monorepoize does.

**Design implication:** lean on git's own *core* subtree merge machinery
(`-X subtree=`, `merge-tree`) as hard as possible and hand-roll only where the
mirror / multi-repo / extract features force it. Reimplementing 3-way subtree
merging ourselves is the line between wrapping git's merge machinery *well* and
maintaining a parallel merge engine *badly* — but "wrapping subtree" here means
its merge strategy, not a dependency on the `git subtree` command.

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
differences; pick one in a spike and lock it in. **Decision 3** rules out
depending on the contrib `git subtree` command for portability, so both viable
options are core git:

- `git merge -s recursive -X subtree=foo <mirror-tip>` — relies on the recursive
  strategy's prefix-shift; robust when the prefix is given explicitly (don't rely
  on auto-detection). Core git, always present.
- `git merge-tree --write-tree` (git ≥ 2.38) three-way on the `foo/` subtree,
  then commit the result manually with the upstream tip as a second parent — the
  most explicit and scriptable, no working-tree churn, but requires newer git and
  more plumbing.
- (`git subtree merge --prefix=foo <mirror-tip>` is the highest-level form, but
  the `git subtree` command is a `contrib/` script that is **not guaranteed
  installed** — absent on stock macOS Xcode git, sometimes unbundled on Linux.
  Ruled out as a dependency for that reason; only its underlying merge strategy,
  which we get directly above, is core.)

Recommendation: prototype the recursive `-X subtree=foo` form first (fewest
dependencies, works on older git), fall back to explicit `merge-tree` plumbing if
prefix detection misbehaves — mindful that `merge-tree --write-tree` raises the
minimum git version to 2.38. Note that `pushdown_one`'s `-X no-renames` is
specific to the initial unrelated-history merge and should **not** be carried
into sync merges, where rename detection is desirable.

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
  larger effort and is **not implemented here**. But per **decision 4 we must not
  make choices now that preclude adding it later**, and the design already keeps
  the door open:

  - The SHA-preserving `foo/<branch>` mirror stays, so a future `git subtree
    split --prefix=foo` has a stable reference for "what is already upstream."
  - Bringing the full upstream DAG into `main`'s ancestry as real merges
    (decision 2) means a future split can tell monorepo-original commits from
    already-upstreamed ones and only push the former.
  - **Do not squash** sync merges and **do not rewrite SHAs** — a squashed or
    rewritten `foo/` history would make a later clean split much harder. (This is
    also why merge mode records real merges rather than replayed/flattened
    commits.)

  So push-back remains a viable future addition on top of this design, not a
  fork of it.
- Rewriting history or changing the mirror/ref-naming scheme.

## Implementation steps

1. **Spike the merge primitive** in a scratch repo (see Testing) to choose
   between core `-X subtree=foo` and `merge-tree --write-tree` plumbing (the
   contrib `git subtree` command is ruled out — decision 3). This gates the rest.
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

## Decisions (resolved)

1. **Default going forward — opt-in per repo.** `replay` stays the default;
   `merge` mode is opt-in, so nothing changes for existing archive monorepos.
   (Reflected in "Sync mode" above.)

2. **History shape — full upstream DAG is acceptable.** Merge mode brings the
   upstream history (including its merge commits) into `main`'s ancestry as real
   merges. This is also what makes the linear-history restriction go away and
   what keeps future push-back feasible (decision 4).

3. **git-subtree availability — do not depend on the contrib command.** Prefer
   the portable core machinery (`git merge -X subtree=`, `git merge-tree`). The
   `git subtree` command is a `contrib/` script that may be absent (e.g. stock
   macOS Xcode git), which also fits this repo's macOS+Linux portability goal.
   (Reflected in "Merge mechanics" and implementation step 1.)

4. **Push-back — not implemented now, but not precluded.** Bidirectional
   (monorepo → upstream) sync stays out of scope, but the design deliberately
   avoids choices that would block adding it later (keep the SHA-preserving
   mirror, real upstream ancestry, no squash/rewrite). See Non-goals for the
   specific constraints this imposes.

## Remaining open question

- **Merge primitive:** the spike (implementation step 1) still has to pick
  between `-X subtree=foo` and `merge-tree --write-tree` and confirm prefix
  handling is reliable against a base/ours/theirs where `ours` is prefixed and
  base/theirs are root-level. Everything else above is settled.
