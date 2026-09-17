// Render an AIX in the real Ink wasm runtime (headless Chromium) with a mocked Neo backend.
// Usage: node harness.mjs <bundle.aix> <outdir> [steps...]
// Steps: key:Enter | key:ArrowDown | wait:ms | shot:name | reload
import { chromium } from 'playwright-core';
import { execFileSync } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const [aix, outDir, ...steps] = process.argv.slice(2);
const here = path.dirname(new URL(import.meta.url).pathname);
fs.mkdirSync(outDir, { recursive: true });
const html = path.join(outDir, 'preview.html');
execFileSync(path.join(here, 'node_modules/.bin/aix'), ['preview', aix, '--html-out', html], { stdio: 'ignore' });
const inkDir = path.join(here, 'node_modules/@yodaos-pkg/ink');
let page = fs.readFileSync(html, 'utf8').replace('https://esm.sh/@yodaos-pkg/ink', '/ink/index.js');
const types = { '.js': 'text/javascript', '.wasm': 'application/wasm', '.html': 'text/html' };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/') { res.writeHead(200, { 'content-type': 'text/html' }); return res.end(page); }
  if (url.pathname.startsWith('/ink/')) {
    const file = path.join(inkDir, url.pathname.slice(5));
    if (fs.existsSync(file)) { res.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream' }); return res.end(fs.readFileSync(file)); }
  }
  res.writeHead(404); res.end();
}).listen(0);
const port = server.address().port;
const browser = await chromium.launch({ args: ['--autoplay-policy=no-user-gesture-required', '--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'] });
const ctx = await browser.newContext({ viewport: { width: 1200, height: 900 } });
const log = [];
const tag = () => new Date().toISOString().slice(17, 23);
ctx.on('console', m => log.push(`${tag()} [console.${m.type()}] ${m.text()}`));
ctx.on('weberror', e => log.push(`${tag()} [pageerror] ${e.error().message}`));
const mode = process.env.MOCK || 'ok';
let polls = 0;
await ctx.route('https://neo-core.1click24.ru/**', async route => {
  const req = route.request();
  const p = new URL(req.url()).pathname;
  log.push(`${tag()} [net] ${req.method()} ${p} ${(req.headers()['content-type'] || '')} body=${(req.postData() || '').length}`);
  const json = (status, body) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body), headers: { 'access-control-allow-origin': '*' } });
  if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': 'GET,POST' } });
  const rid = '54b1dc37-2a21-43ed-8d5b-200e987ed51f';
  if (p === '/v1/auth/check') return json(200, { status: 'ok', user_id: 'minh', device_id: 'rokid-simulator', expires_at: '2099-01-01T00:00:00Z', budget: {} });
  if (p === '/v1/auth/enroll') return json(200, { access_token: 'neo1.1.a.b', expires_at: '2099-01-01T00:00:00Z', refresh_token: 'r'.repeat(64), refresh_expires_at: '2099-01-01T00:00:00Z' });
  if (p === '/v1/auth/refresh') return json(200, { access_token: 'neo1.1.a.b', expires_at: '2099-01-01T00:00:00Z' });
  // Owner approval: the code shows for one poll, then the "button" is pressed. MOCK=pair waits.
  if (p === '/v1/pair/start') { polls = 0; return json(200, { pair_id: 'p'.repeat(32), code: '4821', expires_in: 180, poll_interval: 2 }); }
  if (p === '/v1/pair/poll') {
    polls += 1;
    if (mode === 'pair' || polls < 2) return json(200, { status: 'pending', expires_in: 120, poll_interval: 2 });
    return json(200, { status: 'approved', access_token: 'neo1.1.a.b', expires_at: '2099-01-01T00:00:00Z', refresh_token: 'r'.repeat(64), refresh_expires_at: '2099-01-01T00:00:00Z' });
  }
  if (p === '/v1/diagnostics') {
    for (const event of JSON.parse(req.postData() || '{}').events || []) log.push(`${tag()} [event] ${event.code} ${event.phase || ''} ${event.detail || ''} ${event.value ?? ''}`);
    return route.fulfill({ status: 204, headers: { 'access-control-allow-origin': '*' } });
  }
  if (p === '/v1/transcribe' && process.env.SAVE_AUDIO) {
    fs.writeFileSync(path.join(outDir, 'upload.json'), req.postData() || '');
  }
  if (p === '/v1/transcribe') return json(200, { text: 'Привет, Нео', request_id: rid });
  if (p === '/v1/speech') return route.fulfill({ status: 200, contentType: 'audio/pcm', body: Buffer.alloc(4800), headers: { 'access-control-allow-origin': '*' } });
  if (p === '/v1/ask') {
    const answer = mode === 'long' || mode === 'huge' ? 'Привет! Neo на связи. '.repeat(mode === 'huge' ? 80 : 20) : 'В Краснодаре сейчас около 20 °C, преимущественно облачно. Сегодня ожидается от 15 до 23 °C.';
    const events = [['transcript', { text: 'Скажи, какая погода в Краснодаре', request_id: rid }]]
      .concat(answer.split(' ').map(word => ['delta', { text: word + ' ' }]))
      .concat([['done', { message: answer, session_id: rid, provider: 'openai', request_id: rid, sources: [], budget: {} }]]);
    const body = events.map(([name, data]) => `event: ${name}\ndata: ${JSON.stringify(data)}\n\n`).join('');
    return route.fulfill({ status: 200, contentType: 'text/event-stream', body, headers: { 'access-control-allow-origin': '*' } });
  }
  if (p === '/v1/chat') {
    await new Promise(r => setTimeout(r, 300));
    return json(200, { session_id: rid, message: 'Привет! Neo на связи. '.repeat(mode === 'long' ? 30 : 1), provider: 'mock', request_id: rid, sources: [], memory_action: false, context_reset: false, budget: {} });
  }
  return json(404, {});
});
const tab = await ctx.newPage();
await tab.goto(`http://127.0.0.1:${port}/`);
await tab.waitForFunction(() => /ready|error|fail/i.test(document.getElementById('preview-status')?.textContent || ''), null, { timeout: 60000 }).catch(() => {});
log.push(`${tag()} [status] ${await tab.locator('#preview-status').textContent()}`);
const shot = async name => { await tab.locator('#canvas-host').screenshot({ path: path.join(outDir, name + '.png') }); log.push(`${tag()} [shot] ${name}`); };
for (const step of steps) {
  const [kind, arg] = step.split(':');
  if (kind === 'wait') await tab.waitForTimeout(Number(arg));
  else if (kind === 'shot') await shot(arg);
  else if (kind === 'key' && await tab.locator(`.control-button[data-key="${arg}"]`).count()) await tab.click(`.control-button[data-key="${arg}"]`);
  else if (kind === 'key') {
    // Keys without a simulator button (Craft's swipe controls send ArrowLeft/ArrowRight).
    await tab.evaluate(key => {
      const canvas = document.getElementById('preview-canvas');
      canvas.focus();
      for (const type of ['keydown', 'keyup']) canvas.dispatchEvent(new KeyboardEvent(type, { key, code: key, bubbles: true, cancelable: true }));
    }, arg);
  }
  else if (kind === 'eval') log.push(`${tag()} [eval] ${await tab.evaluate(arg)}`);
  log.push(`${tag()} [step] ${step}`);
}
console.log(log.join('\n'));
await browser.close();
server.close();
