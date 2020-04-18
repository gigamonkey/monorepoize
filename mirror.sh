#!/bin/bash

set -e

dir=$1
file=$2

mkdir -p "$dir" || exit 1

cd "$dir"

while read -r url; do
    git clone --mirror "$url"
done < ../"$file"
