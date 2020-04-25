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
        echo "$dir alread exists."
        exit 1
    else
        mkdir -p "$dir"
        cd "$dir"
        init_monorepo
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

function pushdown {

    local branch name dir moved_something

    branch=$1
    name=${branch%%/*}

    if [ -n "$(git show-ref "$branch")" ]; then

        echo "Pushing $branch into $name."

        git switch -c pushdown "$branch"
        dir=$(mktemp -d tmp.XXXX)
        moved_something="false"
        for f in * .*; do
            if [[ "$f" != .git && "$f" != "$dir" && "$f" != "." && "$f" != ".." ]]; then
                git mv "$f" "$dir"
                moved_something="true"
            fi
        done
        if [ "$moved_something" == "true" ]; then
            git mv "$dir" "$name"
        else
            mv "$dir" "$name"
            echo "No files in $branch." > "$name/empty-branch.txt"
            git add "$name/empty-branch.txt"
        fi
        git commit --allow-empty -m "Moving $name to subdir."
        git checkout master
        git merge --allow-unrelated-histories -s recursive -X no-renames --no-ff -m "Merging $name to master." pushdown
        git branch -d pushdown
    else
        echo "No branch $branch to merge into master."
        mkdir -p "$name"
        if git show-ref | grep "refs/heads/$name" > "$name/no-branch.txt"; then
            git add "$name/no-branch.txt"
        else
            rm "$name/no-branch.txt"
            touch "$name/empty-repo.txt"
            git add "$name/empty-repo.txt"

        fi
        git commit --allow-empty -m "Creating placeholder subdir $name."
    fi

    echo "Done pushing $branch into $name."
    sleep 1
}
