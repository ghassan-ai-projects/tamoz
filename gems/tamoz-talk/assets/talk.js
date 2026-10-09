import { Vad } from './vad.mjs';
import { encodeWav, seconds } from './wav.mjs';
import { newUpdateId, sendUntilSettled } from './retry.mjs';
import { pairHeard, heardText, settleOldest, recordSend } from './pairing.mjs';
import { render } from './render.mjs';
import { HALF_DUPLEX_TAIL_MS, PTT_TAIL_MS, capturing, holdsPtt, userSpeaking } from './gate.mjs';

const $ = (id) => document.getElementById(id);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const trace = [];
window.talkTrace = trace;
const mark = (name, detail = {}) => {
  trace.push({ name, at: performance.now(), ...detail });
  if (trace.length > 2000) trace.shift();
};

const PTT_MAX_MS = 30000;
const WORKING_TONE_MS = 30000;
const POLL_TIMEOUT_MS = 35000;
const SPEECH_TIMEOUT_MS = 20000;
const CATCH_UP_SPOKEN = 1;

const state = {
  token: readToken(),
  epoch: '',
  after: 0,
  live: false,
  dead: false,
  started: false,
  voice: false,
  mode: stored('tamoz.talk.mode', 'hands-free'),
  speech: stored('tamoz.talk.speech', '1') === '1',
  fullDuplex: false,
  bubbles: [],
  messages: new Map(),
  queue: [],
  generation: 0,
  fetching: null,
  playing: null,
  url: null,
  tailUntil: 0,
  working: null,
  pressed: false,
  pressToken: 0,
  pttFrames: [],
  pttUntil: 0,
  context: null,
  stream: null,
  workletReady: false,
  vad: new Vad({ hangoverMs: Number(stored('tamoz.talk.hangover', '1200')) }),
  lastTone: 0,
  pollAbort: null,
  restartPoll: false,
  reconnected: false,
  seen: new Set(),
  micStarting: null,
  nodes: [],
};

function stored(key, fallback) {
  try {
    return localStorage.getItem(key) ?? fallback;
  } catch {
    return fallback;
  }
}

function store(key, value) {
  try {
    localStorage.setItem(key, value);
  } catch {
    // A private window keeps settings for this visit only.
  }
}

function readToken() {
  const fragment = new URLSearchParams(location.hash.slice(1));
  const token = fragment.get('token');
  if (token) {
    store('tamoz.talk.token', token);
    history.replaceState(null, '', location.pathname + location.search);
    return token;
  }
  return stored('tamoz.talk.token', '');
}

function api(path, options = {}) {
  return fetch(path, {
    cache: 'no-store',
    ...options,
    headers: { Authorization: `Bearer ${state.token}`, ...(options.headers || {}) },
  });
}

function withTimeout(ms) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  return { signal: controller.signal, controller, done: () => clearTimeout(timer) };
}

// ---- conversation view ----

function scrollDown() {
  const main = $('conversation');
  main.scrollTop = main.scrollHeight;
}

function bubble({ mine, text, voice = false, command = false }) {
  const node = document.createElement('div');
  node.className = `bubble${mine ? ' mine' : ''}`;
  const body = document.createElement('div');
  render(document, body, text);
  const meta = document.createElement('div');
  meta.className = 'meta';
  const label = document.createElement('span');
  meta.appendChild(label);
  node.append(body, meta);
  $('conversation').appendChild(node);
  scrollDown();
  const entry = { node, body, meta, label, voice, command, admitted: false, mine };
  if (mine) state.bubbles.push(entry);
  return entry;
}

function setMeta(entry, text) {
  entry.label.textContent = text;
}

function addReplay(entry, messageId) {
  if (entry.replay) return;
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'replay';
  button.textContent = 'Replay';
  button.setAttribute('aria-label', 'Replay this reply');
  button.addEventListener('click', () => speak(messageId, { force: true }));
  entry.meta.appendChild(button);
  entry.replay = button;
}

