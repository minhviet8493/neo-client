const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const ink = fs.readFileSync(path.join(__dirname, '../pages/index/index.ink'), 'utf8');
const script = ink.match(/<script setup>([\s\S]*?)<\/script>/)[1];
const template = ink.match(/<page>([\s\S]*?)<\/page>/)[1];
const source = script
  .replace("import('../../config.local.js')", 'globalThis.__config()')
  .replace('export default', 'globalThis.page =');
const TOKEN = 'test-device-token-' + 'a'.repeat(40);
const ID = '54b1dc37-2a21-43ed-8d5b-200e987ed51f';
const plain = value => JSON.parse(JSON.stringify(value));
const flush = async (rounds = 8) => { for (let i = 0; i < rounds; i++) await new Promise(r => setImmediate(r)); };

// A Server-Sent Events response, as /v1/ask returns it.
function sseResponse(events, { chunked = true, reader = true } = {}) {
  const text = events.map(([name, data]) => `event: ${name}\ndata: ${JSON.stringify(data)}\n\n`).join('');
  const parts = chunked ? text.split(/(?<=\n\n)/) : [text];
  let index = 0;
  return {
    ok: true, status: 200,
    headers: { get: () => 'text/event-stream' },
    body: !reader ? {} : {
      getReader: () => ({
        read: async () => index < parts.length
          ? { done: false, value: Buffer.from(parts[index++], 'utf8') }
          : { done: true }
      })
    },
    text: async () => text,
    json: async () => { throw new Error('stream'); }
  };
}

function askEvents(message = 'Ответ Neo.', extra = {}) {
  const words = message.split(' ').map((word, i, all) => ['delta', { text: word + (i < all.length - 1 ? ' ' : '') }]);
  return [
    ['transcript', { text: 'Привет, Нео', request_id: ID }],
    ...words,
    ['done', Object.assign({ message, session_id: ID, provider: 'openai', request_id: ID, sources: [], budget: {} }, extra)]
  ];
}

function response(status, body, binary) {
  return {
    ok: status >= 200 && status < 300, status,
    headers: { get: () => null },
    json: async () => { if (body === undefined) throw new Error('no json'); return body; },
    arrayBuffer: async () => binary
  };
}

