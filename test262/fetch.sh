#!/usr/bin/env bash
# Fetch or update the tc39/test262 suite into test262/suite (gitignored).
# The checkout is ~54k files; it is intentionally NOT committed to this repo.
set -euo pipefail
cd "$(dirname "$0")"

if [ -d suite/.git ]; then
  echo "Updating test262/suite ..."
  git -C suite pull --ff-only origin main
else
  echo "Cloning test262 (shallow) into test262/suite ..."
  git clone --depth 1 https://github.com/tc39/test262 suite
fi

echo "Test files: $(find suite/test -name '*.js' | wc -l | tr -d ' ')"
