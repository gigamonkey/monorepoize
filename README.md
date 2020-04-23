# To create a monorepo.

- Make a file containing the git URLs of the repos you want to
  combine. These can be paths to bare repos (ideally created with `git
  clone --mirror`) or `git@github.com:` URLs. This file should be
  named `something.repos` where `something` is the name of the new
  monorepo you want to create.

- Run `./build something.repos`. It should create a directory named
  `something` and incorporate all the repos listed in the `.repos`
  file, pushing down all branch and tag names to be prefixed by the
  name of the repo being added. So if the subrepo is `foo.git` the
  branches will be `foo/whatever`. It will then look for a
  `foo/master` branch and if it exists, push the contents of that
  branch into a `foo` subdirectory and merge it to the monorepo's
  master branch.

- After the monorepo is built, look for `empty-repo.txt` and
  `no-branch.txt` files in the subdirectories. These are created if
  the repo incorporated had either no changes (`empty-repo.txt`) or no
  `master` branch. In the latter case the `no-branch.txt` file will
  contain a list of the refs from the repo. If there's an appropriate
  branch (say the repo used `prod` instead of `master`) you can fix
  things up with the `pushdown` script. In the monorepo remove the
  `no-branch.txt` and then run `./pushdown foo/prod` to put the
  contents of the `foo/prod` branch into the `foo` subdirectory and
  merge them to `master`.


# Pushing to github

After you've built your monorepo, you'll probably want to push hit to
github. In the normal case you can probably just create a repo on
Github and then do the normal:

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
smaller repos one good thing to try is pushing the original master
branch from each sub repo. For example within the repo you could make
a list of all the `master` branches (except the main master which
would drag in almost everything at once) with this command.

```
git branch | grep master | cut -c 3- | egrep -v '^master$' > masters.txt
```


Then use the `slow_push` script to push one branch at a time:

```
cat masters.txt | ./slow_push
```

This might not push everything (if there were branches in the sub
repos that never got merged to master) but it should get most things
so that you can then do a:

```
git push --all origin
```

to push all the objects and branches.

If trying to push with `--tags` fails, you may need to push fewer tags
at a time. Here's a way to do that assuming you don't already have
files named `tags.txt` or starting with `tags-` in the root directory
of you repo (which you shouldn`t if you just built it).

```
git tag --list > tags.txt
split -l 100 tags.txt tags-
for f in tags-??; do git push origin $(cat $f); done
rm tags-*
rm tags.txt
```