// Builds a page inside a fake Ink host with a controllable clock.
function host(options = {}) {
  let now = 1_000_000;
  let seq = 0;
  const timers = new Map();
  const requests = [];
  const recognitions = [];
  const storage = new Map(Object.entries(options.storage || {}));
  const routes = Object.assign({
    '/v1/auth/check': () => response(200, { status: 'ok', user_id: 'minh', device_id: 'rokid-simulator', expires_at: '2099-01-01T00:00:00Z' }),
    '/v1/auth/enroll': () => response(200, { access_token: 'neo1.a.b.c', refresh_token: 'r'.repeat(64) }),
    '/v1/auth/refresh': () => response(200, { access_token: 'neo1.renewed.b.c' }),
    '/v1/chat': () => response(200, { session_id: ID, message: 'Ответ Neo.', provider: 'openai', request_id: ID, sources: [] }),
    '/v1/transcribe': () => response(200, { text: 'Привет, Нео', request_id: ID }),
    '/v1/speech': () => response(200, undefined, new Int16Array(2400).buffer),
    '/v1/diagnostics': () => response(204),
    '/v1/ask': () => sseResponse(askEvents())
  }, options.routes || {});

  class FakeDate extends Date { static now() { return now; } }
  class FakeRecognition {
    constructor() {
      if (options.recognitionThrows) throw new Error('boom');
      this.started = 0; this.stopped = 0; this.aborted = 0;
      recognitions.push(this);
    }
    start() { this.started++; if (options.startThrows) throw options.startThrows; }
    stop() { this.stopped++; }
    abort() { this.aborted++; }
    emit(name, event = {}) { if (typeof this['on' + name] === 'function') this['on' + name](event); }
    say(text, isFinal = true) {
      const result = [{ transcript: text }];
      result.isFinal = isFinal;
      this.emit('result', { resultIndex: 0, results: [result] });
    }
  }
  const recorder = {
    handlers: {}, started: 0, stopped: 0,
    start(config) { this.started++; this.config = config; return Promise.resolve(); },
    stop() { this.stopped++; return Promise.resolve(); },
    paused: 0, resumed: 0,
    pause() { this.paused++; if (options.pauseThrows) throw new Error('no pause'); return Promise.resolve(); },
    resume() { this.resumed++; if (options.resumeThrows) throw new Error('no resume'); return Promise.resolve(); },
    onResume(fn) { this.handlers.resume = fn; },
    onFrameRecorded(fn) { this.handlers.frame = fn; },
    onError(fn) { this.handlers.error = fn; },
    onInterruptionBegin(fn) { this.handlers.interrupt = fn; },
    onStop(fn) { this.handlers.stop = fn; }
  };
  const played = [];
  const globals = {
    // Stands in for the lazy import of config.local.js.
    __config: () => options.noToken
      ? Promise.reject(new Error('missing'))
      : Promise.resolve({ default: { deviceToken: TOKEN } }),
    console: { log() {}, error() {} },
    Date: FakeDate,
    AbortController,
    // Ink converts timer ids to i32 and throws for anything else.
    setTimeout: (fn, ms) => { const id = ++seq; timers.set(id, { fn, at: now + (ms || 0) }); return id; },
    clearTimeout: id => {
      if (typeof id !== 'number') throw new TypeError(`Error converting from js '${id}' into type 'i32'`);
      timers.delete(id);
    },
    localStorage: {
      getItem: key => storage.has(key) ? storage.get(key) : null,
      setItem: (key, value) => storage.set(key, String(value)),
      removeItem: key => storage.delete(key)
    },
    fetch: async (url, init) => {
      assert.ok(init.headers && typeof init.headers === 'object', 'Ink fetch requires a headers object');
      const route = url.replace('https://neo-core.1click24.ru', '');
      const body = init.body === undefined ? undefined : JSON.parse(init.body);
      requests.push({ route, init, body });
      const handler = routes[route];
      if (!handler) throw new Error('unexpected ' + route);
      return handler({ body, init, count: requests.filter(r => r.route === route).length });
    },
    navigator: { userAgent: 'AIUI/1.0 Ink/0.18.0', versions: { ink: '0.18.0' }, language: 'ru-RU' }
  };
  if (!options.noWx) {
    globals.wx = { media: { getRecorderManager: () => options.noRecorder ? undefined : recorder } };
    if (!options.noBase64) globals.wx.arrayBufferToBase64 = buffer => Buffer.from(buffer).toString('base64');
  }
  if (options.hostRecognition) globals.SpeechRecognition = FakeRecognition;
  if (options.rokidVoice) {
    globals.SpeechSynthesisUtterance = class { constructor(text) { this.text = text; } };
    globals.speechSynthesis = {
      speak(utterance, mode) {
        played.push(utterance.text);
        played.modes = (played.modes || []).concat(mode);
        played.langs = (played.langs || []).concat(utterance.lang);
        played.recording = recorder.paused > recorder.resumed ? 'paused' : 'live';
      }
    };
  }
  if (options.audioContext) {
    globals.AudioContext = class {
      constructor() { this.destination = {}; }
      resume() { return Promise.resolve(); }
      close() { return Promise.resolve(); }
      createBuffer(channels, length) { return { length, copyToChannel() {} }; }
      createBufferSource() {
        const node = { connect() {}, disconnect() {}, stop() {}, start() { played.push('neo-pcm'); node.started = true; } };
        played.node = node;
        return node;
      }
    };
  }
  globals.TextDecoder = TextDecoder;
  globals.globalThis = globals;
  const context = vm.createContext(globals);
  vm.runInContext(source, context);
  const page = context.page;
  page.data = JSON.parse(JSON.stringify(page.data));
  page.setData = patch => Object.assign(page.data, patch);

  const env = {
    page, requests, recognitions, recorder, storage, played, timers,
    get now() { return now; },
    last: () => recognitions[recognitions.length - 1],
    async advance(ms) {
      const end = now + ms;
      for (;;) {
        const due = [...timers.entries()].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
        if (!due) break;
        timers.delete(due[0]);
        now = Math.max(now, due[1].at);
        due[1].fn();
        await flush();
      }
      now = end;
      await flush();
    },
    edge(type, code, extra = {}) {
      const event = { code, prevented: false, preventDefault() { this.prevented = true; }, ...extra };
      (type === 'down' ? page.onKeyDown : page.onKeyUp).call(page, event);
      return event;
    },
    // A physical press: keydown then keyup, as the Craft simulator sends them.
    key(code, extra = {}) {
      const down = env.edge('down', code, extra);
      now += 60;
      const up = env.edge('up', code, extra);
      return { prevented: down.prevented && up.prevented, down, up };
    },
    tick(ms) { now += ms; },
    async tap() { now += 1000; env.key('Enter'); await flush(); },
    async swipe(code) { now += 1000; env.key(code); await flush(); },
    // One real-time frame of mono s16 PCM; the clock advances as audio would.
    frame(level, ms = 250, rate = 16000) {
      const samples = new Int16Array(rate / 1000 * ms);
      for (let i = 0; i < samples.length; i++) samples[i] = Math.round(level * 32767 * (i % 2 ? 1 : -1));
      now += ms;
      recorder.handlers.frame({ frameBuffer: samples.buffer });
    },
    text: () => page.data.bodyLines.filter(line => line.cls === 'line').map(line => line.text).join('\n'),
    rows: () => page.data.bodyLines.map(line => line.text),
    // Shown only for trouble; when visible it must fit the two rendered rows.
    status: () => {
      const shown = page.data.statusLines.map(line => line.text).join(' ');
      if (shown) assert.equal(shown, (page.alert || page.status).trim().split(/\s+/).join(' '), 'status is cut off');
      return page.alert || page.status;
    },
    state: () => page.data.stateWord
  };
  return env;
}

async function ready(options) {
  const env = host(options);
  env.page.onLoad();
  env.page.onShow();
  await flush();
  assert.equal(env.page.data.phase, 'idle', env.page.status);
  return env;
}

const PREFS = 'neo.preferences.v5';
const prefs = value => ({ [PREFS]: JSON.stringify(value) });
const chats = env => env.requests.filter(r => r.route === '/v1/chat');
const asks = env => env.requests.filter(r => r.route === '/v1/ask');
const telemetry = env => JSON.stringify(env.requests.filter(r => r.route === '/v1/diagnostics').map(r => r.body));

// A spoken phrase as the glasses record it: silence while the rate is measured, speech, a pause.
async function sayPhrase(env, { lead = 4, speech = 3, level = 0.2, speak = true } = {}) {
  for (let i = 0; i < lead; i++) env.frame(0);
  for (let i = 0; i < speech; i++) env.frame(level);
  for (let i = 0; i < 4; i++) env.frame(0);
  await flush(16);
  // The answer is shown at once; with the voice on the turn waits for the speech to finish.
  if (speak) await env.advance(4000);
}

