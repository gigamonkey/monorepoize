#!/bin/bash

set -e

source monorepo.sh

here=$(pwd)
input=$(realpath "$1")
branch=${2:-master}

ensure_repo_dir "$(basename "$1" .repos)"

while read -r repo; do
    # Accept either github URLs or a path to a bare repo .git directory.
    if [ "${repo:0:15}" != "git@github.com:" ]; then
        repo=$(cd "$here"; realpath "$repo")
    fi
    name=${repo##*/}
    name=${name%.git}
    echo "Incorporating $name ..."
    incorporate "$name" "$repo"
done < "$input"

pushdown "$branch"
