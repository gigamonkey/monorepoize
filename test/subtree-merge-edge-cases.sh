#!/bin/bash
#
# Edge cases for the subtree-merge primitive (companion to subtree-merge.sh):
#   - multi-repo confinement: syncing one repo must not touch a sibling subdir;
#   - upstream deletions propagate under the target subdir and only there;
#   - the `git merge-tree --write-tree` plumbing fallback (git >= 2.38) that the
#     plan keeps as an optional --dry-run conflict predictor is viable.
#
# Hermetic: throwaway working dir and isolated git config. Run directly; exit
# status is the number of failed checks.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/test/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/monorepoize-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
setup_git_env "$WORK"
cd "$WORK"

mkrepo() { # name file-content : create bare repo <name>.git with an initial commit
  git init --bare -q "$1.git"; git clone -q "$1.git" "$1-wc"
  ( cd "$1-wc" && printf '%s\n' "$2" > f.txt && printf 'shared\n' > shared.txt \
    && git add -A && git commit -q -m init && git push -q -u origin main )
}

hr "Setup: monorepo with TWO repos (widget, gadget)"
mkrepo widget W0; mkrepo gadget G0
printf '%s\n%s\n' "$WORK/widget.git" "$WORK/gadget.git" > mono.repos
bash "$ROOT/build" mono.repos >"$WORK/build.log" 2>&1 || { echo BUILD FAIL; cat "$WORK/build.log"; exit 1; }
MONO="$WORK/mono"
[ -f "$MONO/widget/f.txt" ] && [ -f "$MONO/gadget/f.txt" ] && ok "both widget/ and gadget/ present" || bad "subdirs missing"

fetch_mirror() { git -C "$MONO" fetch -q --no-tags "$WORK/$1.git" "+refs/heads/*:refs/heads/$1/*"; }

hr "Multi-repo: widget subtree merge must not touch gadget/"
gadget_tree_before=$(git -C "$MONO" rev-parse "main:gadget")
( cd widget-wc && printf 'W1\n' > f.txt && printf 'new upstream file\n' > extra.txt && git add -A && git commit -qam w1 && git push -q origin main )
fetch_mirror widget
if git -C "$MONO" merge --no-edit -X subtree=widget widget/main >"$WORK/m.log" 2>&1; then ok "widget merge succeeded"; else bad "widget merge failed"; cat "$WORK/m.log"; fi
[ "$(cat "$MONO/widget/f.txt")" = W1 ] && ok "widget/f.txt updated to W1" || bad "widget/f.txt not updated"
[ -f "$MONO/widget/extra.txt" ] && ok "new upstream file landed in widget/" || bad "widget/extra.txt missing"
gadget_tree_after=$(git -C "$MONO" rev-parse "main:gadget")
[ "$gadget_tree_before" = "$gadget_tree_after" ] && ok "gadget/ tree byte-identical (untouched)" || bad "gadget/ tree changed!"
[ ! -e "$MONO/gadget/extra.txt" ] && ok "no leakage of widget file into gadget/" || bad "leak into gadget/"

hr "Upstream deletion propagates under widget/ only"
( cd widget-wc && git rm -q shared.txt && git commit -q -m "rm shared" && git push -q origin main )
fetch_mirror widget
git -C "$MONO" merge --no-edit -X subtree=widget widget/main >"$WORK/md.log" 2>&1 || { bad "delete-merge failed"; cat "$WORK/md.log"; }
[ ! -e "$MONO/widget/shared.txt" ] && ok "deletion propagated: widget/shared.txt removed" || bad "widget/shared.txt still present"
[ -e "$MONO/gadget/shared.txt" ] && ok "gadget/shared.txt untouched by widget deletion" || bad "gadget/shared.txt wrongly removed"

hr "Fallback: merge-tree --write-tree subtree plumbing (no working-tree churn)"
if ! git_ge 2 38; then
  echo "  SKIP: git $(git version | awk '{print $3}') < 2.38; merge-tree --write-tree unavailable"
else
  ( cd widget-wc && printf 'W2\n' > f.txt && git commit -qam w2 && git push -q origin main )
  fetch_mirror widget
  cd "$MONO"
  THEIRS=$(git rev-parse widget/main)
  BASE=$(git merge-base main widget/main)
  # Shift a commit's tree into widget/ using a temp index -> prints the tree oid.
  shift_tree() {
    local tmpidx; tmpidx=$(mktemp -u)   # a nonexistent path; git creates the index
    GIT_INDEX_FILE="$tmpidx" git read-tree --prefix=widget/ "$1^{tree}"
    GIT_INDEX_FILE="$tmpidx" git write-tree
    rm -f "$tmpidx"
  }
  BASE_SHIFTED=$(shift_tree "$BASE")
  THEIRS_SHIFTED=$(shift_tree "$THEIRS")
  # Wrap the shifted trees in throwaway commits so an explicit --merge-base works.
  c_base=$(git commit-tree "$BASE_SHIFTED"   -m base)
  c_thrs=$(git commit-tree "$THEIRS_SHIFTED" -p "$c_base" -m theirs)
  c_ours=$(git commit-tree "$(git rev-parse main^{tree})" -p "$c_base" -m ours)
  if MT=$(git merge-tree --write-tree --merge-base="$c_base" "$c_ours" "$c_thrs" 2>"$WORK/mt.log"); then
    merged_tree=$(printf '%s' "$MT" | head -1)
    git read-tree "$merged_tree"; git checkout-index -a -f --prefix="$WORK/mtout/" 2>/dev/null
    [ "$(cat "$WORK/mtout/widget/f.txt" 2>/dev/null)" = W2 ] && ok "merge-tree plumbing produced correct widget/f.txt=W2" || bad "merge-tree result wrong"
    ok "merge-tree --write-tree subtree merge is viable (clean case, exit 0)"
  else
    bad "merge-tree plumbing failed"; cat "$WORK/mt.log"
  fi
  git reset -q --hard main   # undo the read-tree we did into the index
fi

finish