// Gesture sequences recorded from the owner's glasses (AIUI 0.17) on 2026-09-17.
function glassesSwipe(env, forward) {
  env.key('GlobalHook');
  env.tick(100);
  env.key(forward ? 'ArrowRight' : 'ArrowLeft');
  env.tick(3);
  env.key(forward ? 'ArrowDown' : 'ArrowUp');
}

async function glassesTap(env) {
  env.key('GlobalHook');
  await env.advance(480);
  env.key('Enter');
  await flush();
}

const selected = env => env.page.data.actions.findIndex(a => a.cls.includes('action-on'));
const menuFocus = env => env.page.data.menuRows.find(r => r.cls.includes('row-on')).id;

test('connects with the embedded token and enrolls a renewable binding', async () => {
  const env = await ready();
  const check = env.requests.find(r => r.route === '/v1/auth/check');
  assert.equal(check.init.headers.Authorization, 'Bearer ' + TOKEN);
  assert.ok(env.requests.some(r => r.route === '/v1/auth/enroll'));
  assert.equal(JSON.parse(env.storage.get('neo.device.v1')).refresh_token, 'r'.repeat(64));
  assert.equal(env.page.data.actions[0].label, 'Говорить');
  assert.match(env.text(), /Коснитесь/);
  assert.deepEqual(plain(env.page.data.statusLines), [], 'the status line is hidden when all is well');
});

test('a saved binding is renewed and used instead of the embedded token', async () => {
  const env = await ready({ storage: { 'neo.device.v1': JSON.stringify({ refresh_token: 'x'.repeat(64) }) } });
  assert.deepEqual(env.requests.map(r => r.route).filter(r => r !== '/v1/diagnostics'), ['/v1/auth/refresh', '/v1/auth/check']);
  assert.equal(env.requests[1].init.headers.Authorization, 'Bearer neo1.renewed.b.c');
});

test('an offline start keeps retrying by itself and says so', async () => {
  let online = false;
  const env = host({ routes: { '/v1/auth/check': () => {
    if (!online) throw new Error('offline');
    return response(200, { status: 'ok', user_id: 'minh', device_id: 'd' });
  } } });
  env.page.onLoad(); env.page.onShow(); await flush();
  assert.equal(env.page.data.phase, 'offline');
  assert.match(env.status(), /Повтор через 5 с/);
  assert.equal(env.page.data.statusLines.length > 0, true, 'trouble is shown');
  await env.advance(5000);
  assert.match(env.status(), /Повтор через 15 с/);
  online = true;
  await env.advance(15000);
  assert.equal(env.page.data.phase, 'idle');
});

test('one request carries the question and streams the answer back', async () => {
  const env = await ready();
  await env.tap();
  assert.equal(env.recorder.started, 1, 'recording starts inside the tap');
  assert.deepEqual(plain(env.recorder.config), { sampleRate: 16000, numberOfChannels: 1, format: 'pcm', frameSize: 250 });
  env.frame(0);
  assert.equal(env.page.data.phase, 'listening');
  assert.equal(env.state(), 'слушаю');
  await sayPhrase(env, { lead: 3 });
  assert.equal(asks(env).length, 1, 'no separate transcribe call');
  assert.equal(chats(env).length, 0);
  const ask = asks(env)[0];
  assert.equal(ask.init.headers.Accept, 'text/event-stream');
  assert.equal(ask.init.headers.Authorization, 'Bearer ' + TOKEN);
  assert.deepEqual(Object.keys(ask.body).sort(), ['client_message_id', 'device_id', 'user_id', 'wav_base64']);
  const wav = Buffer.from(ask.body.wav_base64, 'base64');
  assert.equal(wav.toString('ascii', 0, 4), 'RIFF');
  assert.equal(wav.readUInt32LE(24), 16000);
  assert.equal(env.rows()[0], 'Вы: Привет, Нео');
  assert.equal(env.text(), 'Ответ Neo.');
  assert.equal(env.page.data.phase, 'listening', 'the conversation continues');
  assert.equal(env.recorder.started, 1, 'one recording serves the whole conversation');
  await sayPhrase(env, { lead: 1 });
  assert.equal(asks(env)[1].body.session_id, ID, 'the session continues');
});

test('the answer is shown as it streams and then in full', async () => {
  const env = await ready();
  const seen = [];
  const original = env.page.setData;
  env.page.setData = patch => {
    const result = original(patch);
    const text = env.page.streaming;
    if (text && seen[seen.length - 1] !== text) seen.push(text);
    return result;
  };
  await env.tap();
  await sayPhrase(env, { lead: 3 });
  assert.ok(seen.length >= 1, 'parts were shown while the answer arrived');
  assert.ok(seen.every(text => 'Ответ Neo.'.startsWith(text.trim())), seen.join('|'));
  assert.equal(env.text(), 'Ответ Neo.', 'the whole answer stands in the feed');
  assert.equal(env.page.streaming, '');
});

test('a host without streaming reads still gets the whole answer', async () => {
  const env = await ready({ routes: { '/v1/ask': () => sseResponse(askEvents(), { reader: false }) } });
  await env.tap();
  await sayPhrase(env, { lead: 3 });
  assert.equal(env.text(), 'Ответ Neo.');
  env.page.flushEvents();
  await flush();
  assert.match(telemetry(env), /stream:buffered/);
});