function apply(event) {
  if (state.seen.has(event.seq)) return undefined;
  state.seen.add(event.seq);
  if (state.seen.size > 4000) state.seen.delete(state.seen.values().next().value);
  if (event.type === 'ack') return toast(event.text);
  if (event.type === 'buttons_cleared') return resolveCard(event.message_id);
  if (event.type !== 'message') return undefined;
  if (event.kind === 'control' && heardText(event.text) !== null) return heard(event);
  if (event.replaces && state.messages.has(event.replaces)) return replace(event);
  if (state.messages.has(event.message_id)) return undefined;
  return message(event);
}

function heard(event) {
  const entry = pairHeard(state.bubbles, event.text);
  mark('heard', { message_id: event.message_id });
  if (entry) {
    setMeta(entry, `🎙 Heard: «${entry.heard}»`);
    return;
  }
  const note = document.createElement('div');
  note.className = 'notice';
  note.textContent = event.text;
  $('conversation').appendChild(note);
  scrollDown();
}

function message(event) {
  const entry = bubble({ mine: false, text: event.text });
  state.messages.set(event.message_id, { entry, event });
  const settled = settleOldest(state.bubbles, event.kind, event.part_index || 0);
  if (settled?.voice && settled.heard === null) setMeta(settled, '🎙 not transcribed');
  if (event.kind === 'approval_request' && event.reference) card(entry, event);
  if (event.spoken) addReplay(entry, event.message_id);
  if (state.live) {
    mark('answer', { message_id: event.message_id, kind: event.kind });
    if (event.spoken) maybeSpeak(event.message_id);
  }
}

function replace(event) {
  const known = state.messages.get(event.replaces);
  render(document, known.entry.body, event.text);
  state.messages.set(event.replaces, { entry: known.entry, event: { ...event, message_id: event.replaces } });
  if (event.spoken) {
    addReplay(known.entry, event.replaces);
    if (state.live) maybeSpeak(event.replaces);
  }
}

function card(entry, event) {
  entry.node.classList.add('card');
  entry.node.setAttribute('role', 'alertdialog');
  entry.node.setAttribute('aria-label', 'Approval needed');
  entry.node.tabIndex = -1;
  const actions = document.createElement('div');
  actions.className = 'actions';
  const status = document.createElement('span');
  status.className = 'card-status';
  for (const action of event.actions || ['deny']) {
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = action === 'approve' ? 'Approve' : 'Deny';
    button.className = action === 'approve' ? 'primary' : 'danger';
    button.addEventListener('click', () => decide(action, event, entry));
    actions.appendChild(button);
  }
  actions.appendChild(status);
  entry.node.appendChild(actions);
  entry.actions = actions;
  entry.cardStatus = status;
  const typing = document.activeElement && document.activeElement.closest('textarea, input, select');
  if (state.live && state.started && !typing) entry.node.focus();
}

function resolveCard(messageId) {
  const known = state.messages.get(messageId);
  if (!known?.entry.actions) return;
  known.entry.actions.querySelectorAll('button').forEach((b) => { b.disabled = true; });
  known.entry.node.classList.add('resolved');
}

let toastTimer = null;
function toast(text) {
  const node = $('toast');
  node.hidden = false;
  clearTimeout(toastTimer);
  setTimeout(() => { node.textContent = text; }, 30);
  toastTimer = setTimeout(() => { node.hidden = true; node.textContent = ''; }, 4000);
}

// ---- state line ----

function setState(text) {
  if ($('state-label').textContent !== text) $('state-label').textContent = text;
  $('state-detail').textContent = '';
}

const AUDIO_PAUSED = 'Audio paused — tap Talk to resume.';
const SCREEN_PAUSED = 'paused: the microphone stops when the screen locks';

function clearHint(text) {
  if ($('hint').textContent === text) setHint('');
}

function setHint(text) {
  $('hint').hidden = !text;
  $('hint').textContent = text || '';
}

function setWorking(working) {
  const was = state.working;
  state.working = working;
  if (!working && was) {
    state.bubbles.filter((b) => b.queued).forEach((b) => {
      b.queued = false;
      if (b.heard === undefined) setMeta(b, b.voice ? '🎙 sent' : 'sent');
    });
  }
  if (working && !state.playing) {
    const seconds = Math.max(0, Math.round((Date.parse(working.last_pulse) - Date.parse(working.since)) / 1000));
    setState('Thinking');
    $('state-detail').textContent = ` ${seconds} s`;
    if (state.voice && Date.now() - state.lastTone > WORKING_TONE_MS) {
      state.lastTone = Date.now();
      tone(440, 0.04);
    }
  } else if (!working && !state.playing && state.started) {
    setState(listeningLabel());
  }
}

