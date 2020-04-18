#!/usr/bin/env python

from functools import reduce
import json
import os
import requests
import sys

url = "https://api.github.com/graphql"
token = os.environ["GITHUB_TOKEN"]

headers = {"Authorization": "bearer {}".format(token)}


def query(who, after):
    if after is None:
        args = "first:100"
    else:
        args = 'first:100, after:"{}"'.format(after)

    return (
        'query { organization(login: "'
        + who
        + '") { repositories('
        + args
        + ") { edges { cursor node { name description sshUrl defaultBranchRef { name } } } } } }"
    )


def maybe_get(top, *path):
    return reduce(lambda d, k: None if d is None else d.get(k), path, top)


if __name__ == "__main__":

    who = sys.argv[1]

    after = None
    done = False

    while not done:
        r = requests.post(url, json={"query": query(who, after)}, headers=headers)
        edges = json.loads(r.text)["data"]["organization"]["repositories"]["edges"]
        if len(edges) == 0:
            done = True
        else:
            for n in (e["node"] for e in edges):
                print(
                    json.dumps(
                        {
                            **{k: n.get(k) for k in ["name", "description", "sshUrl"]},
                            "defaultBranch": maybe_get(n, "defaultBranchRef", "name"),
                        }
                    )
                )
            after = edges[-1]["cursor"]
