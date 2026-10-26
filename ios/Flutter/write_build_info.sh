#!/bin/sh
set -eu

# Thin Binary runs after the app's Info.plist has been generated and before code
# signing. Read Git on every build so switching branches cannot reuse stale data.
project_root="${SRCROOT}/.."
app_plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
git_branch="$(git -C "$project_root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
git_commit="$(git -C "$project_root" rev-parse --verify HEAD 2>/dev/null || true)"

for key in ShuYoGitBranch ShuYoGitCommit; do
  /usr/libexec/PlistBuddy -c "Delete :$key" "$app_plist" >/dev/null 2>&1 || true
done
/usr/bin/plutil -insert ShuYoGitBranch -string "$git_branch" "$app_plist"
/usr/bin/plutil -insert ShuYoGitCommit -string "$git_commit" "$app_plist"