function listeningLabel() {
  if (!state.voice || state.mode === 'muted') return 'Microphone off — type below';
  if (state.mode === 'push-to-talk') return 'Hold Talk to speak';
  return 'Listening';
}

function setConnected(on) {
  $('connection').classList.toggle('on', on);
  $('connection').title = on ? 'Connected' : 'Reconnecting…';
  $('connection').setAttribute('aria-label', $('connection').title);
  if (!on && state.started) setState('Reconnecting…');
}

function stopDead(text) {
  state.dead = true;
  $('connection').classList.remove('on');
  setState(text);
  $('start-note').textContent = text;
  $('start-button').disabled = true;
  $('text-only').disabled = true;
}

// ---- events ----

async function poll() {
  let backoff = 1000;
  while (!state.dead) {
    state.restartPoll = false;
    const token = state.token;
    const timer = withTimeout(POLL_TIMEOUT_MS);
    state.pollAbort = timer.controller;
    try {
      const speech = speaking() ? 1 : 0;
      const response = await api(`/v1/events?after=${state.after}&epoch=${state.epoch}&timeout=25&speech=${speech}`,
        { signal: timer.signal });
      if (response.status === 401) {
        if (state.token !== token) continue;
        stopDead('This link is not valid any more. Open the link printed by `tamoz talk start` on this device.');
        return;
      }
      if (!response.ok) throw new Error(String(response.status));
      receive(await response.json());
      backoff = 1000;
      setConnected(true);
    } catch {
      if (state.restartPoll) {
        state.restartPoll = false;
        continue;
      }
      setConnected(false);
      state.reconnected = true;
      await napUnlessWoken(backoff + Math.random() * 500);
      backoff = Math.min(backoff * 2, 15000);
    } finally {
      timer.done();
      if (state.pollAbort === timer.controller) state.pollAbort = null;
    }
  }
}

function receive(page) {
  const main = $('conversation');
  if (page.reset) main.setAttribute('aria-busy', 'true');
  state.live = state.live && !page.reset;
  state.epoch = page.epoch;
  state.after = page.next;
  const queued = state.queue.length;
  for (const event of page.events) {
    try {
      apply(event);
    } catch (error) {
      console.error('tamoz: could not show an event', error);
    }
  }
  const added = state.queue.length - queued;
  if (state.reconnected && added > CATCH_UP_SPOKEN) state.queue.splice(queued, added - CATCH_UP_SPOKEN);
  state.reconnected = false;
  state.live = true;
  main.setAttribute('aria-busy', 'false');
  setWorking(page.working);
}

// ---- sending ----

async function post(path, body, headers, onRetry = () => {}) {
  const id = newUpdateId();
  const url = path.includes('?') ? `${path}&update_id=${id}` : path;
  const payload = typeof body === 'function' ? body(id) : body;
  return sendUntilSettled(() => api(url, { method: 'POST', body: payload, headers }), {
    sleep,
    onRetry: (status, attempt) => {
      onRetry(status, attempt);
      if (status === 0) setConnected(false);
    },
  });
}

async function sendText(text) {
  const command = text.startsWith('/');
  const entry = bubble({ mine: true, text, command });
  setMeta(entry, 'sending');
  const result = await post('/v1/messages', (id) => JSON.stringify({ update_id: id, text }),
    { 'Content-Type': 'application/json' }, (_status, attempt) => { if (attempt >= 2) setMeta(entry, 'retrying…'); });
  settle(entry, result);
}

async function sendUtterance(samples) {
  mark('segment_end');
  tone(880, 0.05);
  const entry = bubble({ mine: true, text: '', voice: true });
  setMeta(entry, `🎙 ${seconds(samples).toFixed(1)} s · sending`);
  mark('post');
  const result = await post('/v1/utterances?', encodeWav(samples), { 'Content-Type': 'audio/wav' },
    (_status, attempt) => { if (attempt >= 2) setMeta(entry, '🎙 retrying…'); });
  settle(entry, result);
}

