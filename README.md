This repo contains code to combine multiple git repos into a single
monolithic repo (a.k.a. a monorepo) while preserving full history,
branches, and tags.

The contents of each sub-repo are incorporated with their original
history (i.e. every commit to the original repo will exist in the new
repo with the same SHA) and all branches and tags will be added,
renamed to be prefixed by the name of the repo being added. So if the
subrepo is `foo.git` and it contains a branch `whatever`, in the
monorepo the SHA pointed to by the branch `whatever` in the original
repo will now be pointed to by a branch named `foo/whatever`.

Additionally the contents of `main` branch from each sub-repo will be
added in a subdirectory named for the sub-repo and merged to the
monorepo's `main` branch. (Or you can specify a different default
branch as the second argument to the `build` script.)

# To create a monorepo.

- Make a file containing the git URLs of the repos you want to
  combine. These can be paths to bare repos (ideally created with `git
  clone --mirror`) or `git@github.com:` URLs. This file should be
  named `something.repos` where `something` is the name of the new
  monorepo you want to create.

- Run `./build something.repos`. It will create a directory named
  `something` and incorporate all the repos listed in the
  `something.repos` file. Pass `--sync=merge` (before the repos file) if
  you intend to keep editing the incorporated subdirectories *and* keep
  pulling upstream changes — it puts every repo in merge mode from the
  start (see "Updating a repo" below). The default, `--sync=replay`,
  suits an archive that only ever receives upstream commits.

- After the monorepo is built, look for `empty-repo.txt` and
  `no-branch.txt` files in the subdirectories. These are created if
  the repo incorporated had either no changes (`empty-repo.txt`) or no
  `main` branch. In the latter case the `no-branch.txt` file will
  contain a list of the refs from the repo. If there's an appropriate
  branch (say the repo used `prod` instead of `main`) you can fix
  things up with the `pushdown` script. In the monorepo remove the
  `no-branch.txt` and then run `./pushdown foo/prod` to put the
  contents of the `foo/prod` branch into the `foo` subdirectory and
  merge them to `main`.

`build` (and `add`) also record where each repo came from in a
committed `.monorepoize/sources` file (one `name url` line per repo).
The `update` command (below) reads this to find each repo's upstream
with no extra arguments. Two sibling files under `.monorepoize/` support
merge-mode syncing: `modes` records each repo's sync mode (absent means
`replay`), and `synced` records how far upstream each merge-mode repo
has been integrated. You don't edit these by hand; `build`, `add`, and
`update` maintain them.


# Extracting a repo

`extract` is the inverse of `build`/`add`: it pulls one original repo
back out of a monorepo with its original history. Because monorepoize
stored each repo as `name/<branch>` and `name/<tag>` with the original
commit SHAs, extraction is just fetching those refs back with the
`name/` prefix stripped — the extracted commits are byte-for-byte the
originals.

```
./extract MONOREPO DIR [-o OUTPUT] [--bundle] [--push URL]
```

`MONOREPO` may be a local path or a git URL; `DIR` is the top-level
subdirectory (the repo name) to extract. By default it writes a
standalone repo to `./DIR`.

- `-o OUTPUT` is the full path to write — it replaces `./DIR` entirely,
  it is not a parent directory to put `DIR` inside. So `-o /tmp/foo`
  creates the extracted repo *at* `/tmp/foo` (not `/tmp/foo/DIR`). With
  `--bundle` it is the bundle file path instead (replacing the default
  `./DIR.bundle`). The path must not already exist.

- `--bundle` writes only a single-file git bundle (nothing else left
  behind); the recipient restores it with `git clone DIR.bundle`.

- `--push URL` pushes `--all` and `--tags` to a fresh remote.

This needs the monorepo to actually contain the per-repo branches. If
the monorepo was pushed to a remote with only its default branch (no
`git push --all`), that history isn't there to recover; `extract` will
tell you to re-push with `git push --all && git push --tags`.


# Updating a repo with later upstream commits

If a source repo gets new commits after the monorepo was built, `update`
folds them back in, preserving history. Either way it first fetches the
new commits onto the `name/<branch>` branch (original SHAs, exactly like
`build`); it then integrates them into the `name/` subdirectory of the
default branch in one of two modes.

**replay** (the default) replays just the new commits onto the `name/`
subdirectory with `git format-patch | git am`, keeping each commit's
message, author, and date. This suits the *archive* case where the
monorepo never edits `name/` itself. It only applies a linear range —
if the upstream range contains a merge commit it is refused (single
repo) or skipped (`--all`) — and it conflicts if the subdirectory has
diverged.