test('ten seconds of silence pause the conversation', async () => {
  const env = await ready();
  await env.tap();
  for (let i = 0; i < 43; i++) env.frame(0);
  await env.advance(200);
  assert.equal(env.page.data.phase, 'paused');
  assert.equal(env.recorder.stopped, 1);
  await flush();
  assert.equal(env.timers.size - (env.page.telemetryTimer ? 1 : 0), 0, 'no timers are left running');
});

test('a phrase ends after a short pause', async () => {
  const env = await ready();
  await env.tap();
  for (let i = 0; i < 4; i++) env.frame(0);
  for (let i = 0; i < 3; i++) env.frame(0.2);
  env.frame(0, 250);
  env.frame(0, 250);
  env.frame(0, 250);
  env.frame(0, 250);
  await flush(16);
  assert.equal(asks(env).length, 1, 'about 0.8 s of silence is enough');
});

test('a microphone that never delivers audio reports a timeout', async () => {
  const env = await ready();
  await env.tap();
  await env.advance(8000);
  assert.equal(env.page.data.phase, 'error');
  assert.match(env.status(), /Микрофон не включился/);
  assert.equal(env.recorder.stopped, 1);
});

test('noise that the server cannot transcribe keeps the conversation going', async () => {
  const env = await ready({ routes: { '/v1/ask': () => response(502, { error: { code: 'invalid_transcription' } }) } });
  await env.tap();
  await sayPhrase(env);
  assert.equal(env.page.data.phase, 'listening');
  assert.match(env.status(), /Не расслышал/);
});

test('an expired access token is renewed silently and the phrase repeated', async () => {
  let calls = 0;
  const env = await ready({ routes: { '/v1/ask': () => (++calls === 1 ? response(401, { error: { code: 'unauthorized' } }) : sseResponse(askEvents())) } });
  await env.tap();
  await sayPhrase(env);
  assert.equal(env.page.data.phase, 'listening');
  assert.match(env.status(), /Связь восстановлена/);
  assert.equal(env.requests.filter(r => r.route === '/v1/auth/check').length, 2);
  await sayPhrase(env, { lead: 1 });
  assert.equal(env.text(), 'Ответ Neo.');
});

test('server errors are explained', async () => {
  const env = await ready({ routes: { '/v1/ask': () => response(429, { error: { code: 'budget_exceeded' } }) } });
  await env.tap();
  await sayPhrase(env);
  assert.equal(env.page.data.phase, 'error');
  assert.match(env.status(), /бюджет/);
  assert.equal(env.recorder.stopped, 1);

  const cut = await ready({ routes: { '/v1/ask': () => sseResponse([['transcript', { text: 'Вопрос' }], ['delta', { text: 'Начал' }]]) } });
  await cut.tap();
  await sayPhrase(cut);
  assert.equal(cut.page.data.phase, 'error');
  assert.match(cut.status(), /Neo не ответил/);
});

test('stopping while Neo answers discards the rest', async () => {
  let release;
  const env = await ready({ routes: { '/v1/ask': () => new Promise(r => { release = () => r(sseResponse(askEvents('Поздно.'))); }) } });
  await env.tap();
  await sayPhrase(env);
  assert.equal(env.page.data.phase, 'recognizing');
  assert.equal(env.page.data.actions[0].label, 'Стоп');
  await env.tap();
  assert.equal(env.page.data.phase, 'paused');
  release();
  await flush();
  assert.notEqual(env.text(), 'Поздно.');
});

test('a deep question announces the wait and is labelled when answered', async () => {
  const env = await ready({ routes: { '/v1/ask': () => sseResponse([
    ['transcript', { text: 'Подумай, как спланировать день' }],
    ['delta', { text: 'План.' }],
    ['done', { message: 'План.', session_id: ID, provider: 'openai', model: 'gpt-5.6-terra', request_id: ID }]
  ]) } });
  const seen = [];
  const original = env.page.setPhase.bind(env.page);
  env.page.setPhase = (phase, status) => { seen.push([phase, status]); return original(phase, status); };
  await env.tap();
  await sayPhrase(env);
  assert.ok(seen.some(([phase, status]) => phase === 'thinking' && /Думаю глубже/.test(status)), JSON.stringify(seen));
  assert.ok(env.rows().includes('· глубокий ответ'), env.rows().join('|'));
});

test('answers with sources are shown in the feed', async () => {
  const env = await ready({ routes: { '/v1/ask': () => sseResponse(askEvents('1. Кофе\n2. Чай', {
    sources: [{ title: 'Пример', url: 'https://example.com' }, { title: 'bad', url: 'javascript:x' }]
  })) } });
  await env.tap();
  await sayPhrase(env);
  assert.deepEqual(plain(env.rows()), ['Вы: Привет, Нео', '1. Кофе', '2. Чай', '[1] Пример https://example.com']);
});

test('spoken "стоп" pauses and "новый разговор" resets the session locally', async () => {
  const phrases = ['Нео, новый разговор', 'стоп'];
  const env = await ready({ routes: { '/v1/ask': () => sseResponse(askEvents()) } });
  env.page.showTranscript = text => { env.page.pending = text; };
  for (const phrase of phrases) {
    await env.tap();
    env.page.afterPhrase(env.page.voice, phrase);
    await flush();
  }
  assert.equal(asks(env).length, 0, 'local commands never reach the server');
  assert.equal(env.page.data.phase, 'paused');
});

