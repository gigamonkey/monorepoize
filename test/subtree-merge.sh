#!/bin/bash
#
# Validates the git merge primitive that the continuous-upstream-sync plan
# (plans/continuous-upstream-sync.md) is built on: `git merge -X subtree=<name>`
# to fold new upstream commits into a monorepo's <name>/ subdirectory when BOTH
# sides have diverged. The monorepo keeps content under <name>/ (ours) while the
# upstream mirror keeps it at the repo root (base + theirs); this checks that the
# subtree strategy reconciles that shape correctly.
#
# Uses the real ./build to create the monorepo, then exercises the core
# scenarios. Hermetic: a throwaway working dir and isolated git config. Run it
# directly; exit status is the number of failed checks.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/test/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/monorepoize-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
setup_git_env "$WORK"
cd "$WORK"

# ---- upstream repo (content at root) + real monorepo build ----------------
hr "Setup: create upstream widget.git and build monorepo"
git init --bare -q widget.git
git clone -q widget.git up
( cd up
  printf 'A0\n' > a.txt; printf 'B0\n' > b.txt; printf 'C0\n' > c.txt; printf 'hello\n' > README
  git add -A; git commit -q -m "initial"; git push -q -u origin main )

printf '%s\n' "$WORK/widget.git" > mono.repos
bash "$ROOT/build" mono.repos >"$WORK/build.log" 2>&1 \
  || { echo "build failed"; cat "$WORK/build.log"; exit 1; }
MONO="$WORK/mono"
[ -f "$MONO/widget/a.txt" ] && ok "monorepo has widget/a.txt" || bad "widget/ subdir missing"
T0=$(git -C "$MONO" rev-parse refs/heads/widget/main)
git -C "$MONO" merge-base --is-ancestor "$T0" main \
  && ok "upstream tip T0 is ancestor of main" || bad "T0 not ancestor of main"

# commit in upstream (+push), then fetch the mirror in mono (what `update` does)
upstream_commit() { ( cd up && eval "$1" && git add -A && git commit -q -m "$2" && git push -q origin main ); }
fetch_mirror()    { git -C "$MONO" fetch -q --no-tags "$WORK/widget.git" '+refs/heads/*:refs/heads/widget/*'; }
subtree_merge()   { git -C "$MONO" merge --no-edit -X subtree=widget widget/main; }

#############################################################################
hr "Scenario A: non-overlapping concurrent changes -> clean subtree merge"
( cd "$MONO" && git checkout -q main && printf 'A0\nmono-added\n' > widget/a.txt && git commit -qam "mono edits a" )
upstream_commit "printf 'B0\nup-added\n' > b.txt" "up edits b"
fetch_mirror
if subtree_merge >"$WORK/mA.log" 2>&1; then ok "clean merge succeeded"; else bad "clean merge unexpectedly failed"; cat "$WORK/mA.log"; fi
a=$(cat "$MONO/widget/a.txt"); b=$(cat "$MONO/widget/b.txt")
[ "$a" = $'A0\nmono-added' ] && ok "monorepo edit to widget/a.txt preserved" || bad "widget/a.txt wrong: $a"
[ "$b" = $'B0\nup-added' ]   && ok "upstream edit landed under widget/b.txt"  || bad "widget/b.txt wrong: $b"
git -C "$MONO" merge-base --is-ancestor widget/main main \
  && ok "upstream tip now ancestor of main (base advances)" || bad "upstream tip not ancestor after merge"

#############################################################################
hr "Scenario B: overlapping change -> conflict, resolve, then next sync is clean"
( cd "$MONO" && printf 'C0\nmono-c\n' > widget/c.txt && git commit -qam "mono edits c" )
upstream_commit "printf 'C0\nup-c\n' > c.txt" "up edits c (overlapping)"
fetch_mirror
if subtree_merge >"$WORK/mB.log" 2>&1; then bad "expected conflict, got clean merge"; else ok "overlapping edit produced a conflict (as expected)"; fi
if git -C "$MONO" status --porcelain | grep -q '^UU widget/c.txt'; then ok "conflict is on widget/c.txt (correct path)"; else
  bad "conflict not on widget/c.txt"; git -C "$MONO" status --porcelain; fi
( cd "$MONO" && printf 'C0\nmono-c\nup-c\n' > widget/c.txt && git add widget/c.txt && git commit -q --no-edit )
git -C "$MONO" merge-base --is-ancestor widget/main main && ok "resolved: upstream tip is ancestor" || bad "upstream tip not ancestor after resolve"
upstream_commit "printf 'B0\nup-added\nup-more\n' > b.txt" "up edits b again"
fetch_mirror
if subtree_merge >"$WORK/mB2.log" 2>&1; then ok "subsequent sync clean (old conflict not replayed)"; else
  bad "subsequent sync re-hit a conflict"; cat "$WORK/mB2.log"; fi
cc=$(cat "$MONO/widget/c.txt")
[ "$cc" = $'C0\nmono-c\nup-c' ] && ok "resolved widget/c.txt stayed resolved" || bad "widget/c.txt regressed: $cc"

#############################################################################
hr "Scenario C: upstream range containing a MERGE commit syncs fine"
( cd up
  git checkout -q -b feature
  printf 'D0\n' > d.txt; git add -A; git commit -q -m "feature: add d"
  git checkout -q main
  printf 'B0\nup-added\nup-more\nmain-side\n' > b.txt; git commit -qam "main moves on"
  git merge -q --no-ff -m "merge feature" feature
  git push -q origin main )
fetch_mirror
if subtree_merge >"$WORK/mC.log" 2>&1; then ok "sync across an upstream merge succeeded (linear restriction gone)"; else
  bad "sync across upstream merge failed"; cat "$WORK/mC.log"; fi
[ -f "$MONO/widget/d.txt" ] && ok "merged-in file widget/d.txt present" || bad "widget/d.txt missing"

#############################################################################
hr "Scenario D: baseline via 'merge -s ours' (migration case)"
# Record an upstream tip as merged WITHOUT taking its content -- the migration
# path for monorepos previously advanced via the old am replay.
upstream_commit "printf 'A0\nmono-added\nUPSTREAM-ONLY\n' > a.txt" "up edits a (will be baselined away)"
fetch_mirror
if git -C "$MONO" merge -s ours --no-edit -m "baseline widget" widget/main >"$WORK/mD.log" 2>&1; then
  ok "merge -s ours recorded baseline"; else bad "merge -s ours failed"; cat "$WORK/mD.log"; fi
a=$(cat "$MONO/widget/a.txt")
[ "$a" = $'A0\nmono-added' ] && ok "baseline kept monorepo's widget/a.txt (upstream-only change dropped)" || bad "a.txt changed by baseline: $a"
git -C "$MONO" merge-base --is-ancestor widget/main main && ok "baseline made upstream tip an ancestor" || bad "baseline did not set ancestry"
upstream_commit "printf 'E0\n' > e.txt" "up adds e after baseline"
fetch_mirror
if subtree_merge >"$WORK/mD2.log" 2>&1; then ok "post-baseline sync clean"; else bad "post-baseline sync failed"; cat "$WORK/mD2.log"; fi
[ -f "$MONO/widget/e.txt" ] && ok "post-baseline upstream file widget/e.txt present" || bad "widget/e.txt missing"

#############################################################################
hr "Cross-check: extract invariant -- upstream SHAs preserved"
UPTIP=$(git -C up rev-parse main)
git -C "$MONO" cat-file -e "$UPTIP" 2>/dev/null \
  && ok "current upstream tip SHA exists byte-for-byte in monorepo" || bad "upstream SHA not preserved"

finish