function settle(entry, result) {
  if (!recordSend(entry, result.outcome)) {
    setMeta(entry, result.status === 413 ? 'too long to send' : 'not sent');
    return;
  }
  mark('admitted');
  if (entry.command) {
    setMeta(entry, 'done');
    return;
  }
  if (entry.heard !== undefined) return;
  entry.queued = Boolean(state.working);
  const label = entry.queued ? 'queued — Tamoz will hear this after the current request' : 'sent';
  setMeta(entry, entry.voice ? `🎙 ${label}` : label);
}

async function decide(action, event, entry) {
  const buttons = entry.actions.querySelectorAll('button');
  buttons.forEach((b) => { b.disabled = true; });
  entry.cardStatus.textContent = 'Sending…';
  const result = await post('/v1/decisions', (id) => JSON.stringify({
    update_id: id, action, reference: event.reference, message_id: event.message_id,
  }), { 'Content-Type': 'application/json' });
  if (result.outcome === 'admitted') {
    entry.cardStatus.textContent = action === 'approve' ? 'Approval sent' : 'Denial sent';
  } else {
    entry.cardStatus.textContent = 'Could not send — try again';
    buttons.forEach((b) => { b.disabled = false; });
  }
  $('talk').focus();
}

// ---- speech out ----

function speaking() {
  return state.speech && state.voice;
}

function maybeSpeak(messageId) {
  if (speaking() && state.started) speak(messageId);
}

function speak(messageId, { force = false } = {}) {
  if (!state.voice) return;
  if (!force && state.queue.includes(messageId)) return;
  state.queue.push(messageId);
  resumeQueue();
}



async function playNext() {
  const messageId = state.queue.shift();
  if (messageId === undefined) return;
  const generation = state.generation;
  state.fetching = messageId;
  mark('speech_request', { message_id: messageId });
  const timer = withTimeout(SPEECH_TIMEOUT_MS);
  state.speechAbort = timer.controller;
  try {
    const response = await api(`/v1/speech/${messageId}`, { signal: timer.signal });
    if (!response.ok) throw new Error(String(response.status));
    const blob = await response.blob();
    if (generation !== state.generation) return;
    if (userSpeaking(state, performance.now()) && !state.fullDuplex) {
      state.queue.unshift(messageId);
      state.fetching = null;
      return;
    }
    state.url = URL.createObjectURL(blob);
    const player = $('player');
    player.src = state.url;
    player.oncanplay = () => mark('can_play', { message_id: messageId });
    player.onplaying = () => {
      if (generation !== state.generation) return;
      state.playing = messageId;
      mark('playing', { message_id: messageId });
      setState('Speaking — tap Talk or press Space to interrupt');
    };
    player.onended = () => { if (generation === state.generation) finished(); };
    player.onerror = () => { if (generation === state.generation) finished(); };
    await player.play();
  } catch (error) {
    if (generation !== state.generation) return;
    const known = state.messages.get(messageId);
    if (known) setMeta(known.entry, error?.name === 'NotAllowedError' ? 'tap Replay to hear it' : 'voice unavailable');
    finished();
  } finally {
    timer.done();
    if (generation === state.generation && state.fetching === messageId) state.fetching = null;
  }
}

function finished() {
  if (state.url) URL.revokeObjectURL(state.url);
  state.url = null;
  state.playing = null;
  state.fetching = null;
  state.tailUntil = performance.now() + HALF_DUPLEX_TAIL_MS;
  setWorking(state.working);
  resumeQueue();
}

function resumeQueue() {
  if (state.queue.length && !state.fetching && !state.playing && !userSpeaking(state, performance.now())) playNext();
}

function stopPlayback() {
  state.generation += 1;
  state.speechAbort?.abort();
  const player = $('player');
  player.pause();
  player.removeAttribute('src');
  if (state.url) URL.revokeObjectURL(state.url);
  state.url = null;
  state.playing = null;
  state.fetching = null;
}

