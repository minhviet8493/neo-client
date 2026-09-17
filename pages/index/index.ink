<script def>
{
  "navigationBarTitleText": "NEO"
}
</script>

<script setup>
// No static imports: a module the firmware lacks would fail the whole page before it renders.
let wx = typeof globalThis.wx === 'object' ? globalThis.wx : null;
let wxMissing = false;
function loadWx() {
  if (wx) return Promise.resolve(wx);
  const missing = () => { wxMissing = true; return null; };
  try {
    return import('wx').then(module => { wx = module && (module.default || module); return wx; }, missing);
  } catch (_) { return Promise.resolve(missing()); }
}

const NEO_BASE_URL = 'https://neo-core.1click24.ru';
const VERSION = '4.0';
const CONNECT_TIMEOUT_MS = 10000;
const REQUEST_TIMEOUT_MS = 40000;
const START_TIMEOUT_MS = 8000;
const IDLE_PAUSE_MS = 10000;
// A shorter end-of-phrase pause: the owner waits for the answer, not for the silence.
const SILENCE_MS = 800;
// Nothing from the answer stream for this long means the link is gone.
const STREAM_IDLE_MS = 20000;
// Gestures as the glasses (AIUI 0.17) deliver them: a swipe is GlobalHook, then ~100-200 ms
// later ArrowRight+ArrowDown (forward) or ArrowLeft+ArrowUp (back); a tap is GlobalHook and
// ~500 ms later Enter. Each GlobalHook starts a gesture; it becomes a tap only if no arrow
// follows within HOOK_DELAY_MS.
const HOOK_DELAY_MS = 350;
const SWIPE_WINDOW_MS = 1500;
// Without a GlobalHook (Craft), arrows closer than this belong to one swipe.
const FALLBACK_GAP_MS = 150;
// Any second confirm this soon after an action is the same physical tap.
const TWIN_MS = 700;
const PRESS_MS = 160;
const RETRY_DELAY_MS = 1500;
const FORWARD_KEYS = ['ArrowDown', 'ArrowRight'];
// Audio frames arrive every 200-250 ms; a longer gap while listening means capture stalled.
const STALL_MS = 4000;
// One animation frame drives the face, so the screen updates once per tick.
const FRAME_MS = 150;
// Rough speaking time, used only to decide when listening may resume: the system voice gives
// no "finished" event, and the text no longer waits for the speech.
const SPEECH_MS_PER_CHAR = 70;
const ACTIVE_PHASES = ['starting', 'listening', 'recognizing', 'thinking', 'speaking'];
const STATE_WORDS = { connecting: 'связь…', offline: 'нет связи', idle: '', starting: 'включаю микрофон',
  listening: 'слушаю', recognizing: 'распознаю', thinking: 'думаю', speaking: 'говорю', paused: 'пауза', error: 'ошибка' };
const DIRECTION_KEYS = ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'];
const READ_STEP_ROWS = 3;
const TELEMETRY_MS = 8000;
const ACTIONS = ['talk', 'menu'];
const HISTORY_TURNS = 20;
const PREFS_KEY = 'neo.preferences.v5';
const OLD_PREFS_KEYS = ['neo.preferences.v4', 'neo.preferences.v3'];
// No secret ships with this repository. The glasses ask the server for access, the owner
// confirms the request in the Telegram bot, and only then does the server enroll the device.
const ACCESS_KEY = 'neo.access.v1';
const OLD_DEVICE_KEY = 'neo.device.v1';
// A stored confirmation is reused until the build changes or a month passes.
const ACCESS_MAX_AGE_MS = 30 * 24 * 3600 * 1000;
const PAIR_POLL_MS = 2000;
const PAIR_WAIT_MS = 200000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Ink's clearTimeout throws for anything but a timer number.
function stopTimer(id) {
  if (typeof id === 'number') clearTimeout(id);
}

function newId() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const value = Math.floor(Math.random() * 16);
    return (c === 'x' ? value : ((value & 3) | 8)).toString(16);
  });
}

// Ink neither renders line breaks in <text> nor clips overflowing content, so text is
// wrapped here and only the rows that fit are rendered. Widths are conservative
// characters per row for the 448px content width.
const ROWS = {
  line: { chars: 40, height: 23 },
  small: { chars: 54, height: 17 },
  mono: { chars: 60, height: 16 },
  status: { chars: 56, height: 16 },
  gap: { chars: 1, height: 8 }
};
const BODY_HEIGHT = { main: 264, info: 286 };

function wrap(text, chars) {
  const rows = [];
  for (const paragraph of String(text || '').split('\n')) {
    let row = '';
    for (let word of paragraph.trim().split(/\s+/)) {
      while (Array.from(word).length > chars) {
        if (row) { rows.push(row); row = ''; }
        rows.push(Array.from(word).slice(0, chars).join(''));
        word = Array.from(word).slice(chars).join('');
      }
      if (!word) continue;
      if (row && Array.from(row + ' ' + word).length > chars) { rows.push(row); row = word; }
      else row = row ? row + ' ' + word : word;
    }
    rows.push(row || ' ');
  }
  return rows;
}

function rows(text, cls) {
  return wrap(text, ROWS[cls].chars).map(value => ({ text: value, cls }));
}

function readLocal(key) {
  try { return typeof localStorage === 'undefined' ? null : JSON.parse(localStorage.getItem(key)); }
  catch (_) { return null; }
}

function writeLocal(key, value) {
  try {
    if (typeof localStorage === 'undefined') return false;
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, JSON.stringify(value));
    return true;
  } catch (_) { return false; }
}

function base64(buffer) {
  if (wx && typeof wx.arrayBufferToBase64 === 'function') return wx.arrayBufferToBase64(buffer);
  const bytes = new Uint8Array(buffer);
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | ((bytes[i + 1] || 0) << 8) | (bytes[i + 2] || 0);
    out += alphabet[(n >>> 18) & 63] + alphabet[(n >>> 12) & 63]
      + (i + 1 < bytes.length ? alphabet[(n >>> 6) & 63] : '=')
      + (i + 2 < bytes.length ? alphabet[n & 63] : '=');
  }
  return out;
}

// Telemetry may only carry technical tokens; the server rejects anything else.
const TRANSLIT = { а: 'a', б: 'b', в: 'v', г: 'g', д: 'd', е: 'e', ё: 'e', ж: 'zh', з: 'z', и: 'i', й: 'i',
  к: 'k', л: 'l', м: 'm', н: 'n', о: 'o', п: 'p', р: 'r', с: 's', т: 't', у: 'u', ф: 'f', х: 'h', ц: 'c',
  ч: 'ch', ш: 'sh', щ: 'sch', ъ: '', ы: 'y', ь: '', э: 'e', ю: 'yu', я: 'ya' };
function safeToken(value) {
  // Host error texts may be Russian; transliterate so they stay readable in the server log.
  const latin = String(value == null ? '' : value).replace(/[а-яё]/gi, ch => {
    const out = TRANSLIT[ch.toLowerCase()];
    return ch === ch.toLowerCase() ? out : out.toUpperCase();
  });
  return latin.replace(/[^A-Za-z0-9_.:+\- ]/g, '_').slice(0, 60);
}

const DEEP_REQUEST = /(^|[^а-яё\w])(подумай|обдумай|подробн[а-яё]*|детальн[а-яё]*|объясни|разбер[а-яё]*|проанализируй|сравни)(?![а-яё\w])/i;

const RATE_PROBE_MS = 800;
const CAPTURE_RATES = [16000, 24000, 48000];

// Snaps a measured sample rate to the nearest supported capture rate (log distance).
// 44.1 kHz lands on 48 kHz: the 9% speed change does not hurt transcription.
function snapRate(measured) {
  let best = CAPTURE_RATES[0];
  for (const rate of CAPTURE_RATES) {
    if (Math.abs(Math.log(measured / rate)) < Math.abs(Math.log(measured / best))) best = rate;
  }
  return best;
}

// Converts mono s16le PCM at `rate` to 16 kHz by averaging each source window.
function to16k(buffer, rate) {
  if (rate === 16000) return new Uint8Array(buffer);
  const input = new DataView(buffer);
  const count = buffer.byteLength / 2;
  const ratio = rate / 16000;
  const length = Math.floor(count / ratio);
  const output = new Uint8Array(length * 2);
  const out = new DataView(output.buffer);
  for (let i = 0; i < length; i++) {
    const start = Math.floor(i * ratio);
    const end = Math.min(count, Math.max(start + 1, Math.floor((i + 1) * ratio)));
    let sum = 0;
    for (let j = start; j < end; j++) sum += input.getInt16(j * 2, true);
    out.setInt16(i * 2, Math.round(sum / (end - start)), true);
  }
  return output;
}

// Transcription is billed per second: drop silence around the phrase, keeping short margins.
function trimSilence(bytes, threshold) {
  const WINDOW = 640; // 20 ms of 16 kHz s16
  const windows = Math.floor(bytes.length / WINDOW);
  let first = -1;
  let last = -1;
  for (let i = 0; i < windows; i++) {
    const start = bytes.byteOffset + i * WINDOW;
    if (rmsOf(bytes.buffer.slice(start, start + WINDOW)) >= threshold) {
      if (first < 0) first = i;
      last = i;
    }
  }
  if (first < 0) return bytes;
  const from = Math.max(0, (first - 10) * WINDOW); // 200 ms before
  const to = Math.min(bytes.length, (last + 16) * WINDOW); // 320 ms after
  // The server rejects clips shorter than 0.3 s; keep at least 0.5 s.
  if (to - from < 16000) return bytes.subarray(0, Math.min(bytes.length, Math.max(16000, to)));
  return bytes.subarray(from, to);
}

function rmsOf(buffer) {
  const view = new DataView(buffer);
  const count = Math.floor(buffer.byteLength / 2);
  let energy = 0;
  for (let i = 0; i < count; i++) {
    const sample = view.getInt16(i * 2, true) / 32768;
    energy += sample * sample;
  }
  return count ? Math.sqrt(energy / count) : 0;
}

// Text level meter: the only way to see on the glasses whether audio arrives at all.
function meter(level, frames) {
  const percent = Math.max(0, Math.min(100, Math.round((level || 0) * 100)));
  const filled = Math.round(percent / 10);
  return 'МИК ' + '█'.repeat(filled) + '░'.repeat(10 - filled) + ' ' + percent + '% · кадры ' + (frames || 0);
}

// One Server-Sent Event block: "event: name" plus "data: {json}".
function parseEvent(block) {
  let name = '';
  let payload = '';
  for (const line of String(block).split('\n')) {
    if (line.indexOf('event:') === 0) name = line.slice(6).trim();
    else if (line.indexOf('data:') === 0) payload += line.slice(5).trim();
  }
  if (!name || !payload) return null;
  try { return { name, data: JSON.parse(payload) }; } catch (_) { return null; }
}

function speechText(text) {
  // Links and source markers are unpleasant to hear.
  return String(text).replace(/https?:\/\/\S+/g, '').replace(/\[\d+\]/g, '').slice(0, 1500);
}