test('audio recorded at 48 kHz is detected and resampled to 16 kHz', async () => {
  const env = await ready();
  await env.tap();
  const chunk = level => env.frame(level, 8192 / 48, 48000);
  for (let i = 0; i < 6; i++) chunk(0);
  for (let i = 0; i < 4; i++) chunk(0.2);
  for (let i = 0; i < 8; i++) chunk(0);
  await flush(16);
  const wav = Buffer.from(asks(env)[0].body.wav_base64, 'base64');
  assert.equal(wav.readUInt32LE(24), 16000);
  const seconds = wav.readUInt32LE(40) / 32000;
  assert.ok(seconds > 0.6 && seconds < 1.6, 'duration ' + seconds);
  env.page.flushEvents();
  await flush();
  assert.match(telemetry(env), /rate:48000/);
});

test('the page works without wx base64 and explains a missing recorder', async () => {
  const bare = await ready({ noWx: true });
  await bare.tap();
  assert.equal(bare.page.data.phase, 'error');
  assert.match(bare.status(), /Запись микрофона недоступна/);

  const env = await ready({ noBase64: true });
  await env.tap();
  await sayPhrase(env);
  const wav = Buffer.from(asks(env)[0].body.wav_base64, 'base64');
  assert.equal(wav.toString('ascii', 8, 12), 'WAVE');
  assert.equal(wav.readUInt32LE(40), wav.length - 44);
});

test('silence around a phrase is not uploaded, but clips stay at least half a second', async () => {
  const env = await ready();
  await env.tap();
  await sayPhrase(env, { lead: 12, speech: 8 });
  const seconds = Buffer.from(asks(env)[0].body.wav_base64, 'base64').readUInt32LE(40) / 32000;
  assert.ok(seconds >= 2 && seconds <= 2.6, 'uploaded ' + seconds + ' s');

  const short = await ready();
  await short.tap();
  await sayPhrase(short, { speech: 1 });
  const clip = Buffer.from(asks(short)[0].body.wav_base64, 'base64').readUInt32LE(40) / 32000;
  assert.ok(clip >= 0.5, 'clip ' + clip);
});

test('the face reacts to the microphone and rests when Neo is idle', async () => {
  const env = await ready();
  assert.equal(env.state(), '');
  await env.tap();
  assert.equal(env.state(), 'включаю микрофон');
  env.frame(0.3);
  await env.advance(200);
  assert.equal(env.state(), 'слушаю');
  const loud = env.page.data.faceHalo;
  env.frame(0);
  await env.advance(400);
  assert.notEqual(env.page.data.faceHalo, loud, 'the halo follows the level');
  assert.doesNotMatch(env.page.data.faceEye + env.page.data.faceMouth, /transform/, 'Ink hides elements with inline transforms');
  env.page.stopVoice();
  env.page.setPhase('idle', 'Готово.');
  await flush();
  assert.equal(env.timers.size - (env.page.telemetryTimer ? 1 : 0), 0, 'the animation stops when idle');
});

test('a stalled microphone is reported instead of listening forever', async () => {
  const env = await ready();
  await env.tap();
  env.frame(0);
  assert.equal(env.page.data.phase, 'listening');
  await env.advance(4500);
  assert.equal(env.page.data.phase, 'error');
  assert.match(env.status(), /перестал присылать звук/);
});

test('losing focus stops listening but not a spoken answer', async () => {
  const env = await ready();
  await env.tap();
  env.frame(0);
  env.page.onHostBlur();
  await flush();
  assert.equal(env.recorder.stopped, 1);
  assert.equal(env.page.data.phase, 'paused');

  const speaking = await ready({ rokidVoice: true });
  await speaking.tap();
  await sayPhrase(speaking, { speak: false });
  assert.equal(speaking.page.data.phase, 'speaking');
  speaking.page.onHostBlur();
  assert.equal(speaking.page.data.phase, 'speaking');
});

test('the answer is read aloud with the microphone released, then the turn ends', async () => {
  const env = await ready({ rokidVoice: true });
  await env.tap();
  await sayPhrase(env, { speak: false });
  assert.equal(env.page.data.phase, 'speaking');
  assert.equal(env.state(), 'говорю');
  assert.deepEqual([...env.played], ['Ответ Neo.']);
  assert.deepEqual([...env.played.modes], ['immediate']);
  assert.equal(env.recorder.paused, 1, 'capture pauses before speaking');
  await env.advance(4000);
  assert.equal(env.recorder.resumed, 1, 'the conversation continues by itself');
  assert.equal(env.page.data.phase, 'listening');
  env.page.flushEvents();
  await flush();
  assert.match(telemetry(env), /rokid:speak:chars_10/);
});

test('the spoken answer can be interrupted and the voice switched off', async () => {
  const env = await ready({ rokidVoice: true });
  await env.tap();
  await sayPhrase(env, { speak: false });
  await env.tap();
  assert.equal(env.page.data.phase, 'paused');
  assert.deepEqual([...env.played], ['Ответ Neo.', ' '], 'a blank utterance interrupts the reply');

  const silent = await ready({ rokidVoice: true, storage: prefs({ voice: 'off', talk: 'tap' }) });
  await silent.tap();
  await sayPhrase(silent);
  assert.deepEqual([...silent.played], []);
  assert.equal(silent.page.data.phase, 'idle');
  assert.match(silent.status(), /Коснитесь/);
});

