# Shared helpers for monorepoize test scripts. Source this after computing ROOT.
#
# Provides a tiny PASS/FAIL harness (ok/bad/hr/finish), a git version check
# (git_ge), and setup_git_env, which isolates all git configuration into a
# throwaway file so the tests never read or write the user's real global config
# or commit identity. Not meant to be run directly.

pass=0
fail=0

ok()  { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }
hr()  { printf '\n==== %s ====\n' "$*"; }

# finish: print the tally and exit non-zero if anything failed.
finish() {
  printf '\n==== RESULT: %d passed, %d failed ====\n' "$pass" "$fail"
  exit "$fail"
}

# git_ge MAJOR MINOR -> success if the running git is at least that version.
git_ge() {
  local v maj rest min
  v=$(git version | awk '{print $3}')
  maj=${v%%.*}; rest=${v#*.}; min=${rest%%.*}
  [ "$maj" -gt "$1" ] || { [ "$maj" -eq "$1" ] && [ "$min" -ge "$2" ]; }
}

# setup_git_env DIR: point git at an isolated global/system config under DIR and
# set a fixed identity, so the tests are hermetic and don't touch the real user.
setup_git_env() {
  export GIT_CONFIG_GLOBAL="$1/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
  git config --global init.defaultBranch main
  git config --global protocol.file.allow always
}