// The user started talking before a reply began: let them finish, then play it.
function yieldToSpeech() {
  const pending = state.playing || state.fetching;
  if (!pending || state.fullDuplex) return;
  stopPlayback();
  state.queue.unshift(pending);
}

function bargeIn() {
  if (!state.playing && !state.fetching) return false;
  stopPlayback();
  mark('barge_in_stop');
  state.queue = [];
  state.tailUntil = 0;
  setWorking(state.working);
  return true;
}

function tone(frequency, length) {
  const context = state.context;
  if (!context || context.state !== 'running') return;
  const oscillator = context.createOscillator();
  const gain = context.createGain();
  gain.gain.value = 0.04;
  oscillator.frequency.value = frequency;
  oscillator.connect(gain).connect(context.destination);
  oscillator.start();
  oscillator.stop(context.currentTime + length);
}

// ---- microphone ----

function onFrame(frame) {
  if (state.mode === 'push-to-talk') {
    if (holdsPtt(state, performance.now())) state.pttFrames.push(frame);
    return;
  }
  if (!capturing(state, performance.now())) return;
  const event = state.vad.push(frame);
  if (!event) return;
  if (event.type === 'start') {
    if (state.fullDuplex) bargeIn();
    else yieldToSpeech();
    setState('Listening…');
    if (state.working) setHint('Press Stop to interrupt; speech is queued.');
    return;
  }
  if (event.type === 'closing' || event.type === 'resume') {
    $('sending').hidden = event.type === 'resume';
    return;
  }
  $('sending').hidden = true;
  setHint('');
  if (event.type === 'end') sendUtterance(event.samples);
  else if (event.reason === 'short' || event.reason === 'quiet') caught();
  setWorking(state.working);
  resumeQueue();
}

function caught() {
  setHint("Didn't catch that.");
  setTimeout(() => { if ($('hint').textContent === "Didn't catch that.") setHint(''); }, 2500);
}

function startMicrophone() {
  state.micStarting ||= openMicrophone().finally(() => { state.micStarting = null; });
  return state.micStarting;
}

async function openMicrophone() {
  if (!window.isSecureContext || !navigator.mediaDevices?.getUserMedia) {
    setHint('The microphone needs HTTPS: open this page through `tailscale serve`, or on this computer. Typing works.');
    return false;
  }
  let stream = null;
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 },
    });
    const track = stream.getAudioTracks()[0];
    const cancelsEcho = track?.getSettings?.().echoCancellation === true;
    $('headphones-row').hidden = !cancelsEcho;
    if (!cancelsEcho) {
      state.fullDuplex = false;
      $('headphones').checked = false;
    }
    track?.addEventListener('ended', () => { if (state.stream === stream) micLost(); });
    if (!state.workletReady) {
      await state.context.audioWorklet.addModule('/capture-worklet.js');
      state.workletReady = true;
    }
    state.nodes.forEach((old) => old.disconnect());
    const node = new AudioWorkletNode(state.context, 'capture');
    state.nodes = [node];
    node.port.onmessage = (message) => onFrame(message.data);
    const silent = state.context.createGain();
    silent.gain.value = 0;
    state.context.createMediaStreamSource(stream).connect(node).connect(silent).connect(state.context.destination);
    state.stream = stream;
    setTracks(state.mode !== 'muted');
    setHint('');
    return true;
  } catch {
    stream?.getTracks().forEach((t) => t.stop());
    setHint('The microphone is not available. Allow it in the browser, or type.');
    return false;
  }
}

function micLost() {
  state.stream = null;
  state.vad.reset();
  $('sending').hidden = true;
  setHint('Microphone paused — tap Talk to resume.');
  resumeQueue();
}

function setTracks(enabled) {
  state.stream?.getAudioTracks().forEach((track) => { track.enabled = enabled; });
}

async function ensureMicrophone({ retry = false } = {}) {
  if (state.context && state.context.state !== 'running') await state.context.resume().catch(() => {});
  const live = state.stream?.getAudioTracks().some((t) => t.readyState === 'live');
  if (live || !state.voice || (state.mode === 'muted' && !retry)) return;
  if (await startMicrophone()) {
    if (state.mode === 'muted') state.mode = 'hands-free';
    $('mode').value = state.mode;
    setState(listeningLabel());
  }
}