test('glasses swipes scroll the conversation, reach Меню at its end and never press a button', async () => {
  const long = Array.from({ length: 60 }, (_, i) => 'слово' + i).join(' ');
  const env = await ready({ routes: { '/v1/chat': () => response(200, { session_id: ID, message: long, provider: 'openai', request_id: ID }) } });
  await env.page.ask('Длинный', null);
  assert.equal(env.rows()[0], 'Вы: Длинный');
  glassesSwipe(env, true);
  await env.advance(1000);
  assert.match(env.rows()[0], /^▲ выше ещё \d+ стр\.$/);
  assert.equal(selected(env), 0);
  glassesSwipe(env, false);
  env.tick(140);
  glassesSwipe(env, true);
  await env.advance(1000);
  assert.match(env.rows()[0], /^▲ выше ещё \d+ стр\.$/);
  for (let i = 0; i < 10; i++) { glassesSwipe(env, true); await env.advance(1000); }
  assert.equal(selected(env), 1, 'past the end the selection moves to Меню');
  glassesSwipe(env, true);
  await env.advance(1000);
  assert.equal(selected(env), 1, 'Меню is the last stop');
  glassesSwipe(env, false);
  await env.advance(1000);
  assert.equal(selected(env), 0, 'back returns to the conversation');
  assert.equal(env.recorder.started, 0);
});

test('the feed keeps the whole session and resets on a new conversation', async () => {
  const words = n => Array.from({ length: n }, (_, i) => 'текст' + i).join(' ');
  const answers = ['Первый ' + words(25), 'Второй ' + words(25)];
  const env = await ready({ routes: { '/v1/chat': () => response(200, { session_id: ID, message: answers.shift(), provider: 'openai', request_id: ID }) } });
  await env.page.ask('Один', null);
  await env.page.ask('Два', null);
  assert.match(env.rows()[0], /^▲ выше ещё \d+ стр\.$/);
  assert.equal(env.rows()[1], 'Вы: Два');
  for (let i = 0; i < 30; i++) await env.swipe('ArrowUp');
  assert.equal(env.rows()[0], 'Вы: Один');
  env.page.selected = 1;
  await env.tap();
  env.key('Backspace');
  assert.equal(env.rows()[0], 'Вы: Один');
  env.page.newConversation();
  assert.equal(env.text(), 'Начат новый разговор. Сохранённые факты\nдоступны.');
});

test('a glasses tap acts once; its trailing Enter and echo GlobalHook are ignored', async () => {
  const env = await ready();
  env.key('GlobalHook');
  assert.equal(env.recorder.started, 0, 'GlobalHook waits for a possible swipe');
  await env.advance(360);
  assert.equal(env.recorder.started, 1);
  assert.match(env.page.data.actions[0].cls, /press/);
  await env.advance(120);
  env.key('Enter');
  env.key('GlobalHook');
  env.tick(38);
  env.key('Enter');
  await env.advance(600);
  assert.equal(env.page.data.phase, 'starting', 'the conversation was not stopped by echoes');
  await env.advance(1000);
  await glassesTap(env);
  assert.equal(env.page.data.phase, 'paused', 'a later real tap stops it');
});

test('Craft arrows and clicks work; host taps right after a swipe are ignored', async () => {
  const env = await ready();
  const right = env.key('ArrowRight');
  assert.equal(right.prevented, true);
  assert.equal(selected(env), 1);
  env.page.tapScreen();
  env.page.tapAction({ currentTarget: { dataset: { index: 1 } } });
  assert.equal(env.page.data.screen, 'main');
  env.tick(1000);
  env.key('ArrowLeft');
  assert.equal(selected(env), 0);
  env.tick(2000);
  env.page.tapAction({ currentTarget: { dataset: { index: 1 } } });
  assert.equal(env.page.data.screen, 'menu');
});

test('the menu has two short levels, stops at its ends and persists settings', async () => {
  const env = await ready({ rokidVoice: true });
  glassesSwipe(env, true);
  await env.advance(1000);
  await glassesTap(env);
  assert.equal(env.page.data.screen, 'menu');
  assert.deepEqual(plain(env.page.menuItems().map(item => item.id)), ['voice', 'talk', 'sensitive', 'new', 'memory', 'service', 'back']);
  assert.match(env.page.data.menuTitle, /^НАСТРОЙКИ {2}1\/7 ▼$/);
  glassesSwipe(env, false);
  await env.advance(1000);
  assert.match(env.page.data.menuTitle, /▲ начало/);
  assert.equal(menuFocus(env), 'voice');
  await glassesTap(env);
  assert.equal(env.page.data.menuRows[0].value, 'выключен');
  await env.advance(1000);
  await glassesTap(env);
  assert.equal(env.page.data.menuRows[0].value, 'включён');
  assert.deepEqual([...env.played], ['Голос включён.']);
  await env.advance(1000);
  glassesSwipe(env, true);
  await env.advance(1000);
  glassesSwipe(env, true);
  await env.advance(1000);
  assert.equal(menuFocus(env), 'sensitive');
  await glassesTap(env);
  assert.deepEqual(JSON.parse(env.storage.get(PREFS)), { voice: 'on', talk: 'continuous', sensitive: true });
  for (let i = 0; i < 8; i++) { await env.advance(1000); glassesSwipe(env, true); }
  await env.advance(1000);
  assert.equal(menuFocus(env), 'back');
  assert.match(env.page.data.menuTitle, /7\/7.*▼ конец/);
  glassesSwipe(env, false);
  await env.advance(1000);
  assert.equal(menuFocus(env), 'service');
  await env.advance(1000);
  await glassesTap(env);
  assert.match(env.page.data.menuTitle, /^СЕРВИС/);
  assert.deepEqual(plain(env.page.menuItems().map(item => item.id)), ['mictest', 'diagnostics', 'reconnect', 'up']);
  const back = env.key('Backspace');
  assert.equal(back.prevented, true);
  assert.match(env.page.data.menuTitle, /^НАСТРОЙКИ/);
  assert.equal(menuFocus(env), 'service');
  env.key('Backspace');
  assert.equal(env.page.data.screen, 'main');
  const exit = env.key('Backspace');
  assert.equal(exit.down.prevented || exit.up.prevented, false, 'back on the main screen closes Neo');
});

