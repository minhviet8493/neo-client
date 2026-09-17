#!/bin/sh
# Render an AIX in headless Chromium (Playwright image) with a mocked Neo backend.
# Usage: ./run.sh dist/neo-glasses.aix out/name wait:2500 key:Enter wait:1000 shot:after
# Keys: Enter (tap), ArrowUp/ArrowDown (swipes), Backspace (back). MOCK=long gives a long answer.
cd "$(dirname "$0")"
exec docker run --rm --init --ipc=host -u "$(id -u):$(id -g)" -e HOME=/tmp -e MOCK="${MOCK:-ok}" -e SAVE_AUDIO="${SAVE_AUDIO:-}" \
  -v "$PWD":/w -w /w mcr.microsoft.com/playwright:v1.63.0-noble timeout 240 node harness.mjs "$@"