// Everything that needs the tap's user activation runs before the first await.
function start({ voice }) {
  $('start').hidden = true;
  ['header', 'conversation', 'footer'].forEach((id) => $(id).removeAttribute('inert'));
  state.started = true;
  state.voice = voice;
  document.body.classList.toggle('text-only', !voice);
  if (voice) {
    state.context = new AudioContext();
    state.context.onstatechange = () => {
      if (state.context.state === 'running') clearHint(AUDIO_PAUSED);
      else if (!document.hidden) setHint(AUDIO_PAUSED);
    };
    const resumed = state.context.resume();
    const player = $('player');
    player.src = URL.createObjectURL(new Blob([encodeWav(new Float32Array(160))], { type: 'audio/wav' }));
    const unlocked = player.play();
    navigator.wakeLock?.request('screen').catch(() => {});
    Promise.allSettled([resumed, unlocked]).then(async () => {
      if (state.mode !== 'muted' && !(await startMicrophone())) {
        state.mode = 'muted';
        $('mode').value = 'muted';
      }
      setState(listeningLabel());
    });
  } else {
    state.mode = 'muted';
    $('mode').value = 'muted';
  }
  $('talk').focus();
  setState(listeningLabel());
}

// ---- controls ----

function releasePtt(cancel = false) {
  if (!state.pressed) return;
  state.pressed = false;
  const token = state.pressToken;
  state.pttUntil = cancel ? 0 : performance.now() + PTT_TAIL_MS;
  $('talk').setAttribute('aria-pressed', 'false');
  setTimeout(() => {
    if (token !== state.pressToken) return;
    flushPtt(cancel);
    setState(listeningLabel());
  }, cancel ? 0 : PTT_TAIL_MS);
}

function flushPtt(cancel = false) {
  const frames = state.pttFrames.splice(0);
  state.pttUntil = 0;
  const total = frames.reduce((n, f) => n + f.length, 0);
  if (!cancel && total >= 16000 * 0.2) {
    const joined = new Float32Array(total);
    let offset = 0;
    frames.forEach((f) => { joined.set(f, offset); offset += f.length; });
    sendUtterance(joined);
  }
  resumeQueue();
}

function pressTalk() {
  if (bargeIn() && state.mode !== 'push-to-talk') return;
  if (state.voice) ensureMicrophone({ retry: true });
  if (state.mode !== 'push-to-talk') return;
  if (!state.pressed && state.pttFrames.length) flushPtt();
  state.pressed = true;
  state.pressToken += 1;
  const token = state.pressToken;
  state.pttFrames = [];
  $('talk').setAttribute('aria-pressed', 'true');
  setState('Listening…');
  setTimeout(() => { if (state.pressed && token === state.pressToken) releasePtt(); }, PTT_MAX_MS);
}

function talkKeyTarget(event) {
  return event.target === document.body || event.target === $('talk');
}