test('a microphone test runs from the service menu and returns there', async () => {
  const env = await ready();
  env.page.openMenu('service');
  env.page.menuIndex = env.page.menuItems().findIndex(item => item.id === 'mictest');
  await env.tap();
  assert.equal(env.page.data.screen, 'info');
  assert.equal(env.recorder.started, 1);
  await env.advance(4500);
  assert.ok(env.rows().some(row => row.includes('НЕТ КАДРОВ')), env.rows().join('|'));
  env.key('Backspace');
  assert.equal(env.page.data.screen, 'menu');
  assert.equal(menuFocus(env), 'mictest');
  assert.equal(env.recorder.stopped, 1);
  await env.tap();
  env.frame(0.3);
  await env.advance(300);
  assert.ok(env.rows().some(row => /^МИК █+/.test(row)), env.rows().join('|'));
  await env.advance(20000);
  assert.ok(env.rows().some(row => row.includes('микрофон РАБОТАЕТ')), env.rows().join('|'));
});

test('long answers are wrapped by words and fit the screen', async () => {
  const long = Array.from({ length: 120 }, (_, i) => 'слово' + i).join(' ');
  const env = await ready({ routes: { '/v1/chat': () => response(200, { session_id: ID, message: long, provider: 'openai', request_id: ID }) } });
  await env.page.ask('Длинный ответ', null);
  const main = env.rows();
  assert.equal(main[0], 'Вы: Длинный ответ');
  assert.match(main[main.length - 1], /^▼ ниже ещё \d+ стр\. — свайп вперёд$/);
  for (const row of env.page.data.bodyLines) assert.ok(Array.from(row.text).length <= (row.cls === 'line' ? 40 : 54), row.text);
  const heights = { line: 23, small: 17, gap: 8 };
  const height = env.page.data.bodyLines.reduce((sum, row) => sum + heights[row.cls], 0);
  assert.ok(height <= 264, 'the feed fits: ' + height);
  for (let i = 0; i < 40; i++) await env.swipe('ArrowDown');
  assert.equal(selected(env), 1);
  assert.match(env.page.data.bodyLines[env.page.data.bodyLines.length - 1].text, /слово119$/);
});

test('temple long-press starts talking and suppresses the system assistant', async () => {
  const env = await ready();
  const event = { keyword: 'clickAiAssist', prevented: false, preventDefault() { this.prevented = true; } };
  env.page.onVoiceWakeup(event);
  await flush();
  assert.equal(event.prevented, true);
  assert.equal(env.recorder.started, 1);
});

test('diagnostics and memory are reachable from the menu', async () => {
  const env = await ready();
  env.page.openMenu('service');
  env.page.menuIndex = env.page.menuItems().findIndex(item => item.id === 'diagnostics');
  env.page.activateMenu();
  assert.equal(env.page.data.screen, 'info');
  assert.match(env.rows().join('\n'), /Ink: 0\.18\.0/);
  env.page.openMenu('main');
  env.page.menuIndex = env.page.menuItems().findIndex(item => item.id === 'memory');
  env.page.activateMenu();
  await flush();
  assert.equal(chats(env)[0].body.message, 'покажи память');
  assert.equal(chats(env)[0].body.web_search, true);
});

test('hiding the page releases everything', async () => {
  const env = await ready();
  await env.tap();
  env.frame(0);
  env.page.onHide();
  assert.equal(env.page.voice, null);
  await flush();
  assert.equal(env.recorder.stopped, 1);
  assert.equal(env.timers.size - (env.page.telemetryTimer ? 1 : 0), 0);
});

test('telemetry carries only technical tokens, transliterated', async () => {
  const env = await ready();
  await env.tap();
  await sayPhrase(env);
  env.page.report('tts_error', 'rokid:Ошибка синтеза речи');
  assert.match(env.page.events[env.page.events.length - 1].detail, /Oshibka/);
  env.page.onHide();
  await flush();
  const sent = telemetry(env);
  for (const code of ['app_start', 'key', 'voice_start', 'mic_frames', 'asr_result', 'voice_state']) assert.match(sent, new RegExp(code));
  assert.ok(!/Привет|Ответ/.test(sent), 'no conversation text in telemetry');
  for (const batch of env.requests.filter(r => r.route === '/v1/diagnostics')) {
    assert.ok(batch.body.events.length <= 20);
    for (const event of batch.body.events) {
      assert.ok(!event.detail || /^[A-Za-z0-9_.:+\- ]{0,60}$/.test(event.detail), event.detail);
      assert.ok(/^[a-z_]{0,16}$/.test(event.phase), event.phase);
    }
  }
});