**merge** (opt in with `--merge`, or from the start with `build`/`add`
`--sync=merge`) subtree-merges the upstream tip into `name/` with
`git merge -X subtree=name`. This suits the *live* case where **both**
the upstream repo and the monorepo's `name/` keep changing: it does a
real 3-way merge, so an overlap is a normal git conflict you resolve
once and the resolution is recorded (it never re-surfaces), and upstream
merge commits come along too. Passing `--merge` also switches the repo
to merge mode permanently (recorded in `.monorepoize/modes`), so later
runs need no flag; on first use for a diverged or replay-built repo it
establishes a merge baseline. How far upstream each repo has been
integrated is tracked in `.monorepoize/synced`, decoupled from the
mirror branch so a failed sync is never mistaken for "up to date".

Run it against a local clone of the monorepo (it mutates that clone):

```
./update MONOREPO NAME [options]
./update MONOREPO NAME --merge
./update MONOREPO --all
```

- The upstream URL for each repo comes from the committed
  `.monorepoize/sources` file. Override one repo with `-u URL`, or point
  at a `.repos` file with `--repos FILE` (matched by URL basename) for
  monorepos built before sources were recorded. In that case (no
  `.monorepoize/sources` in the monorepo yet) the URLs resolved from the
  `.repos` file are also recorded and committed, so subsequent runs need
  no `--repos`.

- `--same-origin` derives each upstream from the monorepo's own
  `origin`: the origin URL with its last path segment replaced by
  `<name>.git`. Use it only when every repo is eponymous and lives on
  the same origin as the monorepo (e.g. the same GitHub org). It is a
  fallback, tried after any recorded sources or `--repos` file.

- `--merge` uses (and permanently switches the repo to) merge mode; see
  above. `--all` respects each repo's recorded mode, so once a repo is on
  merge mode you don't repeat the flag.

- `--all` updates every repo, printing one summary line each (and
  flagging any whose upstream has gone missing). A repo that hits a merge
  conflict is reported and skipped without disturbing the others.

- `-n`/`--dry-run` reports how many new commits each repo has without
  changing anything.

- `--push` pushes the updated default branch and per-repo refs to
  `origin` afterward.

In **replay** mode `update` only handles linear history: if a repo's new
upstream commits include a merge it is refused (single repo) or skipped
(`--all`). Use `--merge` for repos whose upstream accumulates merge
commits, or whose `name/` subdirectory the monorepo also edits.


# Retiring the original repos

Once the monorepo is the real home of the code, `retire` archives
(default) or deletes the original GitHub repos:

```
./retire MONOREPO                        # archive every source repo
./retire foo.repos                       # same, from a raw .repos file
./retire --delete MONOREPO               # dry run: report what would be deleted
./retire --delete --for-real MONOREPO    # actually delete
```

`SOURCES` is either a local clone of the monorepo (repos come from the
committed `.monorepoize/sources` file) or a raw `.repos` file. Only
`github.com` URLs are acted on; other entries (e.g. local bare-repo
paths) are skipped.

Archiving is reversible so it just happens (preview with `-n`).
Deleting is not, so `--delete` alone is a dry run and only deletes when
`--for-real` is added.

When given a monorepo, `retire` also checks that each repo's current
upstream tip commit is actually present in the monorepo, and skips any
repo with unincorporated commits — run `./update` first, then retire. A
raw `.repos` file offers no such check.

Requires an authenticated `gh` CLI; deleting also needs the
`delete_repo` scope (`gh auth refresh -h github.com -s delete_repo`).


# Pushing to GitHub

After you've built your monorepo, you'll probably want to push it to
GitHub. In the normal case you can probably just create a repo on
GitHub and then do the normal:

```
git remote add origin git@github.com:<whatever>
```

Then to push everything:

```
git push --all origin
git push --tags origin
```

However, if you made a really big repo, you might get an error about
pack files or something when you try to push. This probably means your
repo is too big to push in one go. To get around that just push
specific branches one at a time. Because your repo was built from
smaller repos one good thing to try is pushing the original main
branch from each sub repo. For example within the repo you could make
a list of all the `main` branches (except the top-level main which
would drag in almost everything at once) with this command.

```
git branch | grep main | cut -c 3- | egrep -v '^main$' > mains.txt
```


Then use the `slow_push` script to push one branch at a time:

```
cat mains.txt | ./slow_push
```

This might not push everything (if there were branches in the sub
repos that never got merged to main) but it should get most things so
that you can then do a:

```
git push --all origin
```

to push all the objects and branches.

If the `git push --tags origin` fails, you may need to push fewer tags
at a time. Here's a way to do that assuming you don't already have
files named `tags.txt` or starting with `tags-` in the root directory
of you repo (which you shouldn`t if you just built it).

```
git tag --list > tags.txt
split -l 100 tags.txt tags-
for f in tags-*; do git push origin $(cat $f); done
rm tags-*
rm tags.txt
```
