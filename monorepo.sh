#!/bin/bash

set -ex

function init_monorepo {
    git init
    git commit --allow-empty -m "Creating combined repo."
    git config core.ignorecase false # preserve exact-case filenames across merged repos (built on Mac, used on Linux)
    sleep 1
}

function ensure_repo_dir {

    dir="$1"

    if [ -d "$dir" ]; then
        echo "$dir already exists."
        exit 1
    else
        mkdir -p "$dir"
        cd "$dir"
        init_monorepo
    fi
}

function ensure_branch {

    local branch

    branch="$1"

    if git show-ref --verify --quiet refs/heads/"$branch"; then
        git switch "$branch"
    else
        git switch --orphan "$branch"
        git commit --allow-empty -m "Creating combined $branch."
        sleep 1
    fi
}

#
# Print the names of the constituent repos in a monorepo, one per line, unique.
# MONO may be a local path or a git URL. Each incorporated repo contributes
# branches named "<name>/<branch>" (and tags "<name>/<tag>"), so the name is the
# first path segment of each namespaced branch. The un-namespaced default branch
# (main/master) and HEAD have no namespace and are skipped. For a local clone we
# also look at origin remote-tracking refs, since a fresh `git clone` keeps the
# per-repo branches under refs/remotes/origin/ rather than refs/heads/.
#
function constituent_names {
    local mono ref b
    mono=$1
    {
        git ls-remote --heads "$mono" 2>/dev/null | while read -r _ ref; do
            printf '%s\n' "${ref#refs/heads/}"
        done
        if git -C "$mono" rev-parse --git-dir >/dev/null 2>&1; then
            git -C "$mono" for-each-ref --format='%(refname:short)' refs/remotes/origin/ 2>/dev/null \
                | while read -r b; do printf '%s\n' "${b#origin/}"; done
        fi
    } 2>/dev/null | while read -r b; do
        case "$b" in
            HEAD) ;;
            */*) printf '%s\n' "${b%%/*}" ;;
        esac
    done | sort -u
    return 0
}

#
# Upsert a "name value" line into a committed .monorepoize/<file>, keeping one
# line per repo, and stage it. This is the common shape of every per-repo record
# monorepoize keeps (sources, sync positions, sync modes); the callers below are
# thin wrappers. Only stages the file; the caller commits.
#
function stage_kv {
    local file name value dir path
    file=$1
    name=$2
    value=$3
    dir=".monorepoize"
    path="$dir/$file"
    mkdir -p "$dir"
    if [ -f "$path" ]; then
        awk -v n="$name" '$1 != n' "$path" > "$path.tmp"
        mv "$path.tmp" "$path"
    fi
    printf '%s %s\n' "$name" "$value" >> "$path"
    git add "$path"
}

#
# Record (upsert) the source URL a repo was incorporated from in a committed
# .monorepoize/sources file, so `update` (and any future tooling) can find the
# upstream with no extra input. One "name url" line per repo.
#
function stage_source { stage_kv sources "$1" "$2"; }

#
# Record how far upstream a repo has been integrated: the last upstream commit
# SHA folded into the <name>/ subdir on the default branch. This is `update`'s
# source of truth for the integration base -- decoupled from the mirror ref, so
# a failed sync can never be mistaken for "up to date". One line per repo.
#
function stage_synced { stage_kv synced "$1" "$2"; }

#
# Record a repo's sync mode ("merge" or "replay"). Absent = "replay" (the
# historical behavior), so existing monorepos need no migration. One line per
# repo. See `update` for what the modes mean.
#
function stage_mode { stage_kv modes "$1" "$2"; }

function incorporate {
    local name url before after

    name=$1
    url=$2
    before=$(git log --all --oneline | wc -l)

    git remote add "$name" "$url"
    git config --local "remote.$name.fetch" "+refs/heads/*:refs/heads/$name/*"
    git config --local --add "remote.$name.fetch" "+refs/tags/*:refs/tags/$name/*"
    git fetch --no-tags "$name"
    git remote remove "$name"

    after=$(git log --all --oneline | wc -l)

    echo "After incorporating $name $((after - before)) changes."
}

#
# Push down the contents of all branches with the same base name (e.g.
# proj1/main, proj2/main) into a new branch with just that base name with each
# project in its own subdirectory. When creating a monorepo we do this for the
# default branch, e.g. main but this function could be used after the fact to
# create another unified branch. (For instance, if some of the incorporated
# repos used prod instead of main you could pushdown prod and then merge that
# one branch into the monorepo's main. Obviously if some repos had both prod and
# main, that might cause a non-trivial merge but creating the pushdown branch
# should be fine. See the script pushdown for an easy way to invoke this
# function.)
#
function pushdown {

    local branch moved_something

    branch=$1 # e.g. main

    ensure_branch "$branch"

    git show-ref --heads "$branch" | cut -c 53- | while read -r b; do
        if [ "$b" != "$branch" ]; then
            pushdown_one "$branch" "$b"
        fi
    done

    echo "Done pushing $branch."
    sleep 1
}


#
# Push down the contents of one branch created by incorporate into
# another, usually main.
#
function pushdown_one {

    local branch b moved_something

    branch=$1 # e.g. main
    b=$2 # branch to push down, e.g. foo/main

    local dir=${b%%/"$branch"}

    echo "Pushing $b into $dir."

    git switch -c pushdown "$b"

    tmpdir=$(mktemp -d tmp.XXXX)
    moved_something="false"
    for f in * .*; do
        if [[ "$f" != .git && "$f" != "$tmpdir" && "$f" != "." && "$f" != ".." ]]; then
            git mv "$f" "$tmpdir"
            moved_something="true"
        fi
    done

    if [ "$moved_something" == "true" ]; then
        mkdir -p "$(dirname "$dir")"
        git mv "$tmpdir" "$dir"
        git commit -m "Moving $dir to subdir in $branch."
    else
        rmdir "$tmpdir"
    fi
    git checkout "$branch"
    git merge --allow-unrelated-histories -s recursive -X no-renames --no-ff -m "Merging $b to $branch." pushdown
    git branch -d pushdown
}
