#!/bin/bash
#
# End-to-end tests for the real `update` command's merge-based sync (and the
# replay path it keeps working), per plans/continuous-upstream-sync.md. Drives
# build/update against throwaway upstream repos. Hermetic; run directly; exit
# status is the number of failed checks.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/test/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/monorepoize-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
setup_git_env "$WORK"
cd "$WORK"

# --- helpers ---------------------------------------------------------------
new_upstream() { # name : bare <name>.git + working <name>-wc with a,b,c files
  git init --bare -q "$1.git"; git clone -q "$1.git" "$1-wc"
  ( cd "$1-wc" && printf 'a\n' > a.txt && printf 'b\n' > b.txt && printf 'c\n' > c.txt \
    && git add -A && git commit -q -m init && git push -q -u origin main )
}
up_commit() { ( cd "$1-wc" && eval "$2" && git add -A && git commit -q -m "$3" && git push -q origin main ); }
build_mono() { # mono syncflag upstream
  printf '%s\n' "$WORK/$3.git" > "$1.repos"
  bash "$ROOT/build" ${2:+"$2"} "$1.repos" >"$WORK/$1-build.log" 2>&1 \
    || { echo "BUILD FAILED ($1)"; cat "$WORK/$1-build.log"; exit 1; }
}
mono_edit() { ( cd "$1" && git checkout -q main && eval "$2" && git commit -qam "$3" ); }
synced_of() { git -C "$1" show "main:.monorepoize/synced" 2>/dev/null | awk -v n="$2" '$1==n{print $2}'; }
mode_of()   { git -C "$1" show "main:.monorepoize/modes"  2>/dev/null | awk -v n="$2" '$1==n{print $2}'; }

#############################################################################
hr "Part 1: merge-from-start (build --sync=merge)"
new_upstream widget
build_mono mono --sync=merge widget
MONO="$WORK/mono"
[ "$(mode_of "$MONO" widget)" = merge ] && ok "build recorded mode=merge" || bad "mode not recorded: $(mode_of "$MONO" widget)"
[ -n "$(synced_of "$MONO" widget)" ] && ok "build recorded an initial synced tip" || bad "no synced recorded"

hr "1A: non-overlapping concurrent divergence -> update merges cleanly (no flag)"
mono_edit "$MONO" "printf 'a\nmono\n' > widget/a.txt" "mono edits a"
up_commit widget "printf 'b\nup\n' > b.txt" "up edits b"
if "$ROOT/update" "$MONO" widget >"$WORK/u1.log" 2>&1; then ok "update succeeded"; else bad "update failed"; cat "$WORK/u1.log"; fi
[ "$(cat "$MONO/widget/a.txt")" = $'a\nmono' ] && ok "mono edit to widget/a preserved" || bad "widget/a wrong"
[ "$(cat "$MONO/widget/b.txt")" = $'b\nup' ]   && ok "upstream edit to widget/b landed" || bad "widget/b wrong"
nparents=$(git -C "$MONO" rev-list --parents -n1 main | wc -w)
[ "$nparents" -eq 3 ] && ok "integration is a real 2-parent merge commit" || bad "not a merge commit (parents words=$nparents)"
[ "$(synced_of "$MONO" widget)" = "$(git -C "$MONO" rev-parse widget/main)" ] && ok "synced marker advanced to new upstream tip" || bad "synced not advanced"

hr "1B: dry-run reporting"
up_commit widget "printf 'c\nup\n' > c.txt" "up edits c"
"$ROOT/update" -n "$MONO" widget >"$WORK/dry.log" 2>&1
grep -q "new commit" "$WORK/dry.log" && ok "dry-run reports pending commits" || { bad "dry-run wrong"; cat "$WORK/dry.log"; }
git -C "$MONO" diff --quiet && ok "dry-run changed nothing" || bad "dry-run mutated the repo"
"$ROOT/update" "$MONO" widget >/dev/null 2>&1
"$ROOT/update" -n "$MONO" widget >"$WORK/dry2.log" 2>&1
grep -qi "up to date" "$WORK/dry2.log" && ok "dry-run reports up to date after integrating" || { bad "dry2 wrong"; cat "$WORK/dry2.log"; }

