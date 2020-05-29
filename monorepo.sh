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
# proj1/master, proj2/master) into a new branch with just that base
# name with each project in its own subdirectory.
#
function pushdown {

    local branch moved_something

    branch=$1 # e.g. master

    ensure_branch "$branch"

    git show-ref --heads "$branch" | cut -c 53- | while read -r b; do

        if [ "$b" != "$branch" ]; then

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
        fi
    done

    echo "Done pushing $branch."
    sleep 1
}