function bindControls() {
  $('start-button').addEventListener('click', () => start({ voice: true }));
  $('text-only').addEventListener('click', () => start({ voice: false }));
  $('stop').addEventListener('click', () => { bargeIn(); sendText('/cancel'); });
  $('status').addEventListener('click', () => sendText('/status'));
  $('send-now').addEventListener('click', () => {
    const event = state.vad.flush();
    $('sending').hidden = true;
    if (event?.type === 'end') sendUtterance(event.samples);
    else caught();
    resumeQueue();
  });
  $('discard').addEventListener('click', () => {
    state.vad.reset();
    $('sending').hidden = true;
    setState(listeningLabel());
    resumeQueue();
  });
  $('compose').addEventListener('submit', (event) => {
    event.preventDefault();
    const text = $('text').value.trim();
    if (text) sendText(text);
    $('text').value = '';
  });
  $('text').addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      $('compose').requestSubmit();
    }
  });
  const talk = $('talk');
  talk.addEventListener('pointerdown', pressTalk);
  talk.addEventListener('pointerup', () => releasePtt());
  talk.addEventListener('pointerleave', () => releasePtt());
  talk.addEventListener('pointercancel', () => releasePtt(true));
  talk.addEventListener('contextmenu', (event) => event.preventDefault());
  window.addEventListener('blur', () => releasePtt(true));
  document.addEventListener('keydown', (event) => {
    if (!state.started) return;
    if (event.code === 'Space' && !event.repeat && talkKeyTarget(event)) {
      event.preventDefault();
      pressTalk();
    }
    if (event.key === 'Escape') bargeIn();
  });
  document.addEventListener('keyup', (event) => {
    if (event.code === 'Space' && (state.pressed || talkKeyTarget(event))) releasePtt();
  });
  $('settings-button').addEventListener('click', () => {
    const open = $('settings').hidden;
    $('settings').hidden = !open;
    $('settings-button').setAttribute('aria-expanded', String(open));
  });
  $('mode').value = state.mode;
  $('mode').addEventListener('change', () => {
    state.mode = $('mode').value;
    store('tamoz.talk.mode', state.mode);
    talk.textContent = state.mode === 'push-to-talk' ? 'Hold to talk' : 'Talk';
    state.vad.reset();
    $('sending').hidden = true;
    setTracks(state.mode !== 'muted');
    if (state.mode === 'push-to-talk') talk.setAttribute('aria-pressed', 'false');
    else talk.removeAttribute('aria-pressed');
    if (state.mode !== 'muted' && !state.voice && state.started) start({ voice: true });
    else if (state.mode !== 'muted') ensureMicrophone();
    setState(listeningLabel());
    resumeQueue();
  });
  $('hangover').value = String(state.vad.options.hangoverMs);
  $('hangover').addEventListener('change', () => {
    state.vad.setHangover(Number($('hangover').value));
    store('tamoz.talk.hangover', $('hangover').value);
  });
  $('speech').checked = state.speech;
  $('speech').addEventListener('change', () => {
    state.speech = $('speech').checked;
    store('tamoz.talk.speech', state.speech ? '1' : '0');
    if (!state.speech) bargeIn();
  });
  $('headphones').addEventListener('change', () => { state.fullDuplex = $('headphones').checked; });
  talk.textContent = state.mode === 'push-to-talk' ? 'Hold to talk' : 'Talk';
  if (state.mode !== 'push-to-talk') talk.removeAttribute('aria-pressed');
  navigator.mediaSession?.setActionHandler?.('pause', () => bargeIn());
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      releasePtt(true);
      state.vad.reset();
      $('sending').hidden = true;
      if (state.voice) setHint(SCREEN_PAUSED);
      return;
    }
    restartPoll();
    if (state.started) {
      navigator.wakeLock?.request('screen').catch(() => {});
      ensureMicrophone().then(() => {
        if (state.stream?.getAudioTracks().some((t) => t.readyState === 'live')) clearHint(SCREEN_PAUSED);
      });
      resumeQueue();
    }
  });
  window.addEventListener('online', () => restartPoll());
}

function napUnlessWoken(ms) {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms);
    state.wakePoll = () => { clearTimeout(timer); resolve(); };
  }).finally(() => { state.wakePoll = null; });
}

function restartPoll() {
  if (state.wakePoll) {
    state.wakePoll();
    return;
  }
  if (!state.pollAbort) return;
  state.restartPoll = true;
  state.pollAbort.abort();
}

function requireToken() {
  const ready = Boolean(state.token);
  $('start-button').disabled = !ready;
  $('text-only').disabled = !ready;
  $('start-note').textContent = ready
    ? 'Tap Start to use your microphone and hear replies.'
    : 'Open the link printed by `tamoz talk start` on this device.';
  return ready;
}

let polling = false;
function begin() {
  if (!requireToken() || polling) return;
  polling = true;
  state.dead = false;
  poll().finally(() => { polling = false; });
}

window.addEventListener('hashchange', () => {
  const token = readToken();
  if (token && token !== state.token) {
    state.token = token;
    state.epoch = '';
    state.after = 0;
    restartPoll();
  }
  begin();
});

bindControls();
['header', 'conversation', 'footer'].forEach((id) => $(id).setAttribute('inert', ''));
$('start-button').focus();
begin();