hr "1C: upstream history containing a merge commit integrates (no 'merges' refusal)"
( cd widget-wc
  git checkout -q -b feat && printf 'd\n' > d.txt && git add -A && git commit -q -m "feat d"
  git checkout -q main && printf 'b\nup\nmore\n' > b.txt && git commit -qam "main moves"
  git merge -q --no-ff -m "merge feat" feat && git push -q origin main )
if "$ROOT/update" "$MONO" widget >"$WORK/u2.log" 2>&1; then ok "update across an upstream merge succeeded"; else bad "update refused/failed on merge"; cat "$WORK/u2.log"; fi
[ -f "$MONO/widget/d.txt" ] && ok "merged-in file widget/d.txt present" || bad "widget/d.txt missing"

hr "1D: overlapping conflict -> in-progress merge, resolve, then next sync clean"
mono_edit "$MONO" "printf 'c\nmono\n' > widget/c.txt" "mono edits c"
up_commit widget "printf 'c\nupstream\n' > c.txt" "up edits c (overlapping)"
if "$ROOT/update" "$MONO" widget >"$WORK/u3.log" 2>&1; then bad "expected conflict, update succeeded"; else ok "update stopped on conflict (nonzero exit)"; fi
if git -C "$MONO" status --porcelain | grep -q '^UU widget/c.txt'; then ok "merge left in progress with widget/c.txt conflicted"; else bad "no in-progress conflict on widget/c.txt"; fi
# resolve keeping both, and commit -- the staged sync marker should ride along
( cd "$MONO" && printf 'c\nmono\nupstream\n' > widget/c.txt && git add widget/c.txt && git commit -q --no-edit )
[ "$(synced_of "$MONO" widget)" = "$(git -C "$MONO" rev-parse widget/main)" ] && ok "resolved merge commit recorded the sync marker" || bad "marker not recorded by resolve commit"
up_commit widget "printf 'b\nup\nmore\nyet\n' > b.txt" "up edits b again"
if "$ROOT/update" "$MONO" widget >"$WORK/u4.log" 2>&1; then ok "subsequent sync clean (conflict not replayed)"; else bad "subsequent sync re-hit conflict"; cat "$WORK/u4.log"; fi
[ "$(cat "$MONO/widget/c.txt")" = $'c\nmono\nupstream' ] && ok "resolved widget/c.txt stayed resolved" || bad "widget/c.txt regressed"

#############################################################################
hr "Part 2: replay backward-compat and the #3 stranding fix"
new_upstream gizmo
build_mono rmono "" gizmo
RMONO="$WORK/rmono"
[ -z "$(mode_of "$RMONO" gizmo)" ] && ok "default build records no merge mode (stays replay)" || bad "unexpected mode recorded"

hr "2A: replay applies a linear upstream change (unchanged behavior)"
up_commit gizmo "printf 'b\nup\n' > b.txt" "up edits b"
if "$ROOT/update" "$RMONO" gizmo >"$WORK/r1.log" 2>&1; then ok "replay update succeeded"; else bad "replay update failed"; cat "$WORK/r1.log"; fi
[ "$(cat "$RMONO/gizmo/b.txt")" = $'b\nup' ] && ok "replayed change present under gizmo/" || bad "replay content wrong"

hr "2B: replay conflict does NOT strand (dry-run still reports pending)"
mono_edit "$RMONO" "printf 'a\nmono\n' > gizmo/a.txt" "mono edits a"
up_commit gizmo "printf 'a\nupstream\n' > a.txt" "up edits a (overlapping)"
if "$ROOT/update" "$RMONO" gizmo >"$WORK/r2.log" 2>&1; then bad "expected replay conflict"; else ok "replay update reported conflict (nonzero exit)"; fi
"$ROOT/update" -n "$RMONO" gizmo >"$WORK/r3.log" 2>&1
if grep -qi "up to date" "$WORK/r3.log"; then bad "STRANDED: reports up to date after a conflict"; else
  grep -q "new commit" "$WORK/r3.log" && ok "re-run still reports the pending commit (bug #3 fixed)" || { bad "unexpected dry-run output"; cat "$WORK/r3.log"; }