test('older settings migrate to voice on/off', async () => {
  const env = await ready({ storage: { 'neo.preferences.v4': JSON.stringify({ voice: 'neo', mode: 'tap', sensitive: true, search: false }) } });
  assert.deepEqual(plain(env.page.prefs), { voice: 'on', talk: 'tap', sensitive: true });
  const off = await ready({ storage: { 'neo.preferences.v4': JSON.stringify({ voice: 'off' }) } });
  assert.equal(off.page.prefs.voice, 'off');
  const fresh = await ready();
  assert.deepEqual(plain(fresh.page.prefs), { voice: 'on', talk: 'continuous', sensitive: false });
});

test('template bindings and handlers exist', () => {
  const env = host();
  const data = env.page.data;
  for (const [, expression] of template.matchAll(/\{\{\s*([^}]+?)\s*\}\}/g)) {
    const root = expression.match(/^[!]?([A-Za-z_]\w*)/)[1];
    if (['item', 'index', 'true', 'false'].includes(root)) continue;
    assert.ok(root in data, 'unknown template binding ' + root);
  }
  for (const [, handler] of template.matchAll(/bind\w+="(\w+)"/g)) {
    assert.equal(typeof env.page[handler], 'function', 'missing handler ' + handler);
  }
  assert.ok(!/\\n/.test(template), 'line breaks are not rendered by <text>');
  const style = ink.match(/<style>([\s\S]*?)<\/style>/)[1];
  for (const property of ['white-space', 'word-break', 'animation', 'visibility', 'position: sticky', 'overflow', 'transform']) {
    assert.ok(!style.includes(property), 'unsupported WXSS: ' + property);
  }
  assert.equal(script.match(/clearTimeout\(/g).length, 1, 'use stopTimer(): Ink clearTimeout throws for undefined');
  assert.ok(!/crypto\.randomUUID|SpeechRecognition\(/.test(script), 'unavailable or removed runtime APIs');
  assert.ok(!/^import /m.test(script), 'static imports can fail the whole page on older firmware');
});

test('app manifest declares the microphone and the agent description', () => {
  const app = JSON.parse(fs.readFileSync(path.join(__dirname, '../app.json'), 'utf8'));
  assert.deepEqual(app.pages, ['pages/index/index']);
  assert.ok(app.permissions.includes('RECORD_AUDIO'));
  const agents = fs.readFileSync(path.join(__dirname, '../AGENTS.md'), 'utf8');
  assert.match(agents, /\*\*Description\*\*: NEO/);
  // The token file is packaged into the AIX but never committed.
  const aixignore = fs.readFileSync(path.join(__dirname, '../.aixignore'), 'utf8');
  assert.ok(!/config\.local/.test(aixignore), 'the token file must reach the glasses');
  const gitignore = fs.readFileSync(path.join(__dirname, '../.gitignore'), 'utf8');
  assert.match(gitignore, /^config\.local\.js$/m);
  assert.ok(fs.existsSync(path.join(__dirname, '../config.local.example.js')));
  // This repository is public: no token may appear in the source.
  const literals = [...script.matchAll(/'([^'\n]*)'|"([^"\n]*)"/g)].map(match => match[1] ?? match[2]);
  const known = [
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/',
    'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
  ];
  for (const literal of literals) {
    assert.ok(known.includes(literal) || !/^[A-Za-z0-9_-]{32,}$/.test(literal),
      'secret-looking literal: ' + literal.slice(0, 8) + '…');
  }
  assert.ok(!/NEO_DEVICE_TOKEN/.test(script), 'the token is loaded from config.local.js');
});

test('the conversation continues by itself and pauses after ten silent seconds', async () => {
  const env = await ready({ rokidVoice: true });
  await env.tap();
  await sayPhrase(env);
  assert.equal(env.page.data.phase, 'listening');
  await sayPhrase(env, { lead: 1 });
  assert.equal(asks(env).length, 2, 'the next question needs no tap');
  for (let i = 0; i < 43; i++) env.frame(0);
  await env.advance(200);
  assert.equal(env.page.data.phase, 'paused');

  const tapMode = await ready({ rokidVoice: true, storage: prefs({ voice: 'on', talk: 'tap' }) });
  await tapMode.tap();
  await sayPhrase(tapMode);
  assert.equal(tapMode.page.data.phase, 'idle');
  assert.equal(tapMode.recorder.stopped, 1);
});

test('a scrollbar shows how much of the conversation is visible', async () => {
  const long = Array.from({ length: 120 }, (_, i) => 'слово' + i).join(' ');
  const env = await ready({ routes: { '/v1/chat': () => response(200, { session_id: ID, message: long, provider: 'openai', request_id: ID }) } });
  assert.equal(env.page.data.thumb, '', 'no bar while everything fits');
  await env.page.ask('Длинный', null);
  const first = env.page.data.thumb;
  assert.match(first, /height: \d+px; top: 0px;/);
  for (let i = 0; i < 40; i++) await env.swipe('ArrowDown');
  const last = env.page.data.thumb;
  assert.match(last, /top: [1-9]\d*px/);
  assert.notEqual(first, last, 'the thumb moves with the text');
});


test('without config.local.js Neo explains what to do', async () => {
  const env = host({ noToken: true });
  env.page.onLoad();
  env.page.onShow();
  await flush();
  assert.equal(env.page.data.phase, 'offline');
  assert.match(env.text(), /config\.local\.js/);
  assert.equal(env.requests.length, 0, 'nothing is sent without a token');
  env.page.flushEvents();
  await flush();
  assert.equal(env.requests.length, 0);
});