export default {
  data: {
    version: VERSION,
    screen: 'main',
    phase: 'connecting',
    statusLines: [],
    bodyLines: [],
    thumb: '',
    actions: [],
    menuRows: [],
    menuTitle: '',
    stateWord: '',
    faceEye: '',
    faceMouth: '',
    faceHalo: '',
    hint: ''
  },

  // ---- lifecycle -------------------------------------------------------

  onLoad() {
    // Enrollments made with the embedded token are dropped: 4.0 asks the owner in Telegram.
    if (readLocal(OLD_DEVICE_KEY)) writeLocal(OLD_DEVICE_KEY, null);
    // Neo server recognition is the only recognizer (Rokid host ASR cannot do Russian on
    // AIUI 0.17). Older settings carry over, except that 2.7 starts in free conversation.
    const saved = readLocal(PREFS_KEY);
    const old = saved ? null : OLD_PREFS_KEYS.map(readLocal).find(Boolean);
    const carried = saved || {};
    if (old && old.sensitive !== undefined) carried.sensitive = old.sensitive;
    if (old && old.voice !== undefined) carried.voice = old.voice === 'off' ? 'off' : 'on';
    if (old && old.mode === 'tap') carried.talk = 'tap';
    this.prefs = Object.assign({ voice: 'on', talk: 'continuous', sensitive: false }, carried);
    delete this.prefs.pace;
    this.prefs.talk = this.prefs.talk === 'tap' ? 'tap' : 'continuous';
    // 3.0 keeps only settings that change behavior: the Rokid voice and microphone sensitivity.
    this.prefs.voice = this.prefs.voice === 'off' ? 'off' : 'on';
    delete this.prefs.mode;
    delete this.prefs.search;
    delete this.prefs.rokidVoice;
    this.menuLevel = 'main';
    this.events = [];
    this.keysDown = {};
    this.sessionTag = newId().slice(0, 8);
    this.selected = 0;
    this.menuIndex = 0;
    this.conversationId = null;
    this.navLog = [];
    this.lastError = 'нет';
    this.status = 'Подключение к Neo…';
    // The main screen is a scrollable feed of this session's questions and answers.
    this.history = [];
    this.pending = '';
    this.notice = 'Neo подключается к серверу.';
    this.answerText = '';
    this.infoText = [];
    this.offset = 0;
    // Unknown until the host reports focus; older hosts may never report it.
    this.focused = undefined;
    loadWx();
    this.render();
  },

  onShow() {
    loadWx();
    this.guard('show', () => {
      if (!this.connection && !this.connecting) return this.connect();
    });
  },

  onHide() { this.suspend('Neo на паузе.'); this.flushEvents(); },
  onUnload() { this.suspend(''); this.connection = null; },
  onHostFocus() { this.focused = true; },
  onHostBlur() {
    this.focused = false;
    // Capture requires focus; the system speech player may blur us without stopping playback.
    if (this.voice && this.phase !== 'speaking') this.suspend('Пауза. Коснитесь, чтобы продолжить.');
  },

  suspend(status) {
    stopTimer(this.hookTimer);
    this.hookTimer = null;
    stopTimer(this.connectTimer);
    this.connectTimer = null;
    stopTimer(this.pressTimer);
    this.pressTimer = null;
    this.pressed = '';
    this.stopMicTest();
    this.stopVoice();
    this.cancelChat();
    if (status && this.connection) this.setPhase('paused', status);
  },

  // Every host callback goes through here: an exception must never leave the UI stuck.
  guard(name, fn) {
    try {
      const result = fn();
      if (result && typeof result.then === 'function') {
        return result.catch(error => this.crash(name, error));
      }
      return result;
    } catch (error) { this.crash(name, error); }
  },

  crash(name, error) {
    const text = String(error && (error.name || error.message) || error).slice(0, 80);
    console.error('[neo] ' + name + ' failed: ' + String(error && error.message || error));
    this.lastError = name + ': ' + text;
    this.report('crash', name + ':' + text);
    try { this.stopVoice(); } catch (_) {}
    this.setPhase(this.connection ? 'error' : 'offline', 'Сбой Neo (' + name + '). Коснитесь, чтобы повторить.');
  },

  // ---- rendering -------------------------------------------------------

  setPhase(phase, status) {
    if (this.phase !== phase) this.report('voice_state', phase);
    this.phase = phase;
    if (status !== undefined) this.status = status;
    this.setData({ phase });
    this.renderFace();
    this.render();
  },

  talkLabel() {
    if (!this.connection) return this.connecting ? '…' : 'Связь';
    return ACTIVE_PHASES.includes(this.phase) ? 'Стоп' : 'Говорить';
  },

  // The status line is for trouble only; normal state is the face plus one word next to it.
  statusVisible() {
    return this.phase === 'error' || this.phase === 'offline' || !!this.alert;
  },

  render() {
    const labels = { talk: this.talkLabel(), menu: 'Меню' };
    const hints = {
      main: 'Свайп: листать · касание: ' + (this.selected === 1 ? 'меню' : 'говорить'),
      menu: 'Свайп: пункт · касание: изменить · назад: выход',
      info: 'Свайп: прокрутка · касание: выход'
    };
    const status = this.statusVisible() ? (this.alert || this.status) : '';
    const screen = this.screen || 'main';
    // One setData per frame: the Ink runtime throttles frequent updates.
    this.setData(Object.assign({
      screen,
      actions: ACTIONS.map((id, index) => ({ id, label: labels[id],
        cls: 'action' + (index === this.selected ? ' action-on' : '') + (this.pressed === 'action:' + index ? ' press' : '') })),
      hint: hints[screen],
      stateWord: STATE_WORDS[this.phase] || '',
      statusLines: status ? rows(status, 'status').slice(0, 2).map((row, id) => ({ id, text: row.text })) : []
    }, screen === 'menu' ? this.menuData() : this.bodyData()));
  },

  setStatus(status) {
    this.status = status;
    this.render();
  },

  bodyRows() {
    if (this.screen === 'info') return this.infoText.flatMap(text => rows(text, 'mono'));
    const list = [];
    this.turnStarts = [];
    if (!this.history.length && this.notice) list.push(...rows(this.notice, 'line'));
    this.history.forEach((turn, index) => {
      if (index) list.push({ text: ' ', cls: 'gap' });
      this.turnStarts.push(list.length);
      // Wrapping every turn on every frame is too slow on the glasses: keep the rows.
      if (!turn.rows) {
        turn.rows = rows('Вы: ' + turn.q, 'small').concat(rows(turn.a, 'line'));
        if (turn.deep) turn.rows = turn.rows.concat(rows('· глубокий ответ', 'small'));
        for (let i = 0; i < turn.sources.length; i++) {
          const source = turn.sources[i];
          turn.rows = turn.rows.concat(rows('[' + (i + 1) + '] ' + String(source.title || '').slice(0, 60) + ' ' + source.url, 'small'));
        }
      }
      for (const row of turn.rows) list.push(row);
    });
    if (this.history.length && this.notice) list.push({ text: ' ', cls: 'gap' }, ...rows(this.notice, 'small'));
    if (this.pending) list.push(...rows('Вы: ' + this.pending, 'small'));
    if (this.streaming) list.push(...rows(this.streaming, 'line'));
    return list;
  },

  renderBody() {
    this.setData(this.bodyData());
  },

  // The rows that fit; swipes move this window over the feed or the info text.
  bodyData() {
    const screen = this.screen || 'main';
    const list = this.bodyRows();
    // Two 17px marker rows are reserved, plus the status line when it is visible.
    const budget = BODY_HEIGHT[screen] - 2 * ROWS.small.height - (this.statusVisible() ? 2 * ROWS.status.height : 0);
    // The last page is always full: find the first row of the final screenful.
    let maxStart = list.length;
    let tail = 0;
    while (maxStart > 0 && tail + ROWS[list[maxStart - 1].cls].height <= budget) tail += ROWS[list[--maxStart].cls].height;
    this.maxOffset = maxStart;
    if (this.follow !== undefined) {
      // Show a new answer from its question.
      // Following a new turn may scroll past a full page so its question sits at the top.
      const start = this.follow === 'end' ? maxStart
        : this.follow === 'top' ? 0 : (this.turnStarts || [])[this.follow] || 0;
      this.offset = Math.max(0, Math.min(start, Math.max(0, list.length - 2)));
      this.follow = undefined;
    }
    this.offset = Math.max(0, Math.min(this.offset, Math.max(maxStart, this.offset)));
    // Swipes never scroll past the last full page, but they can come back from a followed turn.
    this.maxOffset = Math.max(maxStart, this.offset);
    let end = this.offset;
    let used = 0;
    while (end < list.length && used + ROWS[list[end].cls].height <= budget) { used += ROWS[list[end].cls].height; end++; }
    const shown = list.slice(this.offset, end);
    if (this.offset > 0) shown.unshift({ cls: 'small', text: '▲ выше ещё ' + this.offset + ' стр.' });
    const hidden = list.length - end;
    if (hidden > 0) shown.push({ cls: 'small', text: '▼ ниже ещё ' + hidden + ' стр. — свайп вперёд' });
    // A scrollbar on the right, as on a computer: the thumb shows the visible part.
    const height = BODY_HEIGHT[screen];
    const visible = Math.max(1, end - this.offset);
    const thumb = list.length > visible
      ? 'height: ' + Math.max(12, Math.round(height * visible / list.length)) + 'px; top: '
        + Math.round((height - Math.max(12, height * visible / list.length)) * this.offset / Math.max(1, list.length - visible)) + 'px;'
      : '';
    return { bodyLines: shown.map((row, id) => ({ id, text: row.text, cls: row.cls })), thumb };
  },

  // A small face at the bottom bar, like the Rokid assistant's character: it blinks, follows the
  // microphone level while listening and moves its mouth while speaking.
  // One loop paints the face: a single setData per frame.
  renderFace() {
    stopTimer(this.frameTimer);
    this.frameTimer = null;
    this.frameStep = 0;
    const tick = () => {
      this.frameTimer = null;
      const voice = this.voice;
      const phase = this.phase;
      if (phase === 'listening' && voice && voice.confirmed && Date.now() - (voice.lastFrameAt || 0) > STALL_MS) {
        return this.voiceFailed(voice, 'mic_stalled', 'Микрофон перестал присылать звук. Коснитесь «Говорить».');
      }
      this.setData(this.faceData(this.frameStep++));
      if (ACTIVE_PHASES.includes(this.phase)) this.frameTimer = setTimeout(tick, FRAME_MS);
    };
    tick();
  },

  faceData(step) {
    const voice = this.voice;
    const phase = this.phase;
    const level = phase === 'listening' && voice ? voice.level || 0 : 0;
    const busy = ACTIVE_PHASES.includes(phase);
    const blink = step % 19 === 0 && phase !== 'speaking';
    const look = phase === 'thinking' ? Math.round(Math.sin(step / 4) * 2) : 0;
    // Ink draws nothing for an inline transform, so the face moves through sizes and margins.
    return {
      faceEye: 'height: ' + (blink ? 1 : 6) + 'px; margin-left: ' + (2 + look) + 'px; margin-right: ' + (2 - look) + 'px;',
      faceMouth: 'height: ' + (phase === 'speaking' ? 2 + (step % 3) * 3 : phase === 'listening' ? 2 + Math.round(level * 5) : 2)
        + 'px; width: ' + (phase === 'speaking' ? 10 : 12) + 'px;',
      faceHalo: 'opacity: ' + (phase === 'listening' ? (0.35 + level * 0.65).toFixed(2)
        : busy ? (0.3 + 0.3 * Math.abs(Math.sin(step / 3))).toFixed(2) : '0.18') + ';'
    };
  },

  setNotice(text) {
    this.notice = text;
    this.follow = this.history.length ? 'end' : 'top';
    this.render();
  },

  showTranscript(text) {
    this.pending = text || '';
    this.follow = 'end';
    this.render();
  },

  // The answer as it is being written, shown under the question before it enters history.
  showStreaming(text) {
    this.streaming = text;
    this.follow = 'end';
    this.render();
  },

  addTurn(question, answer, sources, deep) {
    this.streaming = '';
    this.history.push({ q: question, a: answer, sources: sources || [], deep: !!deep });
    if (this.history.length > HISTORY_TURNS) this.history.shift();
    this.answerText = answer;
    this.pending = '';
    this.notice = '';
    this.follow = this.history.length - 1;
    this.render();
  },

  clearHistory(notice) {
    this.history = [];
    this.pending = '';
    this.streaming = '';
    this.answerText = '';
    this.offset = 0;
    this.setNotice(notice);
  },

  // ---- input -------------------------------------------------------------

  onKeyDown(event) { return this.key(event, 'down'); },
  onKeyUp(event) { return this.key(event, 'up'); },

  key(event, type) {
    if (!event) return;
    const code = event.code;
    const handled = DIRECTION_KEYS.includes(code) || code === 'Enter' || code === 'GlobalHook'
      || (code === 'Backspace' && this.screen && this.screen !== 'main');
    // Suppress the host's own scroll/focus navigation on both edges of the key.
    if (handled && typeof event.preventDefault === 'function') event.preventDefault();
    return this.guard('key', () => {
      const action = this.gesture(type, code, !!event.repeat);
      const now = Date.now();
      this.report('key', type + ':' + code + ':' + action, this.lastKeyAt ? now - this.lastKeyAt : 0);
      this.lastKeyAt = now;
      this.trace(type + ' ' + code, action);
      if (action === 'hook') {
        stopTimer(this.hookTimer);
        this.hookTimer = setTimeout(() => {
          this.hookTimer = null;
          this.guard('key', () => {
            if (this.isTwin()) return this.report('key', 'hook:twin', 0);
            this.actionAt = Date.now();
            this.report('key', 'hook:tap', 0);
            this.trace('GlobalHook', 'касание');
            return this.confirm();
          });
        }, HOOK_DELAY_MS);
        return;
      }
      if (action !== 'act') return;
      if (code === 'Backspace') return this.back();
      if (DIRECTION_KEYS.includes(code)) return this.step(FORWARD_KEYS.includes(code) ? 1 : -1);
      return this.confirm();
    });
  },

  isTwin() {
    return !!this.actionAt && Date.now() - this.actionAt < TWIN_MS;
  },

  // Decides whether a raw key edge performs an action; each physical gesture acts once.
  gesture(type, code, repeat) {
    const now = Date.now();
    if (code === 'Backspace') {
      if (!this.screen || this.screen === 'main') return 'system';
      return type === 'down' ? 'wait' : 'act';
    }
    if (DIRECTION_KEYS.includes(code)) {
      if (this.hookTimer) {
        // The GlobalHook that started this swipe is not a tap.
        stopTimer(this.hookTimer);
        this.hookTimer = null;
      }
      if (type === 'up' && this.keysDown[code]) { delete this.keysDown[code]; return 'end'; }
      if (type === 'down') this.keysDown[code] = true;
      if (repeat) return 'skip';
      const swipe = this.swipe && now - this.swipe.at < SWIPE_WINDOW_MS ? this.swipe : null;
      if (swipe) {
        // The paired arrow of the same swipe (Right+Down, Left+Up) is ignored.
        if (swipe.stepped) return 'skip';
        swipe.stepped = true;
      } else if (this.stepAt && now - this.stepAt < FALLBACK_GAP_MS) {
        return 'skip';
      }
      this.stepAt = now;
      return 'act';
    }
    if (code !== 'Enter' && code !== 'GlobalHook') return 'other';
    if (code === 'GlobalHook') {
      // A new physical gesture starts here, whether it becomes a swipe or a tap.
      if (type === 'down') { this.swipe = { at: now, stepped: false, open: true }; return 'wait'; }
      if (this.swipe && this.swipe.open) this.swipe.open = false;
      else this.swipe = { at: now, stepped: false, open: false };
      if (repeat || this.isTwin()) return 'twin';
      return 'hook';
    }
    if (type === 'down') return 'wait';
    if (repeat || this.isTwin() || this.hookTimer) return 'twin';
    if (this.stepAt && now - this.stepAt < 300) return 'skip';
    this.actionAt = now;
    return 'act';
  },

  onVoiceWakeup(event) {
    // A temple long-press inside Neo means "talk to Neo", not the system assistant.
    if (event && typeof event.preventDefault === 'function') event.preventDefault();
    return this.guard('wakeup', () => {
      this.trace('Wakeup', 'talk');
      this.report('key', 'wakeup:' + (event && event.keyword || ''), 0);
      this.goMain();
      return this.toggleTalk();
    });
  },

  // A tap event right after a swipe or a key confirm is the host echoing the same gesture.
  tapIgnored() {
    const now = Date.now();
    if ((this.stepAt && now - this.stepAt < 600) || this.isTwin() || this.hookTimer) {
      this.report('key', 'tap_ignored', this.stepAt ? now - this.stepAt : 0);
      return true;
    }
    this.actionAt = now;
    return false;
  },

  // Pointer clicks in Craft.
  tapAction(event) {
    const index = Number(event && event.currentTarget && event.currentTarget.dataset && event.currentTarget.dataset.index);
    return this.guard('tap', () => {
      if (this.tapIgnored() || !Number.isInteger(index) || index < 0 || index >= ACTIONS.length) return;
      this.selected = index;
      return this.confirm();
    });
  },

  tapMenu(event) {
    const index = Number(event && event.currentTarget && event.currentTarget.dataset && event.currentTarget.dataset.index);
    return this.guard('tap', () => {
      if (this.tapIgnored() || !Number.isInteger(index)) return;
      this.menuIndex = index;
      return this.confirm();
    });
  },

  tapScreen() {
    return this.guard('tap', () => {
      if (this.tapIgnored()) return;
      this.report('key', 'tap', 0);
      return this.confirm();
    });
  },

  trace(code, action) {
    const now = Date.now();
    const interval = this.lastTraceAt ? now - this.lastTraceAt : 0;
    this.lastTraceAt = now;
    this.navLog.push(code + ' / ' + interval + ' мс / ' + action);
    if (this.navLog.length > 30) this.navLog.shift();
  },

  step(delta) {
    if (this.screen === 'menu') {
      const count = this.menuItems().length;
      const next = Math.max(0, Math.min(count - 1, this.menuIndex + delta));
      this.edge = next === this.menuIndex ? (delta < 0 ? '▲ начало' : '▼ конец') : '';
      this.menuIndex = next;
      this.renderMenu();
    } else if (this.screen === 'info') {
      this.offset = Math.max(0, Math.min(this.maxOffset || 0, this.offset + delta * READ_STEP_ROWS));
      this.renderBody();
    } else if (this.selected === 1) {
      // On "Меню": back returns to the conversation, forward stays.
      if (delta < 0) { this.selected = 0; this.render(); }
    } else if (delta > 0 && this.offset >= (this.maxOffset || 0)) {
      // Past the end of the conversation the selection moves to "Меню".
      this.selected = 1;
      this.render();
    } else {
      this.offset = Math.max(0, Math.min(this.maxOffset || 0, this.offset + delta * READ_STEP_ROWS));
      this.renderBody();
    }
  },

  // Brief highlight so the owner sees that a tap was taken.
  press(target) {
    this.pressed = target;
    stopTimer(this.pressTimer);
    this.pressTimer = setTimeout(() => {
      this.pressTimer = null;
      this.pressed = '';
      if (this.screen === 'menu') this.renderMenu();
      else this.render();
    }, PRESS_MS);
  },

  confirm() {
    if (this.screen === 'menu') {
      this.press('menu:' + this.menuIndex);
      return this.activateMenu();
    }
    if (this.screen === 'info') return this.back();
    this.press('action:' + this.selected);
    return this.activate();
  },

  back() {
    if (this.screen === 'menu' && this.menuLevel === 'service') return this.openMenu('main', 'service');
    if (this.screen === 'info' && this.menuLevel === 'service') return this.openMenu('service', this.returnItem);
    return this.goMain();
  },

  // ---- telemetry -----------------------------------------------------------

  report(code, detail, value) {
    if (!this.events) return;
    const event = { code, phase: safeToken(this.phase || '').toLowerCase().replace(/[^a-z_]/g, '').slice(0, 16) };
    if (detail !== undefined && detail !== null) event.detail = safeToken(detail);
    if (Number.isFinite(value)) event.value = Math.max(-1, Math.min(100000000, Math.round(value)));
    this.events.push(event);
    if (this.events.length > 60) this.events.splice(0, this.events.length - 60);
    if (!this.telemetryTimer) {
      this.telemetryTimer = setTimeout(() => {
        this.telemetryTimer = null;
        this.flushEvents();
      }, TELEMETRY_MS);
    }
  },

  async flushEvents() {
    stopTimer(this.telemetryTimer);
    this.telemetryTimer = null;
    if (!this.connection || this.sendingEvents || !this.events || !this.events.length) return;
    const batch = this.events.splice(0, 20);
    this.sendingEvents = true;
    try {
      const result = await this.request('/v1/diagnostics', { token: this.connection.token, body: { events: batch }, timeout: CONNECT_TIMEOUT_MS });
      // A rejected batch is dropped: retrying cannot fix it.
      if (!result.ok && result.status >= 500) this.events = batch.concat(this.events).slice(-60);
    } catch (_) {
      this.events = batch.concat(this.events).slice(-60);
    } finally {
      this.sendingEvents = false;
    }
    if (this.events.length && !this.telemetryTimer) {
      this.telemetryTimer = setTimeout(() => {
        this.telemetryTimer = null;
        this.flushEvents();
      }, TELEMETRY_MS);
    }
  },

  activate() {
    const action = ACTIONS[this.selected];
    if (action === 'menu') {
      this.selected = 0;
      return this.openMenu('main');
    }
    return this.toggleTalk();
  },

  goMain() {
    this.stopMicTest();
    const leavingMenu = this.screen === 'menu' || this.screen === 'info';
    this.screen = 'main';
    this.menuLevel = 'main';
    if (leavingMenu && this.feedOffset !== undefined) this.offset = this.feedOffset;
    if (leavingMenu && this.connection && this.phase === 'paused') this.setPhase('idle', 'Коснитесь «Говорить».');
    else this.render();
  },

  toggleTalk() {
    this.stopMicTest();
    if (!this.connection) return this.connect();
    if (this.voice || this.chat) {
      this.stopVoice();
      this.cancelChat();
      return this.setPhase('paused', 'Остановлено. Коснитесь, чтобы говорить.');
    }
    return this.startVoice(false);
  },

  // ---- settings ------------------------------------------------------

  menuItems() {
    const p = this.prefs;
    if (this.menuLevel === 'service') {
      return [
        { id: 'mictest', label: 'Тест микрофона', value: '' },
        { id: 'diagnostics', label: 'Проверка устройства', value: '' },
        { id: 'reconnect', label: 'Переподключить', value: '' },
        { id: 'up', label: '‹ Назад', value: '' }
      ];
    }
    return [
      { id: 'voice', label: 'Голос ответа', value: p.voice === 'off' ? 'выключен' : 'включён' },
      { id: 'talk', label: 'Разговор', value: p.talk === 'tap' ? 'по касанию' : 'непрерывный' },
      { id: 'sensitive', label: 'Микрофон', value: p.sensitive ? 'тихая речь' : 'обычный' },
      { id: 'new', label: 'Новый разговор', value: '' },
      { id: 'memory', label: 'Показать память', value: '' },
      { id: 'service', label: 'Сервис', value: '›' },
      { id: 'back', label: 'Готово', value: '' }
    ];
  },

  openMenu(level = 'main', focusId = '') {
    if ((this.screen || 'main') === 'main') this.feedOffset = this.offset;
    this.stopMicTest();
    this.stopVoice();
    this.cancelChat();
    this.menuLevel = level;
    this.screen = 'menu';
    this.edge = '';
    const index = this.menuItems().findIndex(item => item.id === focusId);
    this.menuIndex = index >= 0 ? index : 0;
    if (this.connection) this.setPhase('paused', level === 'service' ? 'Сервис и проверки.' : 'Настройки.');
    else this.render();
  },

  renderMenu() {
    this.setData(this.menuData());
  },

  menuData() {
    const items = this.menuItems();
    // A fixed window of rows around the selection; the list stops at its ends.
    const size = 5;
    const start = Math.max(0, Math.min(this.menuIndex - 2, items.length - size));
    const marks = (start > 0 ? ' ▲' : '') + (start + size < items.length ? ' ▼' : '');
    return {
      menuTitle: (this.menuLevel === 'service' ? 'СЕРВИС  ' : 'НАСТРОЙКИ  ') + (this.menuIndex + 1) + '/' + items.length
        + (this.edge ? '  · ' + this.edge : marks),
      menuRows: items.slice(start, start + size).map((item, offset) => ({
        id: item.id,
        index: start + offset,
        label: item.label,
        value: item.value,
        cls: 'row' + (start + offset === this.menuIndex ? ' row-on' : '') + (this.pressed === 'menu:' + (start + offset) ? ' press' : '')
      })),
      bodyLines: [],
      thumb: ''
    };
  },

  activateMenu() {
    const item = this.menuItems()[this.menuIndex];
    if (!item) return;
    const p = this.prefs;
    this.edge = '';
    if (item.id === 'voice') p.voice = p.voice === 'off' ? 'on' : 'off';
    else if (item.id === 'talk') p.talk = p.talk === 'tap' ? 'continuous' : 'tap';
    else if (item.id === 'sensitive') p.sensitive = !p.sensitive;
    else if (item.id === 'new') return this.newConversation();
    else if (item.id === 'memory') { this.goMain(); return this.ask('покажи память', null); }
    else if (item.id === 'service') return this.openMenu('service');
    else if (item.id === 'up') return this.openMenu('main', 'service');
    else if (item.id === 'diagnostics') { this.returnItem = 'diagnostics'; return this.showDiagnostics(); }
    else if (item.id === 'mictest') { this.returnItem = 'mictest'; return this.startMicTest('wx'); }
    else if (item.id === 'reconnect') { this.connection = null; this.goMain(); return this.connect(); }
    else if (item.id === 'back') return this.goMain();
    if (item.id === 'voice' && p.voice === 'on') this.speakRokid('Голос включён.', null);
    writeLocal(PREFS_KEY, p);
    this.renderMenu();
  },

  newConversation() {
    this.stopVoice();
    this.cancelChat();
    this.conversationId = null;
    this.retry = null;
    this.goMain();
    this.clearHistory('Начат новый разговор. Сохранённые факты доступны.');
    this.setPhase(this.connection ? 'idle' : 'offline', 'Коснитесь «Говорить».');
  },

  showDiagnostics() {
    const nav = typeof navigator === 'undefined' ? {} : navigator;
    const has = name => typeof globalThis[name] !== 'undefined' ? 'есть' : 'нет';
    let recorder = 'нет';
    try { recorder = wx && wx.media && wx.media.getRecorderManager && wx.media.getRecorderManager() ? 'есть' : 'нет'; } catch (_) { recorder = 'ошибка'; }
    const lines = [
      'NEO ' + VERSION + ' · ' + String(nav.userAgent || '?').slice(0, 60),
      'Ink: ' + String(nav.versions && nav.versions.ink || '?') + ' · язык: ' + String(nav.language || '?'),
      'SpeechRecognition: ' + has('SpeechRecognition') + ' · Session: ' + has('SpeechRecognitionSession'),
      'Запись wx: ' + recorder + ' · getUserMedia: ' + (nav.mediaDevices && nav.mediaDevices.getUserMedia ? 'есть' : 'нет'),
      'Синтез речи: ' + has('speechSynthesis') + ' · AudioContext: ' + has('AudioContext'),
      'Окно в фокусе: ' + (this.focused ? 'да' : 'нет') + ' · связь: ' + (this.connection ? 'есть' : 'нет'),
      'Последний режим: ' + (this.lastVoiceApi || 'не запускался'),
      'Аудиокадров: ' + (this.audioFrames || 0),
      'Последняя ошибка: ' + this.lastError,
      'Управление (код / интервал / действие):'
    ].concat(this.navLog.slice(-12));
    this.screen = 'info';
    this.infoText = lines;
    this.offset = 0;
    this.setPhase(this.connection ? 'paused' : 'offline', 'Проверка устройства.');
  },

  // Runs capture only (no recognition) so the owner can see whether audio arrives.
  startMicTest(kind) {
    this.stopVoice();
    this.cancelChat();
    const test = { kind, startedAt: Date.now(), frames: 0, bytes: 0, level: 0, peak: 0, state: 'запуск', error: '' };
    this.micTest = test;
    this.screen = 'info';
    this.offset = 0;
    this.report('voice_start', 'mictest:' + kind + ':focus=' + String(this.focused));
    const fail = (code, error) => {
      if (this.micTest !== test) return;
      test.state = 'ошибка';
      test.error = code + ' ' + String(error && (error.errMsg || error.name || error.message) || '').slice(0, 50);
      this.report('asr_error', 'mictest:' + kind + ':' + code + ':' + safeToken(test.error).slice(0, 30), Date.now() - test.startedAt);
      this.renderMicTest();
    };
    try {
      if (kind === 'wx') {
        const recorder = wx && wx.media && wx.media.getRecorderManager ? wx.media.getRecorderManager() : null;
        if (!recorder) return fail(wx ? 'recorder_unavailable' : 'wx_missing');
        test.recorder = recorder;
        recorder.onFrameRecorded(event => {
          if (this.micTest !== test) return;
          const frame = event && event.frameBuffer;
          if (!frame || !frame.byteLength) return;
          test.frames++;
          test.bytes += frame.byteLength;
          const view = new DataView(frame.slice(0, frame.byteLength - (frame.byteLength % 2)));
          let energy = 0;
          for (let i = 0; i < view.byteLength; i += 2) { const v = view.getInt16(i, true) / 32768; energy += v * v; }
          const rms = view.byteLength ? Math.sqrt(energy / (view.byteLength / 2)) : 0;
          test.level = Math.min(1, rms * 12);
          test.peak = Math.max(test.peak, test.level);
          test.state = 'идут кадры';
          if (test.frames === 1) this.report('mic_frames', 'mictest:wx:first:' + frame.byteLength, Date.now() - test.startedAt);
        });
        recorder.onError(error => fail('onError', error));
        recorder.onStop(() => { if (this.micTest === test && test.state !== 'ошибка') test.state = 'остановлен системой'; });
        Promise.resolve(recorder.start({ sampleRate: 16000, numberOfChannels: 1, format: 'pcm', frameSize: 250 }))
          .then(() => { if (this.micTest === test && !test.frames) test.state = 'запущен, ждём кадры'; }, error => fail('start_rejected', error));
      } else {
        const media = typeof navigator !== 'undefined' && navigator.mediaDevices;
        if (!media || !media.getUserMedia || typeof MediaRecorder !== 'function') return fail('media_unavailable');
        Promise.resolve(media.getUserMedia({ audio: true })).then(stream => {
          if (this.micTest !== test) { stream.getTracks().forEach(track => track.stop()); return; }
          test.stream = stream;
          const track = stream.getAudioTracks ? stream.getAudioTracks()[0] : null;
          const settings = track && track.getSettings ? track.getSettings() : {};
          test.info = 'трек: ' + (track ? 'есть' : 'нет') + ' ' + (settings.sampleRate || '?') + ' Гц';
          const recorder = new MediaRecorder(stream, { mimeType: 'audio/wav' });
          test.mediaRecorder = recorder;
          recorder.ondataavailable = event => {
            if (this.micTest !== test || !event.data) return;
            test.frames++;
            test.bytes += event.data.size || 0;
            test.state = 'идут данные';
            if (test.frames === 1) this.report('mic_frames', 'mictest:media:first:' + (event.data.size || 0), Date.now() - test.startedAt);
          };
          recorder.onerror = event => fail('recorder_error', event && event.error);
          recorder.start(250);
          test.state = 'запущен, ждём данные';
          // Level meter from Web Audio when available; never connected to the speaker.
          if (typeof AudioContext === 'function') {
            try {
              const context = new AudioContext();
              test.context = context;
              const source = context.createMediaStreamSource(stream);
              const analyser = context.createAnalyser();
              source.connect(analyser);
              Promise.resolve(context.resume()).catch(() => {});
              const samples = new Float32Array(analyser.fftSize);
              test.sample = () => {
                analyser.getFloatTimeDomainData(samples);
                let energy = 0;
                for (let i = 0; i < samples.length; i++) energy += samples[i] * samples[i];
                test.level = Math.min(1, Math.sqrt(energy / samples.length) * 12);
                test.peak = Math.max(test.peak, test.level);
              };
            } catch (error) { test.info += ' · анализатор: ' + String(error && error.name || error).slice(0, 30); }
          }
        }, error => fail('getUserMedia', error));
      }
    } catch (error) {
      fail('exception', error);
    }
    const tick = () => {
      if (this.micTest !== test) return;
      if (test.sample) { try { test.sample(); } catch (_) { test.sample = null; } }
      const elapsed = Date.now() - test.startedAt;
      if (!test.frames && elapsed > 4000 && test.state !== 'ошибка') test.state = 'НЕТ КАДРОВ — микрофон не включился';
      this.renderMicTest();
      if (elapsed >= 20000) return this.stopMicTest();
      test.timer = setTimeout(tick, 250);
    };
    this.setPhase(this.connection ? 'paused' : 'offline', 'Говорите: уровень должен расти. Касание — стоп.');
    tick();
  },

  renderMicTest() {
    const test = this.micTest;
    if (!test) return;
    this.infoText = [
      'ТЕСТ МИКРОФОНА · ' + (test.kind === 'wx' ? 'wx.media RecorderManager PCM' : 'getUserMedia + MediaRecorder'),
      meter(test.level, test.frames),
      'Пик: ' + Math.round(test.peak * 100) + '% · байт: ' + test.bytes + ' · ' + Math.round((Date.now() - test.startedAt) / 1000) + ' с',
      'Состояние: ' + test.state,
      test.info || '',
      test.error ? 'Ошибка: ' + test.error : '',
      'Окно в фокусе: ' + String(this.focused)
    ].filter(Boolean);
    if (this.screen === 'info') this.renderBody();
  },

  stopMicTest() {
    const test = this.micTest;
    if (!test) return;
    this.micTest = null;
    stopTimer(test.timer);
    this.report('mic_frames', 'mictest:' + test.kind + ':end:peak=' + Math.round(test.peak * 100) + ':' + safeToken(test.state).slice(0, 20), test.frames);
    if (test.recorder) { try { Promise.resolve(test.recorder.stop()).catch(() => {}); } catch (_) {} }
    if (test.mediaRecorder) { try { test.mediaRecorder.stop(); } catch (_) {} }
    if (test.stream) { try { test.stream.getTracks().forEach(track => track.stop()); } catch (_) {} }
    if (test.context) { try { Promise.resolve(test.context.close()).catch(() => {}); } catch (_) {} }
    const lines = this.infoText.slice();
    lines[3] = 'Итог: ' + (test.frames ? 'микрофон РАБОТАЕТ, пик ' + Math.round(test.peak * 100) + '%' : 'кадров НЕТ — микрофон не включился');
    this.infoText = lines;
    this.flushEvents();
    if (this.screen === 'info') this.renderBody();
  },

  // ---- connection ------------------------------------------------------

  async request(path, { token, body, timeout = REQUEST_TIMEOUT_MS, binary = false, owner } = {}) {
    const headers = { 'Accept': binary ? 'audio/pcm' : 'application/json' };
    if (token) headers['Authorization'] = 'Bearer ' + token;
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    const controller = typeof AbortController === 'function' ? new AbortController() : null;
    if (owner) owner.abort = controller;
    let timer = null;
    const deadline = new Promise((_, reject) => {
      timer = setTimeout(() => {
        timer = null;
        if (controller) { try { controller.abort(); } catch (_) {} }
        reject(Object.assign(new Error('timeout'), { code: 'timeout' }));
      }, timeout);
    });
    try {
      const response = await Promise.race([fetch(NEO_BASE_URL + path, {
        method: 'POST', timeout, headers,
        ...(controller ? { signal: controller.signal } : {}),
        ...(body !== undefined ? { body: typeof body === 'string' ? body : JSON.stringify(body) } : {})
      }), deadline]);
      let data = null;
      if (response.ok && binary) data = await response.arrayBuffer();
      else { try { data = await response.json(); } catch (_) { data = null; } }
      return { status: response.status, ok: response.ok, data, headers: response.headers };
    } finally {
      stopTimer(timer);
      if (owner) owner.abort = null;
    }
  },

  // silent: re-authenticate in the background during a question, without touching the UI.
  async connect({ silent = false } = {}) {
    if (this.connecting) return !!this.connection;
    this.connecting = true;
    stopTimer(this.connectTimer);
    this.connectTimer = null;
    if (!silent) this.setPhase('connecting', 'Подключение к Neo…');
    const offline = message => {
      this.connecting = false;
      this.connection = null;
      if (silent) return false;
      // Keep trying in the background: the phone link often comes back by itself.
      this.connectAttempts = (this.connectAttempts || 0) + 1;
      const delay = [5000, 15000, 30000][Math.min(2, this.connectAttempts - 1)];
      this.setPhase('offline', message + ' Повтор через ' + Math.round(delay / 1000) + ' с.');
      this.connectTimer = setTimeout(() => {
        this.connectTimer = null;
        if (!this.connection && this.phase === 'offline') this.guard('connect', () => this.connect());
      }, delay);
      return false;
    };
    try {
      const stored = readLocal(ACCESS_KEY);
      let token = await this.renew(stored);
      if (!token) {
        // Never ask the owner in the background: a confirmation must follow a visible request.
        if (silent) {
          this.connecting = false;
          this.connection = null;
          return false;
        }
        const paired = await this.pair();
        token = paired.token;
        if (!token) {
          if (paired.reason === 'network') return offline('Нет связи с Neo: проверьте интернет телефона.');
          this.connecting = false;
          this.connection = null;
          return false;
        }
      }
      const check = await this.request('/v1/auth/check', { token, body: {}, timeout: CONNECT_TIMEOUT_MS });
      const info = check.data;
      if (!check.ok || !info || info.status !== 'ok' || typeof info.user_id !== 'string' || typeof info.device_id !== 'string') {
        if (check.status === 401) writeLocal(ACCESS_KEY, null);
        return offline(check.status === 401
          ? 'Доступ Neo отозван. Коснитесь «Говорить», чтобы подтвердить заново.'
          : check.status === 429 ? 'Слишком много попыток.'
          : 'Сервер Neo отказал (HTTP ' + check.status + ').');
      }
      this.connection = { token, userId: info.user_id, deviceId: info.device_id };
      this.connecting = false;
      this.connectAttempts = 0;
      if (silent) {
        this.report('app_start', 'reconnected');
        return true;
      }
      const nav = typeof navigator === 'undefined' ? {} : navigator;
      this.report('app_start', 'session ' + this.sessionTag + ' device ' + (/Trae|Craft|Mozilla/i.test(String(nav.userAgent)) ? 'craft' : 'glasses'));
      this.report('app_start', VERSION + ' ' + String(nav.userAgent || '') + ' ink:' + String(nav.versions && nav.versions.ink || '?'));
      this.report('app_start', 'api SR:' + (typeof SpeechRecognition) + ' SRS:' + (typeof SpeechRecognitionSession)
        + ' TTS:' + (typeof speechSynthesis) + ' AC:' + (typeof AudioContext) + ' wx:' + (wx ? 'yes' : typeof wx));
      this.report('app_start', 'locale ' + String(nav.language || '?') + ' ' + String(Array.isArray(nav.languages) ? nav.languages.slice(0, 3).join(',') : '')
        + ' region ' + String(nav.region || '?'));
      this.report('app_start', 'prefs voice:' + this.prefs.voice + ' talk:' + this.prefs.talk
        + ' mic:' + (this.prefs.sensitive ? 'quiet' : 'normal'));
      this.flushEvents();
      const first = !readLocal(PREFS_KEY);
      if (first) writeLocal(PREFS_KEY, this.prefs);
      if (!this.history.length) {
        this.setNotice(first
          ? 'Neo готов. Коснитесь дужки и спросите: он сам поищет в интернете, если нужно. Свайп листает разговор, в конце — меню.'
          : 'Neo готов. Коснитесь дужки, чтобы говорить.');
      }
      this.setPhase('idle', 'Подключено.');
      return true;
    } catch (_) {
      return offline('Нет связи с Neo: проверьте интернет телефона.');
    }
  },

  delay(ms, owner) {
    return new Promise(resolve => {
      const id = setTimeout(resolve, ms);
      if (owner) owner.delayTimer = id;
    });
  },

  // One automatic recovery per request: a network error is retried once, and an expired
  // access token is renewed once. Server-side idempotency (client_message_id) makes the
  // chat retry safe; a transcription retry is billed again, so it also happens only once.
  async authed(path, options, owner) {
    let result;
    try {
      result = await this.request(path, Object.assign({}, options, { token: this.connection.token, owner }));
    } catch (error) {
      if (owner && owner.active === false) throw error;
      this.report('chat_error', 'retry:' + path.slice(4) + ':' + (error && error.code || 'network'));
      await this.delay(RETRY_DELAY_MS, owner);
      if ((owner && owner.active === false) || !this.connection) throw error;
      result = await this.request(path, Object.assign({}, options, { token: this.connection.token, owner }));
    }
    if ((result.status === 401 || result.status === 403) && !(owner && owner.active === false)) {
      this.report('chat_error', 'reauth:' + path.slice(4), result.status);
      if (await this.connect({ silent: true })) {
        result = await this.request(path, Object.assign({}, options, { token: this.connection.token, owner }));
      }
    }
    return result;
  },

  // Reuse an earlier confirmation. Returns '' when the owner has to confirm again.
  async renew(stored) {
    if (!stored || typeof stored.refresh_token !== 'string') return '';
    if (stored.build !== VERSION || !(Date.now() - Number(stored.at || 0) < ACCESS_MAX_AGE_MS)) {
      this.report('pair', 'stored:' + (stored.build === VERSION ? 'expired' : 'build'));
      writeLocal(ACCESS_KEY, null);
      return '';
    }
    try {
      const renewed = await this.request('/v1/auth/refresh', { body: { refresh_token: stored.refresh_token }, timeout: CONNECT_TIMEOUT_MS });
      if (renewed.ok && renewed.data && typeof renewed.data.access_token === 'string') {
        this.report('pair', 'stored:ok');
        return renewed.data.access_token;
      }
      if (renewed.status === 401) {
        writeLocal(ACCESS_KEY, null);
        this.report('pair', 'stored:revoked');
      }
    } catch (_) {}
    return '';
  },

  // Ask the owner for access and wait for the button in Telegram. The code on the screen is
  // the one the bot shows, so the owner can see that this request is really from the glasses.
  async pair() {
    let started;
    try {
      started = await this.request('/v1/pair/start', { body: { label: 'glasses ' + VERSION }, timeout: CONNECT_TIMEOUT_MS });
    } catch (_) {
      this.report('pair', 'start:network');
      return { token: '', reason: 'network' };
    }
    const data = started.data || {};
    const error = data.error || {};
    if (!started.ok || typeof data.pair_id !== 'string' || typeof data.code !== 'string') {
      this.report('pair', 'start:' + safeToken(error.code || 'http').slice(0, 20), started.status);
      this.clearHistory(error.code === 'pair_unbound'
        ? 'Telegram ещё не привязан. Откройте бота NEO, отправьте /start и коснитесь «Говорить».'
        : (error.message || 'Сервер Neo не отвечает (HTTP ' + started.status + ').'));
      this.setPhase('offline', 'Доступ не подтверждён.');
      return { token: '', reason: 'server' };
    }
    const code = String(data.code).slice(0, 4);
    this.report('pair', 'start:ok');
    this.clearHistory('Подтвердите доступ в Telegram.\nКод: ' + code.slice(0, 2) + '-' + code.slice(2)
      + '\nОткройте бота NEO, сверьте код и нажмите «Подтвердить».');
    this.setPhase('connecting', 'Жду подтверждения в Telegram…');
    const step = Math.max(1000, Number(data.poll_interval) * 1000 || PAIR_POLL_MS);
    const until = Date.now() + Math.min(PAIR_WAIT_MS, (Number(data.expires_in) || 180) * 1000);
    while (Date.now() < until) {
      await this.delay(step);
      let polled;
      try {
        polled = await this.request('/v1/pair/poll', { body: { pair_id: data.pair_id }, timeout: CONNECT_TIMEOUT_MS });
      } catch (_) { continue; }
      const body = polled.data || {};
      if (body.status === 'approved' && typeof body.access_token === 'string') {
        if (typeof body.refresh_token === 'string') {
          writeLocal(ACCESS_KEY, { refresh_token: body.refresh_token, build: VERSION, at: Date.now() });
        }
        this.report('pair', 'approved');
        return { token: body.access_token, reason: 'ok' };
      }
      if (body.status === 'denied' || body.status === 'expired') {
        this.report('pair', body.status);
        this.clearHistory(body.status === 'denied'
          ? 'Доступ отклонён в Telegram. Коснитесь «Говорить», чтобы запросить снова.'
          : 'Время подтверждения вышло. Коснитесь «Говорить», чтобы запросить снова.');
        this.setPhase('offline', 'Доступ не подтверждён.');
        return { token: '', reason: body.status };
      }
    }
    this.report('pair', 'timeout');
    this.clearHistory('Подтверждение из Telegram не пришло. Коснитесь «Говорить», чтобы запросить снова.');
    this.setPhase('offline', 'Доступ не подтверждён.');
    return { token: '', reason: 'timeout' };
  },

  // ---- chat ----------------------------------------------------------------

  cancelChat() {
    if (!this.chat) return;
    this.chat.active = false;
    stopTimer(this.chat.delayTimer);
    if (this.chat.abort) { try { this.chat.abort.abort(); } catch (_) {} }
    this.chat = null;
  },

  // Returns true when an answer was shown.
  async ask(text, voice) {
    if (!this.connection) { await this.connect(); if (!this.connection) return false; }
    const message = String(text || '').trim();
    if (!message) return false;
    if (!this.conversationId) this.conversationId = newId();
    if (!this.retry || this.retry.text !== message) this.retry = { text: message, id: newId() };
    this.cancelChat();
    const chat = { active: true, abort: null };
    this.chat = chat;
    this.showTranscript(message);
    this.deepThinking = DEEP_REQUEST.test(message);
    this.setPhase('thinking', this.deepThinking ? 'Думаю глубже, до 20 секунд…' : 'Neo думает…');
    let result;
    try {
      result = await this.authed('/v1/chat', {
        body: {
          user_id: this.connection.userId, device_id: this.connection.deviceId, message,
          session_id: this.conversationId, client_message_id: this.retry.id, web_search: true
        }
      }, chat);
    } catch (error) {
      if (!chat.active) return false;
      this.chat = null;
      this.lastError = 'chat: ' + (error && error.code || 'network');
      this.report('chat_error', error && error.code || 'network');
      this.setPhase('error', error && error.code === 'timeout'
        ? 'Сервер не ответил вовремя. Коснитесь «Говорить» — вопрос повторится.'
        : 'Нет связи с Neo. Коснитесь «Говорить» — вопрос повторится.');
      return false;
    }
    if (!chat.active) return false;
    this.chat = null;
    const body = result.data || {};
    if (!result.ok) {
      const code = body.error && body.error.code;
      this.lastError = 'chat HTTP ' + result.status + (code ? ' ' + code : '');
      this.report('chat_error', code || 'http', result.status);
      if (result.status === 401 || result.status === 403) {
        this.connection = null;
        this.setPhase('offline', 'Доступ Neo не восстановился. Коснитесь, чтобы переподключиться.');
        return false;
      }
      const messages = {
        429: code === 'budget_exceeded' ? 'Достигнут месячный бюджет Neo.' : 'Лимит запросов. Подождите минуту.',
        409: 'Neo ещё обрабатывает прошлый вопрос. Повторите через секунду.',
        504: 'Сервер не ответил вовремя. Коснитесь «Говорить» — вопрос повторится.'
      };
      if (code === 'context_changed') this.retry = null;
      this.setPhase('error', messages[result.status] || (body.error && body.error.message) || ('Ошибка сервера (HTTP ' + result.status + ').'));
      return false;
    }
    if (typeof body.message !== 'string' || !body.message.trim() || typeof body.session_id !== 'string' || !UUID.test(body.session_id)) {
      this.lastError = 'chat: invalid_response';
      this.setPhase('error', 'Сервер вернул неожиданный ответ.');
      return false;
    }
    this.retry = null;
    this.conversationId = body.session_id;
    const sources = Array.isArray(body.sources)
      ? body.sources.filter(s => s && typeof s.url === 'string' && /^https?:\/\//.test(s.url)).slice(0, 5) : [];
    this.addTurn(body.context_reset ? message + ' (прошлый разговор истёк)' : message, body.message, sources);
    const deep = typeof body.model === 'string' && body.model && body.model !== 'gpt-5.6-luna';
    this.setPhase('idle', body.budget && body.budget.warning ? 'Бюджет: использовано более 80%.'
      : deep ? 'Ответ готов (глубокий режим).' : 'Ответ готов.');
    return true;
  },

  // ---- voice: common -----------------------------------------------------

  startVoice(auto) {
    if (this.voice || !this.connection) return;
    if (this.screen !== 'main') this.goMain();
    const voice = { kind: 'server', auto, level: 0, startedAt: Date.now() };
    this.voice = voice;
    const retry = this.retry;
    this.report('voice_start', 'server' + (retry ? ':retry' : '') + (auto ? ':auto' : ':tap') + ':focus=' + String(this.focused));
    this.setPhase('starting', auto ? 'Слушаю следующий вопрос…' : 'Включаю микрофон…');
    this.armStartTimeout(voice);
    // Recording starts inside the tap even for a retry, so free conversation can go on.
    this.startServer(voice, !retry);
    if (retry && this.voice === voice) {
      stopTimer(voice.startTimer);
      voice.startTimer = null;
      return this.afterPhrase(voice, retry.text);
    }
  },

  armStartTimeout(voice) {
    stopTimer(voice.startTimer);
    voice.startTimer = setTimeout(() => {
      voice.startTimer = null;
      if (this.voice === voice && this.phase === 'starting') {
        this.report('asr_error', 'start_timeout:server', this.audioFrames || 0);
        this.voiceFailed(voice, 'start_timeout', 'Микрофон не включился за 8 секунд. Проверьте разрешение Microphone и коснитесь.');
      }
    }, START_TIMEOUT_MS);
  },

  listening(voice, status) {
    if (this.voice !== voice) return;
    stopTimer(voice.startTimer);
    voice.startTimer = null;
    if (this.phase !== 'listening') this.setPhase('listening', status);
  },

  stopVoice() {
    const voice = this.voice;
    this.voice = null;
    if (!voice) return;
    for (const key of ['startTimer', 'playTimer', 'delayTimer']) {
      stopTimer(voice[key]);
      voice[key] = null;
    }
    if (voice.recorder) {
      const recorder = voice.recorder;
      Promise.resolve(voice.recorderStart).catch(() => {}).then(() => {
        try { return recorder.stop(); } catch (_) {}
      }).catch(() => {});
    }
    if (voice.player) { try { voice.player.stop(); } catch (_) {} try { voice.player.destroy(); } catch (_) {} }
    if (voice.task) { try { voice.task.abort(); } catch (_) {} }
    if (voice.output) { voice.output.onended = null; try { voice.output.stop(); } catch (_) {} }
    if (voice.context) { try { Promise.resolve(voice.context.close()).catch(() => {}); } catch (_) {} }
    if (voice.abort) { try { voice.abort.abort(); } catch (_) {} }
    if (voice.speaking && typeof speechSynthesis !== 'undefined') {
      // speak() has no cancel(); an immediate blank utterance replaces the answer being read.
      try { speechSynthesis.speak(new SpeechSynthesisUtterance(' '), 'immediate'); } catch (_) {}
    }
    this.renderFace();
  },

  voiceFailed(voice, code, message) {
    if (this.voice !== voice) return;
    this.lastError = code;
    this.report('asr_error', 'failed:' + code, Date.now() - (voice.startedAt || Date.now()));
    this.stopVoice();
    this.setPhase('error', message);
  },

  // Nobody spoke: pause instead of listening forever.
  voiceSilent(voice) {
    if (this.voice !== voice) return;
    this.report('asr_event', 'silent:' + voice.kind + ':frames=' + (voice.frameCount || 0) + ':peak=' + Math.round((voice.peak || 0) * 10000),
      Date.now() - (voice.startedAt || Date.now()));
    this.stopVoice();
    this.setPhase('paused', voice.auto
      ? 'Пауза: вопроса не было. Коснитесь «Говорить», чтобы продолжить.'
      : 'Речь не услышана. Коснитесь «Говорить» и повторите.');
  },

  async afterPhrase(voice, text) {
    if (this.voice !== voice) return;
    const phrase = String(text || '').trim();
    if (/^(?:(?:нео|neo)[,\s:]+)?(?:стоп|хватит|пауза)[.!]*$/i.test(phrase)) {
      this.stopVoice();
      return this.setPhase('paused', 'Пауза. Коснитесь «Говорить», чтобы продолжить.');
    }
    if (/^(?:(?:нео|neo)[,\s:]+)?новый (?:разговор|диалог)[.!]*$/i.test(phrase)) {
      this.conversationId = null;
      this.retry = null;
      this.clearHistory('Начинаем новый разговор.');
      return this.nextTurn(voice);
    }
    const shown = await this.ask(phrase, voice);
    if (this.voice !== voice) return;
    if (!shown) {
      // ask() already shows the error; release the microphone.
      const phase = this.phase;
      const status = this.status;
      this.stopVoice();
      return this.setPhase(phase, status);
    }
    if (this.prefs.voice !== 'off') {
      this.holdMicrophone(voice);
      await this.speakRokid(this.answerText, voice);
    }
    if (this.voice !== voice) return;
    return this.nextTurn(voice);
  },

  // Pausing keeps the recording session alive, so the next question needs no new gesture.
  holdMicrophone(voice) {
    voice.accept = false;
    voice.expectStop = true;
    if (!voice.recorder) return;
    try {
      if (typeof voice.recorder.pause === 'function') {
        Promise.resolve(voice.recorder.pause()).catch(() => {});
        voice.held = true;
        this.report('asr_event', 'server:paused_for_speech');
        return;
      }
      const recorder = voice.recorder;
      voice.recorder = null;
      Promise.resolve(recorder.stop()).catch(() => {});
      this.report('asr_event', 'server:stopped_for_speech');
    } catch (error) {
      this.report('asr_error', 'pause:' + safeToken(error && (error.errMsg || error.message)).slice(0, 30));
    }
  },

  nextTurn(voice) {
    if (this.voice !== voice) return;
    const talking = this.prefs.talk !== 'tap' && this.screen === 'main' && this.focused !== false;
    if (talking && voice.recorder) {
      voice.expectStop = false;
      if (voice.held) {
        voice.held = false;
        try {
          Promise.resolve(voice.recorder.resume()).catch(() => {});
          voice.lastFrameAt = Date.now();
          this.report('asr_event', 'server:resumed');
        } catch (error) {
          this.report('asr_error', 'resume:' + safeToken(error && (error.errMsg || error.message)).slice(0, 30));
          this.stopVoice();
          return this.setPhase('idle', 'Коснитесь «Говорить».');
        }
      }
      voice.auto = true;
      return this.serverListen(voice, 'Слушаю следующий вопрос…');
    }
    this.stopVoice();
    this.setPhase('idle', 'Коснитесь «Говорить».');
  },

  // ---- voice: Neo server recognition ---------------------------------------

  startServer(voice, listen = true) {
    // Capture must start synchronously inside the user's gesture; wx is preloaded on show.
    let recorder = null;
    try { recorder = wx && wx.media && wx.media.getRecorderManager ? wx.media.getRecorderManager() : null; } catch (_) {}
    this.report('asr_event', 'server:recorder:' + (recorder ? 'yes' : 'no') + ':wx=' + (wx ? 'yes' : 'no'));
    if (!recorder) {
      if (!wx && !wxMissing) {
        loadWx();
        return this.voiceFailed(voice, 'wx_loading', 'Микрофон ещё готовится. Коснитесь «Говорить» ещё раз.');
      }
      return this.voiceFailed(voice, 'recorder_unavailable', 'Запись микрофона недоступна на этой прошивке. Меню → Сервис → Тест микрофона.');
    }
    this.lastVoiceApi = 'Сервер Neo (запись wx PCM)';
    voice.recorder = recorder;
    recorder.onFrameRecorded(event => this.guard('mic', () => this.serverFrame(voice, event && event.frameBuffer)));
    recorder.onError(error => this.guard('mic', () => this.voiceFailed(voice, 'recorder_error:' + safeToken(error && error.errMsg).slice(0, 40), 'Ошибка микрофона. Закройте другие записи и коснитесь.')));
    recorder.onInterruptionBegin(() => this.guard('mic', () => this.voiceFailed(voice, 'recorder_interrupted', 'Система прервала микрофон. Коснитесь, чтобы продолжить.')));
    recorder.onStop(() => this.guard('mic', () => {
      // Neo stops the recorder itself before speaking; only a surprise stop is a failure.
      if (this.voice === voice && !voice.expectStop) {
        this.voiceFailed(voice, 'recorder_stopped', 'Микрофон остановлен системой. Коснитесь, чтобы продолжить.');
      }
    }));
    recorder.onResume && recorder.onResume(() => { voice.lastFrameAt = Date.now(); });
    voice.recorderStart = recorder.start({ sampleRate: 16000, numberOfChannels: 1, format: 'pcm', frameSize: 250 });
    Promise.resolve(voice.recorderStart).then(() => this.report('asr_event', 'server:start_resolved', Date.now() - voice.startedAt), error => this.guard('mic', () => this.voiceFailed(voice, 'recorder_denied:' + safeToken(error && (error.errMsg || error.message || error.name)).slice(0, 40), 'Не удалось включить микрофон. Разрешите Microphone в Studio и обновите пакет.')));
    this.serverListen(voice, 'Включаю микрофон…', true);
    // While a failed question is re-sent, incoming audio is ignored.
    if (!listen) voice.accept = false;
  },

  serverListen(voice, status, starting) {
    if (this.voice !== voice) return;
    Object.assign(voice, { frames: [], bytes: 0, voicedMs: 0, silenceMs: 0, idleMs: 0, preRoll: [], accept: true, peak: 0 });
    if (starting) return;
    if (!voice.confirmed) this.armStartTimeout(voice);
    this.setPhase(voice.confirmed ? 'listening' : 'starting', status);
  },

  serverFrame(voice, frame) {
    if (this.voice !== voice || !frame || !frame.byteLength) return;
    this.audioFrames = (this.audioFrames || 0) + 1;
    voice.frameCount = (voice.frameCount || 0) + 1;
    voice.lastFrameAt = Date.now();
    if (!voice.confirmed) {
      voice.confirmed = true;
      this.report('mic_frames', 'first:' + frame.byteLength, Date.now() - voice.startedAt);
      if (this.phase === 'starting') this.listening(voice, 'Говорите. Пауза завершает вопрос.');
    }
    const raw = frame.slice(0, frame.byteLength - (frame.byteLength % 2));
    if (voice.speaking) return;
    // Hosts may ignore the requested 16 kHz (the web host records at 48 kHz), so the real
    // rate is measured from the data flow before any frame is interpreted.
    // The meter does not depend on the sample rate.
    const level = rmsOf(raw);
    voice.level = Math.min(1, level * 12);
    voice.peak = Math.max(voice.peak || 0, level);
    if (!voice.rate) {
      const now = Date.now();
      if (!voice.firstFrameAt) { voice.firstFrameAt = now; voice.rateBytes = 0; voice.rawFrames = []; }
      else voice.rateBytes += raw.byteLength;
      voice.rawFrames.push(raw);
      const elapsed = now - voice.firstFrameAt;
      if (elapsed < RATE_PROBE_MS || voice.rawFrames.length < 3) {
        if (elapsed > 5000) voice.rawFrames.shift();
        return;
      }
      voice.rate = snapRate(voice.rateBytes * 1000 / elapsed / 2);
      this.report('mic_frames', 'rate:' + voice.rate + ':bps=' + Math.round(voice.rateBytes * 1000 / elapsed), voice.rawFrames.length);
      const queued = voice.rawFrames;
      voice.rawFrames = null;
      for (const part of queued) {
        if (this.voice !== voice) return;
        this.serverSamples(voice, part);
      }
      return;
    }
    this.serverSamples(voice, raw);
  },

  serverSamples(voice, raw) {
    if (this.voice !== voice || !voice.accept) return;
    const bytes = to16k(raw, voice.rate);
    if (!bytes.length) return;
    const rms = rmsOf(bytes.buffer);
    const ms = bytes.length / 32;
    const voiced = rms >= (this.prefs.sensitive ? 0.005 : 0.012);
    if (!voice.frames.length && !voiced) {
      voice.preRoll.push(bytes);
      while (voice.preRoll.length > 2) voice.preRoll.shift();
      voice.idleMs += ms;
      if (voice.idleMs >= IDLE_PAUSE_MS) this.voiceSilent(voice);
      return;
    }
    if (!voice.frames.length) {
      voice.frames = voice.preRoll;
      voice.preRoll = [];
      voice.bytes = voice.frames.reduce((size, part) => size + part.length, 0);
    }
    const part = bytes.subarray(0, Math.max(0, 640000 - voice.bytes));
    voice.frames.push(part);
    voice.bytes += part.length;
    if (voiced) { voice.voicedMs += ms; voice.silenceMs = 0; } else voice.silenceMs += ms;
    if (voice.silenceMs >= SILENCE_MS || voice.bytes >= 640000) {
      if (voice.voicedMs >= 250) return this.serverSubmit(voice);
      // A click or short noise must not create a paid request.
      this.serverListen(voice, 'Слушаю…');
    }
  },

  wav(frames, size) {
    const result = new Uint8Array(44 + size);
    const view = new DataView(result.buffer);
    const ascii = (offset, text) => { for (let i = 0; i < text.length; i++) result[offset + i] = text.charCodeAt(i); };
    ascii(0, 'RIFF'); view.setUint32(4, 36 + size, true); ascii(8, 'WAVE');
    ascii(12, 'fmt '); view.setUint32(16, 16, true); view.setUint16(20, 1, true);
    view.setUint16(22, 1, true); view.setUint32(24, 16000, true);
    view.setUint32(28, 32000, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
    ascii(36, 'data'); view.setUint32(40, size, true);
    let offset = 44;
    for (const frame of frames) { result.set(frame, offset); offset += frame.length; }
    return result.buffer;
  },

  // Reads Server-Sent Events from /v1/ask: the transcript first, then the answer in parts.
  async streamAsk(voice, audio) {
    const body = JSON.stringify({
      user_id: this.connection.userId, device_id: this.connection.deviceId,
      wav_base64: base64(audio),
      ...(this.conversationId ? { session_id: this.conversationId } : {}),
      client_message_id: (this.retry && this.retry.id) || newId()
    });
    const controller = typeof AbortController === 'function' ? new AbortController() : null;
    voice.abort = controller;
    const stop = () => { if (controller) { try { controller.abort(); } catch (_) {} } };
    let idleTimer = setTimeout(stop, STREAM_IDLE_MS);
    const keepAlive = () => {
      stopTimer(idleTimer);
      idleTimer = setTimeout(stop, STREAM_IDLE_MS);
    };
    try {
      const response = await fetch(NEO_BASE_URL + '/v1/ask', {
        method: 'POST', timeout: REQUEST_TIMEOUT_MS,
        headers: { 'Accept': 'text/event-stream', 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + this.connection.token },
        ...(controller ? { signal: controller.signal } : {}),
        body
      });
      if (!response.ok) {
        let data = null;
        try { data = await response.json(); } catch (_) {}
        return { status: response.status, error: (data && data.error) || {} };
      }
      const events = [];
      const handle = event => { keepAlive(); events.push(event); this.onAskEvent(voice, event); };
      const reader = response.body && typeof response.body.getReader === 'function' ? response.body.getReader() : null;
      if (reader) {
        const decoder = typeof TextDecoder === 'function' ? new TextDecoder() : null;
        let buffer = '';
        for (;;) {
          const chunk = await reader.read();
          if (chunk.done) break;
          buffer += decoder ? decoder.decode(chunk.value, { stream: true }) : String(chunk.value);
          let split = buffer.indexOf('\n\n');
          while (split >= 0) {
            const event = parseEvent(buffer.slice(0, split));
            buffer = buffer.slice(split + 2);
            if (event) handle(event);
            split = buffer.indexOf('\n\n');
          }
          if (this.voice !== voice) break;
        }
      } else {
        // Hosts without streaming reads still get every event, just at the end.
        this.report('asr_event', 'stream:buffered');
        for (const block of String(await response.text()).split('\n\n')) {
          const event = parseEvent(block);
          if (event) handle(event);
        }
      }
      const last = events[events.length - 1];
      if (!last || (last.name !== 'done' && last.name !== 'error')) return { status: 0, error: { code: 'stream_cut' } };
      return last.name === 'done' ? { status: 200, done: last.data } : { status: 502, error: last.data };
    } finally {
      stopTimer(idleTimer);
      voice.abort = null;
    }
  },

  onAskEvent(voice, event) {
    if (this.voice !== voice) return;
    if (event.name === 'transcript' && typeof event.data.text === 'string' && event.data.text.trim()) {
      this.showTranscript(event.data.text.trim());
      this.setPhase('thinking', DEEP_REQUEST.test(event.data.text) ? 'Думаю глубже…' : 'Neo думает…');
      return;
    }
    if (event.name === 'delta' && typeof event.data.text === 'string') {
      voice.streamed = (voice.streamed || '') + event.data.text;
      // Redraw at most five times a second while the answer is written.
      const now = Date.now();
      if (now - (voice.drawnAt || 0) >= 200) {
        voice.drawnAt = now;
        this.showStreaming(voice.streamed);
      }
    }
  },

  async serverSubmit(voice) {
    voice.accept = false;
    this.report('mic_frames', 'phrase:voiced=' + voice.voicedMs + ':peak=' + Math.round((voice.peak || 0) * 10000), voice.bytes);
    const joined = new Uint8Array(voice.bytes);
    let offset = 0;
    for (const part of voice.frames) { joined.set(part, offset); offset += part.length; }
    const speech = trimSilence(joined, this.prefs.sensitive ? 0.005 : 0.012);
    this.report('mic_frames', 'trim:' + joined.length + '>' + speech.length, voice.voicedMs);
    const audio = this.wav([speech], speech.length);
    voice.frames = [];
    voice.streamed = '';
    this.setPhase('recognizing', 'Распознаю…');
    const started = Date.now();
    let result;
    try {
      result = await this.streamAsk(voice, audio);
    } catch (error) {
      this.report('transcribe_error', error && error.code || 'network');
      return this.voiceFailed(voice, 'ask_' + (error && error.code || 'network'), 'Не удалось передать голос. Проверьте связь и коснитесь.');
    }
    if (this.voice !== voice) return;
    if (result.status === 200 && result.done) {
      this.report('asr_result', 'ask:ok', Date.now() - started);
      return this.finishAnswer(voice, result.done);
    }
    const code = result.error && result.error.code;
    this.report('transcribe_error', code || 'http', result.status);
    if (code === 'invalid_transcription' || code === 'invalid_audio') {
      return this.serverListen(voice, 'Не расслышал. Повторите вопрос.');
    }
    if (result.status === 401 || result.status === 403) {
      if (await this.connect({ silent: true })) return this.serverListen(voice, 'Связь восстановлена. Повторите вопрос.');
      this.connection = null;
      this.stopVoice();
      return this.setPhase('offline', 'Доступ Neo истёк. Коснитесь, чтобы переподключиться.');
    }
    const messages = {
      429: code === 'budget_exceeded' ? 'Достигнут месячный бюджет Neo.' : 'Лимит запросов. Подождите минуту.',
      409: 'Neo ещё отвечает на прошлый вопрос. Коснитесь через секунду.'
    };
    return this.voiceFailed(voice, 'ask ' + result.status + ' ' + (code || ''),
      messages[result.status] || (result.error && result.error.message) || 'Neo не ответил. Коснитесь, чтобы повторить.');
  },

  async finishAnswer(voice, done) {
    const answer = typeof done.message === 'string' ? done.message.trim() : '';
    if (!answer) return this.voiceFailed(voice, 'empty_answer', 'Neo вернул пустой ответ. Коснитесь, чтобы повторить.');
    if (typeof done.session_id === 'string' && UUID.test(done.session_id)) this.conversationId = done.session_id;
    this.retry = null;
    const sources = Array.isArray(done.sources)
      ? done.sources.filter(source => source && typeof source.url === 'string' && /^https?:\/\//.test(source.url)).slice(0, 5) : [];
    const deep = typeof done.model === 'string' && done.model && done.model !== 'gpt-5.6-luna';
    const question = this.pending;
    this.alert = done.budget && done.budget.warning ? 'Бюджет: использовано более 80%.' : '';
    this.addTurn(question, answer, sources, deep);
    if (this.prefs.voice !== 'off') {
      // The glasses mute playback while the microphone records, so capture pauses for the reply.
      this.holdMicrophone(voice);
      await this.speakRokid(answer, voice);
    }
    if (this.voice !== voice) return;
    return this.nextTurn(voice);
  },

  // ---- voice output ----------------------------------------------------------

  waitPlayback(voice, estimateMs, isDone) {
    return new Promise(resolve => {
      const started = Date.now();
      const poll = () => {
        if (voice && this.voice !== voice) return resolve();
        let done = false;
        try { done = isDone(Date.now() - started); } catch (_) { done = true; }
        if (done || Date.now() - started > estimateMs + 5000) return resolve();
        const id = setTimeout(poll, 300);
        if (voice) voice.playTimer = id;
      };
      poll();
    });
  },

  // speechSynthesis.speak() is the documented path for plain replies; on AIUI 0.17 the
  // synthesize() + SpeechAudioPlayer path started tasks that never finished. speak() has no end
  // event, so Neo waits for an estimate of the spoken length.
  async speakRokid(text, voice) {
    const phrase = speechText(text);
    const chars = Array.from(phrase).length;
    const tts = (detail, value) => this.report('tts_event', 'rokid:' + detail, value);
    if (!phrase.trim()) return;
    if (typeof speechSynthesis === 'undefined' || typeof speechSynthesis.speak !== 'function'
        || typeof SpeechSynthesisUtterance !== 'function') {
      tts('unavailable');
      if (voice && this.voice === voice) this.setStatus('Голос Rokid недоступен на этой прошивке; ответ на экране.');
      return;
    }
    if (voice) {
      voice.speaking = true;
      this.setPhase('speaking', 'Neo отвечает голосом. Коснитесь, чтобы остановить.');
    }
    const estimate = 400 + chars * SPEECH_MS_PER_CHAR;
    try {
      const utterance = new SpeechSynthesisUtterance(phrase);
      utterance.lang = 'ru-RU';
      speechSynthesis.speak(utterance, 'immediate');
      tts('speak:chars=' + chars, estimate);
      await this.waitPlayback(voice, estimate, elapsed => elapsed >= estimate);
      if (voice && this.voice === voice) {
        voice.speaking = false;
        // Let the speaker fall silent before listening again.
        await this.waitPlayback(voice, 0, elapsed => elapsed >= 600);
      }
    } catch (error) {
      if (voice) voice.speaking = false;
      this.lastError = 'tts rokid: ' + String(error && error.message || error).slice(0, 60);
      this.report('tts_error', 'rokid:' + String(error && (error.name || error.message) || error).slice(0, 40));
      if (voice && this.voice === voice) this.setStatus('Голос Rokid не сработал; ответ на экране.');
    }
  }

};
</script>

<page>
  <view class="page">
    <view ink:if="{{ screen !== 'menu' }}" class="feed" bindtap="tapScreen">
      <text ink:for="{{ bodyLines }}" ink:key="id" class="{{ item.cls }}">{{ item.text }}</text>
      <view ink:if="{{ thumb }}" class="track"><view class="thumb" style="{{ thumb }}"></view></view>
    </view>

    <view ink:if="{{ screen === 'menu' }}" class="feed">
      <text class="section">{{ menuTitle }}</text>
      <view ink:for="{{ menuRows }}" ink:key="id" class="{{ item.cls }}" data-index="{{ item.index }}" bindtap="tapMenu">
        <text class="row-label">{{ item.label }}</text>
        <text class="row-value">{{ item.value }}</text>
      </view>
    </view>

    <view ink:if="{{ statusLines.length }}" class="status-box">
      <text ink:for="{{ statusLines }}" ink:key="id" class="status">{{ item.text }}</text>
    </view>

    <view class="bar">
      <view class="face">
        <view class="halo" style="{{ faceHalo }}"></view>
        <view class="eyes">
          <view class="eye" style="{{ faceEye }}"></view>
          <view class="eye" style="{{ faceEye }}"></view>
        </view>
        <view class="mouth" style="{{ faceMouth }}"></view>
      </view>
      <text class="state">{{ stateWord }}</text>
      <view ink:for="{{ actions }}" ink:key="id" class="{{ item.cls }}" data-index="{{ index }}" bindtap="tapAction">
        <text class="action-label">{{ item.label }}</text>
      </view>
    </view>
    <text class="hint">{{ hint }}</text>
  </view>
</page>

<style>
.page {
  display: flex;
  flex-direction: column;
  width: 100%;
  height: 100%;
  padding: 12px 16px;
  box-sizing: border-box;
  background-color: #000000;
}
.feed { position: relative; display: flex; flex-direction: column; flex: 1; height: 0; padding-right: 8px; }
.track {
  position: absolute;
  right: 0;
  top: 0;
  width: 3px;
  height: 100%;
  background-color: rgba(64,255,94,0.16);
  border-radius: 2px;
}
.thumb {
  position: absolute;
  right: 0;
  width: 3px;
  background-color: rgba(64,255,94,0.72);
  border-radius: 2px;
  transition: top 140ms, height 140ms;
}
.line { color: #40ff5e; font-size: 16px; line-height: 23px; }
.small { color: rgba(64,255,94,0.55); font-size: 12px; line-height: 17px; }
.gap { font-size: 4px; line-height: 8px; }
.section { color: rgba(64,255,94,0.48); font-size: 11px; line-height: 16px; }
.mono { color: rgba(64,255,94,0.72); font-family: monospace; font-size: 11px; line-height: 16px; }
.status-box { flex-shrink: 0; margin-bottom: 2px; }
.status { color: rgba(64,255,94,0.72); font-size: 12px; line-height: 16px; }
.row {
  display: flex;
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
  height: 36px;
  padding: 0 10px;
  margin-top: 4px;
  border: 1px solid rgba(64,255,94,0.24);
  border-radius: 6px;
}
.row-on { background-color: rgba(64,255,94,0.12); border: 2px solid #40ff5e; }
.row-label { color: rgba(64,255,94,0.9); font-size: 14px; }
.row-value { color: #40ff5e; font-size: 13px; font-weight: 500; }
.bar {
  display: flex;
  flex-direction: row;
  align-items: center;
  gap: 8px;
  height: 36px;
  flex-shrink: 0;
}
.face {
  position: relative;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 3px;
  width: 32px;
  height: 32px;
  border: 1px solid rgba(64,255,94,0.72);
  border-radius: 17px;
  flex-shrink: 0;
}
.halo {
  position: absolute;
  left: -4px;
  top: -4px;
  width: 38px;
  height: 38px;
  border: 1px solid #40ff5e;
  border-radius: 20px;
  transition: opacity 200ms;
}
.eyes { display: flex; flex-direction: row; align-items: center; gap: 4px; height: 7px; }
.eye { width: 4px; height: 6px; background-color: #40ff5e; border-radius: 2px; transition: height 120ms, margin 200ms; }
.mouth { width: 12px; height: 2px; background-color: #40ff5e; border-radius: 1px; transition: height 200ms, width 200ms; }
.state { color: rgba(64,255,94,0.6); font-size: 12px; line-height: 16px; flex: 1; }
.action {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 104px;
  height: 34px;
  border: 1px solid rgba(64,255,94,0.48);
  border-radius: 4px;
  flex-shrink: 0;
}
.action-on { background-color: rgba(64,255,94,0.12); border: 2px solid #40ff5e; }
.press { background-color: rgba(64,255,94,0.36); }
.action-label { color: #40ff5e; font-size: 14px; font-weight: 500; }
.hint {
  color: rgba(64,255,94,0.4);
  font-size: 11px;
  line-height: 15px;
  margin-top: 2px;
  flex-shrink: 0;
}
</style>
