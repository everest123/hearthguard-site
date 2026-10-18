#!/usr/bin/env bash
# My Maestro AI: move a hub installed from the old private repository to the public one,
# https://github.com/mymaestroai/mymaestroai (a fresh history).
#
# Most hubs move themselves: open Update, which offers "Move to the public repository", then restart.
# Use this script when Update says "Update blocked" (hubs installed before 2026-10-14) or cannot reach GitHub.
#
# Run it inside the hub folder (the one with server.js):
#   curl -fsSL https://www.mymaestroai.ai/move.sh | bash
# or name the folder:
#   curl -fsSL https://www.mymaestroai.ai/move.sh | bash -s -- --dir ~/agent-hub
#
# What it does: backs up the folder (node_modules left out) to a .tgz next to it, keeps the current
# position on a backup branch, points the hub at the public repository and switches to its history.
# data/, workspaces/, .env and other per-install files stay where they are; any edited program file is
# copied aside first. Then restart the hub once.
set -u
export GIT_TERMINAL_PROMPT=0   # the public repository needs no sign-in; never wait for one

NEW_REPO="https://github.com/mymaestroai/mymaestroai.git"
DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2:-}"; shift 2 ;;
    --dir=*) DIR="${1#--dir=}"; shift ;;
    -h|--help) sed -n '2,16p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "Unknown option: $1"; exit 2 ;;
  esac
done

fail() { echo; echo "STOPPED: $*"; exit 1; }
if [ -n "$DIR" ]; then
  case "$DIR" in "~"*) DIR="$HOME${DIR#\~}" ;; esac
  cd "$DIR" 2>/dev/null || fail "no folder $DIR."
fi
[ -f server.js ] && [ -d .git ] || fail "run this inside the hub folder (the one with server.js), or pass --dir <folder>. Nothing was changed."
command -v git >/dev/null 2>&1 || fail "git is not installed. Nothing was changed."

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
target=main
[ "$branch" = dev ] && target=dev
old_url=$(git remote get-url origin 2>/dev/null || echo "")

stamp=$(date +%Y%m%d-%H%M%S)
backup="../hub-backup-$stamp.tgz"
keep="../hub-kept-files-$stamp"

echo "Moving the hub in $(pwd) to $NEW_REPO (branch $target)."

echo "1/6 Checking the public repository..."
if [ "$old_url" = "$NEW_REPO" ] && git rev-parse -q --verify "refs/remotes/origin/$target" >/dev/null \
   && git fetch -q --no-tags origin "+refs/heads/$target:refs/remotes/origin/$target" 2>/dev/null \
   && [ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$target")" ]; then
  echo "    Already moved and up to date. Nothing to do."
  exit 0
fi
git ls-remote --exit-code "$NEW_REPO" "refs/heads/$target" >/dev/null 2>&1 || fail "could not reach $NEW_REPO. Nothing was changed."

echo "2/6 Backing up this folder to $backup (node_modules left out)..."
tar --exclude node_modules -czf "$backup" . || fail "backup failed. Nothing was changed."

echo "3/6 Fetching the public repository..."
git fetch -q --no-tags "$NEW_REPO" "+refs/heads/$target:refs/hub-move/target" || fail "fetch failed. Nothing was changed."
git branch -f "backup/before-move-$stamp" HEAD 2>/dev/null || true

echo "4/6 Saving your edited files and the files the new version does not track..."
mkdir -p "$keep"
{ git diff --name-only HEAD 2>/dev/null; git diff --name-only --diff-filter=D HEAD refs/hub-move/target; } | sort -u | while IFS= read -r f; do
  if [ -f "$f" ]; then mkdir -p "$keep/$(dirname "$f")"; cp -p "$f" "$keep/$f"; fi
done
# Untracked files where the new version has a file are replaced by the switch: copy them too.
git ls-tree -r --name-only refs/hub-move/target | while IFS= read -r f; do
  if [ -f "$f" ] && ! git ls-files --error-unmatch "$f" >/dev/null 2>&1; then mkdir -p "$keep/$(dirname "$f")"; cp -p "$f" "$keep/$f"; fi
done

echo "5/6 Switching to the public repository..."
if [ -n "$old_url" ]; then git remote set-url origin "$NEW_REPO"; else git remote add origin "$NEW_REPO"; fi
if ! git fetch -q --prune --no-tags origin; then
  [ -n "$old_url" ] && git remote set-url origin "$old_url"
  fail "fetch from the public repository failed; origin restored. Your backup is $backup."
fi
git checkout -f -q -B "$target" "origin/$target" || fail "switch failed. Your backup is $backup; the previous position is branch backup/before-move-$stamp."
git branch -q --set-upstream-to="origin/$target" "$target" 2>/dev/null || true
git update-ref -d refs/hub-move/target 2>/dev/null || true

echo "6/6 Putting your own files back..."
# Only top-level files the new version ignores come back (the per-install agent group, voice and roster files);
# retired program files stay in the copies folder.
(cd "$keep" && find . -type f) | while IFS= read -r f; do
  f=${f#./}
  case "$f" in */*) continue ;; esac
  if git check-ignore -q "$f" && [ ! -e "$f" ]; then mkdir -p "$(dirname "$f")"; cp -p "$keep/$f" "$f"; echo "    kept $f"; fi
done
if ! git diff --quiet "backup/before-move-$stamp" HEAD -- package-lock.json package.json 2>/dev/null; then
  echo "    packages changed: installing..."
  npm ci --omit=dev --no-audit --no-fund >/dev/null 2>&1 || npm install --omit=dev --no-audit --no-fund >/dev/null 2>&1 \
    || echo "    npm failed: run 'npm ci --omit=dev' in this folder"
fi

echo
echo "Done. This folder now follows $NEW_REPO"
echo "  now on:   $(git log -1 --date=short --format='%h  %s  (%ad)')"
echo "  backup:   $backup"
echo "  previous position: branch backup/before-move-$stamp"
[ -n "$(ls -A "$keep" 2>/dev/null)" ] && echo "  copies of edited and retired files: $keep"
echo
echo "Next: restart the hub once (in the app: Restart hub; or stop it and start it again the way you normally do)."
