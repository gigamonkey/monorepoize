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