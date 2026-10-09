import test from 'node:test';
import assert from 'node:assert/strict';
import { encodeWav, toInt16 } from '../../assets/wav.mjs';
import { newUpdateId, sendUntilSettled, MAX_UPDATE_ID } from '../../assets/retry.mjs';
import { pairHeard, heardText, settleOldest, recordSend } from '../../assets/pairing.mjs';
import { blocks, render } from '../../assets/render.mjs';

test('the WAV header is 16 kHz, 16-bit, mono PCM and the samples are clipped', () => {
  const wav = encodeWav(Float32Array.from([0, 1, -1, 2]));
  const view = new DataView(wav.buffer);
  const text = (o, n) => String.fromCharCode(...wav.subarray(o, o + n));
  assert.equal(text(0, 4), 'RIFF');
  assert.equal(text(8, 4), 'WAVE');
  assert.deepEqual([view.getUint16(20, true), view.getUint16(22, true), view.getUint32(24, true), view.getUint16(34, true)], [1, 1, 16000, 16]);
  assert.equal(view.getUint32(40, true), 8);
  assert.deepEqual([...toInt16(Float32Array.from([2, -2]))], [32767, -32768]);
});

test('update ids fit a JS number and a resend keeps the id', async () => {
  const id = newUpdateId(1_760_000_000_000, () => 0.999);
  assert.ok(id <= MAX_UPDATE_ID && Number.isSafeInteger(id));
  const seen = [];
  const statuses = [0, 503, 200];
  const result = await sendUntilSettled(() => { seen.push(id); return Promise.resolve({ status: statuses.shift() }); }, { sleep: async () => {} });
  assert.deepEqual([result.outcome, result.attempts], ['admitted', 3]);
  assert.deepEqual(new Set(seen), new Set([id]));
  const refused = await sendUntilSettled(() => Promise.resolve({ status: 413 }), { sleep: async () => {} });
  assert.equal(refused.outcome, 'refused');
});

test('update ids never repeat within a page, even in one millisecond or after the clock steps back', () => {
  const first = newUpdateId(1_760_000_000_000, () => 0.5);
  const same = newUpdateId(1_760_000_000_000, () => 0.5);
  const earlier = newUpdateId(1_759_999_999_000, () => 0.5);
  assert.ok(first < same && same < earlier);
});

test('a Heard pairs with the oldest admitted voice bubble still waiting', () => {
  const bubbles = [{ voice: true, admitted: true, heard: 'old' }, { voice: false, admitted: true }, { voice: true, admitted: true }, { voice: true, admitted: true }];
  assert.equal(pairHeard(bubbles, 'Heard: «check pond 7»'), bubbles[2]);
  assert.equal(bubbles[2].heard, 'check pond 7');
  assert.equal(pairHeard(bubbles, 'not a notice'), null);
  assert.equal(heardText('Heard: «a\nb»'), 'a\nb');
});

test('code fences become pre blocks and text never becomes markup', () => {
  assert.deepEqual(blocks('Hi\n```\n<b>x</b>\n```\nbye').map((b) => b.type), ['p', 'pre', 'p']);
  const created = [];
  const doc = { createElement: (tag) => { const node = { tag, set innerHTML(_) { throw new Error('innerHTML is forbidden'); } }; created.push(node); return node; } };
  const container = { children: [], replaceChildren() { this.children = []; }, appendChild(n) { this.children.push(n); } };
  render(doc, container, '<img src=x onerror=alert(1)>\n\n```\n<script>alert(1)</script>\n```');
  assert.deepEqual(container.children.map((n) => [n.tag, n.textContent]), [['p', '<img src=x onerror=alert(1)>'], ['pre', '<script>alert(1)</script>']]);
});

test('a voice bubble whose transcription never came is closed by its answer and later Heards pair correctly', () => {
  const bubbles = [{ voice: true, admitted: true }, { voice: true, admitted: true }, { command: true, admitted: true }];
  assert.equal(settleOldest(bubbles, 'failed'), bubbles[0]);
  assert.equal(bubbles[0].heard, null);
  assert.equal(pairHeard(bubbles, 'Heard: «second»'), bubbles[1]);
  assert.equal(settleOldest(bubbles, 'approval_request'), null, 'an approval request does not end a turn');
  assert.equal(settleOldest(bubbles, 'answer'), bubbles[1]);
  assert.equal(settleOldest(bubbles, 'answer'), null, 'commands are never waiting for an answer');
});

test('only the first part of a split answer ends a turn', () => {
  const bubbles = [{ voice: true, admitted: true }, { voice: true, admitted: true }];
  assert.equal(settleOldest(bubbles, 'answer', 0), bubbles[0]);
  assert.equal(settleOldest(bubbles, 'answer', 1), null, 'a later part of the same answer');
  const refused = { voice: true };
  const later = { voice: true };
  assert.equal(recordSend(refused, 'refused'), false);
  assert.equal(recordSend(later, 'admitted'), true);
  assert.equal(pairHeard([refused, later], 'Heard: «later»'), later, 'a refused send never takes a Heard');
  assert.equal(settleOldest([refused, later], 'answer'), later, 'nor an answer');
});