fi

#############################################################################
hr "Part 3: switch a replay-built repo to merge mode (--merge)"
new_upstream sprocket
build_mono smono "" sprocket
SMONO="$WORK/smono"
up_commit sprocket "printf 'b\nup\n' > b.txt" "up edits b"
"$ROOT/update" "$SMONO" sprocket >/dev/null 2>&1   # one clean replay first
# now diverge on both sides (non-overlapping) and switch to merge
mono_edit "$SMONO" "printf 'a\nmono\n' > sprocket/a.txt" "mono edits a"
up_commit sprocket "printf 'c\nup\n' > c.txt" "up edits c"
if "$ROOT/update" --merge "$SMONO" sprocket >"$WORK/s1.log" 2>&1; then ok "--merge switch + sync succeeded"; else bad "--merge switch failed"; cat "$WORK/s1.log"; fi
[ "$(mode_of "$SMONO" sprocket)" = merge ] && ok "mode switched to merge and recorded" || bad "mode not switched"
[ "$(cat "$SMONO/sprocket/a.txt")" = $'a\nmono' ] && ok "mono edit preserved through switch" || bad "sprocket/a wrong"
[ "$(cat "$SMONO/sprocket/c.txt")" = $'c\nup' ]   && ok "upstream edit merged after switch" || bad "sprocket/c wrong"
# a second merge-mode sync should now just work with no flag
up_commit sprocket "printf 'a\nmono2\n' > /dev/null; printf 'e\n' > e.txt" "up adds e"
if "$ROOT/update" "$SMONO" sprocket >"$WORK/s2.log" 2>&1; then ok "post-switch sync (no flag) succeeded"; else bad "post-switch sync failed"; cat "$WORK/s2.log"; fi
[ -f "$SMONO/sprocket/e.txt" ] && ok "post-switch upstream file present" || bad "sprocket/e.txt missing"

#############################################################################
hr "Part 4: --all with a mixed monorepo (merge conflict skipped, others proceed)"
new_upstream aa; new_upstream bb
printf '%s\n%s\n' "$WORK/aa.git" "$WORK/bb.git" > combo.repos
bash "$ROOT/build" --sync=merge combo.repos >"$WORK/combo-build.log" 2>&1 || { echo BUILD FAIL combo; cat "$WORK/combo-build.log"; exit 1; }
COMBO="$WORK/combo"
# aa: overlapping conflict; bb: clean non-overlapping change
mono_edit "$COMBO" "printf 'a\nmono\n' > aa/a.txt" "mono edits aa/a"
up_commit aa "printf 'a\nupstream\n' > a.txt" "aa edits a (overlapping)"
up_commit bb "printf 'z\n' > z.txt" "bb adds z"
"$ROOT/update" --all "$COMBO" >"$WORK/all.log" 2>&1; allrc=$?
[ "$allrc" -eq 0 ] && ok "--all exits 0 despite a per-repo conflict" || bad "--all exit=$allrc"
grep -q "CONFLICT" "$WORK/all.log" && ok "--all reports the conflicting repo" || { bad "no conflict reported"; cat "$WORK/all.log"; }
if git -C "$COMBO" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then bad "--all left a merge in progress"; else ok "--all left no merge in progress (aborted cleanly)"; fi
[ -f "$COMBO/bb/z.txt" ] && ok "the clean repo was still integrated" || bad "clean repo not integrated"

hr "Cross-check: extract still reproduces upstream SHAs after merge syncs"
tip=$(git -C widget-wc rev-parse main)
git -C "$MONO" cat-file -e "$tip" 2>/dev/null && ok "upstream tip SHA present byte-for-byte in monorepo" || bad "upstream SHA not preserved"

finish
