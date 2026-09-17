# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This repository is the NEO client for Rokid Glasses: a single-page AIUI agent that records a
question, sends it to the personal Neo server (`https://neo-core.1click24.ru`, private repository
`neo-core`) and shows the streamed answer. The repository root *is* the agent package, so Rokid
Craft can import it straight from GitHub. User-facing text is Russian; `README.md` is the
behavioral spec.

## Commands

```bash
node --test tests/page.test.cjs                        # page logic in an Ink-like fake host
node --test --test-name-pattern='menu has' tests/page.test.cjs

cd tools/ink-preview && npm install && npm run pack    # -> dist/neo-glasses.aix
./run.sh dist/neo-glasses.aix out/check wait:2500 shot:idle key:Enter wait:1000 shot:talk
```

`run.sh` renders the package in the real Ink wasm runtime (Docker + the Playwright image) with a
mocked Neo backend, writes PNG screenshots and prints the page console. Keys: `Enter` = tap,
`ArrowUp`/`ArrowDown`/`ArrowLeft`/`ArrowRight` = swipes, `GlobalHook` = temple touch,
`Backspace` = back. `MOCK=long|huge` returns longer answers; `MOCK=pair` keeps the approval
screen up (nobody presses the button in the bot). The web host cannot recognize or
synthesize speech, so voice paths are covered only by the Node tests and on the glasses.

## Layout

- `pages/index/index.ink` — the whole client: `<script def>` config, `<script setup>` logic,
  `<page>` template, `<style>`.
- `AGENTS.md` — the agent's identity and description; Rokid uses it to invoke the agent.
- `app.json` — pages, window title, `RECORD_AUDIO` and `INTERNET` permissions.
- `.aixignore` — keeps `tests/`, `tools/`, `.git/`, `.claude/` and docs out of the AIX package.
- No secret of any kind lives here. Access is granted per device: `pair()` asks
  `/v1/pair/start`, shows the four-digit code, polls `/v1/pair/poll` until the owner presses
  Подтвердить in the Telegram bot, and stores only the resulting refresh token in
  `neo.access.v1` (`{refresh_token, build, at}`). `renew()` reuses it while the build matches
  and it is under 30 days old; a silent reconnection during a question must never pair, because
  a confirmation has to follow a request the owner can see on the glasses.
- `.claude/skills/aiui-dev` — the official Rokid reference. **Load it before editing** and use
  only the APIs, components and WXSS it lists.

## Ink runtime traps (verified in the real runtime; Node does not reproduce them)

- `clearTimeout(undefined|null)` throws: always use `stopTimer()`.
- `<text>` ignores `\n` and containers never clip overflow: text is wrapped in JS (`wrap()`,
  `ROWS`) and only the rows that fit `BODY_HEIGHT` are rendered.
- Inline `transform` makes an element invisible: animate sizes, margins and opacity instead.
- No `word-break`, `white-space`, `overflow`, `animation` in WXSS.
- `fetch` needs a `headers` object; `crypto.randomUUID` is missing.
- Static `import` of a module the firmware lacks fails the whole page: `wx` is loaded lazily.
- `setData` updates `this.data` synchronously, but frequent calls are throttled: one `setData`
  per frame (`render()` merges `bodyData()`/`menuData()`), and a single 150 ms loop paints the face.

## Structure

- Every host callback goes through `guard()`, so an exception never leaves the UI stuck.
- Page state lives on `this` (`phase`, `screen`, `voice`, `prefs`, `history`); `render()` projects
  it into `data`.
- `voice` is one object per listening turn; `stopVoice()` releases everything and stale callbacks
  check `this.voice === voice`.
- Gestures (`key()`/`gesture()`) follow the sequences recorded from the glasses: a swipe is
  `GlobalHook` then an arrow pair, a tap is `GlobalHook` then `Enter` ~500 ms later.
- `recorder.start()` must run synchronously inside the tap handler (no `await` before it).

## Tests

`tests/page.test.cjs` extracts the `<script setup>` block, swaps `export default` for a global,
and runs it in `node:vm` with a fake host: manual clock, throwing `clearTimeout`, fake `wx`,
recorder, speech synthesis and `/v1/ask` Server-Sent Events. `ready()` starts from a device the
owner has already confirmed (`confirmed()` seeds `neo.access.v1`); pairing has its own tests
that use `host()` plus `boot()`. The suite fails if a secret-looking literal appears in the page
or if a token file reappears in the repository.

Passing Node tests and Ink web renders do not prove speech recognition or synthesis on the
physical glasses; report those separately.
