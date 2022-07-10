#!/bin/bash

set -ex

function init_monorepo {
    git init
    git commit --allow-empty -m "Creating combined repo."
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
# repos used master instead of main you could pushdown master and then merge
# that one branch into the monorepo's main. Obviously if some repos had both
# master and main, that might cause a non-trivial merge but creating the
# pushdown branch should be fine.)
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
