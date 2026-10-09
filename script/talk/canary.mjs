#!/usr/bin/env node
// The talk page end to end in headless Chrome: the WAV is the page's microphone, the real page endpoints it, sends it,
// and plays the reply. Prints one JSON line: the page's talkTrace marks and whether they came in order.
// Headless Chrome on macOS never resolves getUserMedia (the OS microphone permission), so the capture stream is built
// from the WAV in the page itself; everything after the browser's capture layer is the real page.
//
//   node script/talk/canary.mjs --url URL --wav PATH --scenario ask|approval|barge_in [--timeout 180]
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, existsSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { StringDecoder } from 'node:string_decoder';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const ORDER = {
  ask: ['segment_end', 'post', 'admitted', 'heard', 'answer', 'playing'],
  approval: ['segment_end', 'post', 'admitted', 'heard', 'approval_card', 'approve_click', 'answer'],
  barge_in: ['segment_end', 'post', 'admitted', 'heard', 'answer', 'playing', 'barge_in_stop'],
};

const args = Object.fromEntries(process.argv.slice(2).join(' ').split(/\s*--/).filter(Boolean)
  .map((pair) => pair.split(/\s+/)).map(([key, ...value]) => [key, value.join(' ')]));
const timeoutMs = Number(args.timeout || 180) * 1000;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function done(result) {
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

if (!existsSync(CHROME)) {
  done({ scenario: args.scenario, outcome: 'blocked', detail: 'no Google Chrome' });
  process.exit(0);
}

class Cdp {
  constructor(child) {
    this.out = child.stdio[3];
    this.waiting = new Map();
    this.id = 0;
    this.buffer = '';
    const decoder = new StringDecoder('utf8');
    child.stdio[4].on('data', (chunk) => {
      this.buffer += decoder.write(chunk);
      let end;
      while ((end = this.buffer.indexOf('\0')) >= 0) {
        const message = JSON.parse(this.buffer.slice(0, end));
        this.buffer = this.buffer.slice(end + 1);
        const pending = this.waiting.get(message.id);
        if (!pending) continue;
        this.waiting.delete(message.id);
        if (message.error) pending.reject(new Error(message.error.message));
        else pending.resolve(message.result);
      }
    });
  }

  send(method, params = {}, sessionId = undefined) {
    this.id += 1;
    const id = this.id;
    this.out.write(`${JSON.stringify({ id, method, params, sessionId })}\0`);
    return new Promise((resolve, reject) => this.waiting.set(id, { resolve, reject }));
  }
}

const profile = mkdtempSync(join(tmpdir(), 'talk-canary-'));
const chrome = spawn(CHROME, [
  '--headless=new', '--remote-debugging-pipe', '--no-first-run', '--no-default-browser-check',
  `--user-data-dir=${profile}`, '--autoplay-policy=no-user-gesture-required', 'about:blank',
], { stdio: ['ignore', 'ignore', 'ignore', 'pipe', 'pipe'] });

const cdp = new Cdp(chrome);
let session;
const page = (method, params) => cdp.send(method, params, session);
const evaluate = async (expression) => {
  const reply = await page('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (reply.exceptionDetails) throw new Error(reply.exceptionDetails.text);
  return reply.result.value;
};
const until = async (expression, what) => {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await evaluate(expression)) return true;
    await sleep(100);
  }
  throw new Error(`timed out waiting for ${what}`);
};
// A trusted click, so the page sees a real user gesture.
const click = async (selector) => {
  const box = await evaluate(`(() => { const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`);
  const at = await evaluate('performance.now()');
  for (const type of ['mousePressed', 'mouseReleased']) {
    await page('Input.dispatchMouseEvent', { type, x: box.x, y: box.y, button: 'left', clickCount: 1 });
  }
  return at;
};
const marks = () => evaluate('window.talkTrace.map((m) => ({ ...m, at: Math.round(m.at) }))');
const has = (name) => `window.talkTrace.some((m) => m.name === '${name}')`;

function inOrder(trace, names) {
  let from = -1;
  const missing = [];
  for (const name of names) {
    const index = trace.findIndex((m, i) => i > from && m.name === name);
    if (index < 0) missing.push(name);
    else from = index;
  }
  return missing;
}

let result;
try {
  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  ({ sessionId: session } = await cdp.send('Target.attachToTarget', { targetId, flatten: true }));
  await page('Page.enable');
  await page('Runtime.enable');
  const wav = readFileSync(args.wav).toString('base64');
  await page('Page.addScriptToEvaluateOnNewDocument', { source: `navigator.mediaDevices.getUserMedia = async () => {
    const context = new AudioContext();
    const bytes = Uint8Array.from(atob('${wav}'), (c) => c.charCodeAt(0));
    const source = context.createBufferSource();
    source.buffer = await context.decodeAudioData(bytes.buffer);
    const sink = context.createMediaStreamDestination();
    source.connect(sink);
    source.start();
    return sink.stream;
  };` });
  await page('Page.navigate', { url: args.url });
  await until("document.readyState === 'complete' && !document.getElementById('start-button')?.disabled", 'the page');
  await click('#start-button');
  const extra = [];
  if (args.scenario === 'approval') {
    await until("!!document.querySelector('[role=alertdialog] button')", 'the approval card');
    extra.push({ name: 'approval_card', at: Math.round(await evaluate('performance.now()')) });
    const approve = await evaluate("[...document.querySelectorAll('[role=alertdialog] button')].some((b) => b.textContent === 'Approve')");
    if (!approve) throw new Error('the card offers no Approve');
    const at = await evaluate(`(() => { const b = [...document.querySelectorAll('[role=alertdialog] button')]
      .find((x) => x.textContent === 'Approve'); b.dataset.canary = '1'; return performance.now(); })()`);
    await click('[data-canary="1"]');
    extra.push({ name: 'approve_click', at: Math.round(at) });
    await until(`window.talkTrace.some((m) => m.name === 'answer' && m.at > ${at})`, 'the answer after approval');
  } else {
    await until(has('playing'), 'playback');
  }
  let bargeMs = null;
  if (args.scenario === 'barge_in') {
    const clicked = await click('#talk');
    await until(has('barge_in_stop'), 'the barge-in stop');
    const stop = (await marks()).find((m) => m.name === 'barge_in_stop');
    bargeMs = Math.round(stop.at - clicked);
  }
  const trace = [...(await marks()), ...extra].sort((a, b) => a.at - b.at);
  const missing = inOrder(trace, ORDER[args.scenario]);
  const fast = args.scenario !== 'barge_in' || bargeMs <= 150;
  result = { scenario: args.scenario, outcome: missing.length === 0 && fast ? 'pass' : 'fail', capture: 'script', missing,
    barge_in_ms: bargeMs, trace };
} catch (error) {
  let trace = [];
  try { trace = await marks(); } catch { /* the page may be gone */ }
  let pageState = null;
  try {
    pageState = await evaluate(`({ state: document.getElementById('state')?.textContent,
      hint: document.getElementById('hint')?.textContent, startShown: !document.getElementById('start')?.hidden,
      bubbles: document.querySelectorAll('#conversation .bubble, #conversation article').length })`);
  } catch { /* the page may be gone */ }
  result = { scenario: args.scenario, outcome: 'invalid', detail: error.message, page: pageState, trace };
} finally {
  const exited = new Promise((resolve) => { chrome.once('exit', resolve); setTimeout(resolve, 5000); });
  chrome.kill('SIGTERM');
  await exited;
  rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
done(result);
process.exit(0);
