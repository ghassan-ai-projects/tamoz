import test from 'node:test';
import assert from 'node:assert/strict';
import { Vad } from '../../assets/vad.mjs';
import { silence, speech, join, run, cough, clicks, hum, random, word, pink } from './signals.mjs';

const ends = (events) => events.filter((e) => e.type === 'end');

test('a sentence between silences is one segment with its pre-roll', () => {
  const events = run(new Vad(), join(silence(1000), speech(1500), silence(1500)));
  assert.deepEqual(events.map((e) => e.type).filter((t) => t !== 'closing'), ['start', 'end']);
  assert.ok(ends(events)[0].samples.length >= 16000 * 1.5);
});

test('an inner pause shorter than the hang-over does not split the sentence', () => {
  const events = run(new Vad(), join(silence(1000), speech(800), silence(1000), speech(800), silence(1500)));
  assert.equal(ends(events).length, 1);
});

test('a pause longer than the hang-over ends the segment, and the setting is clamped to 0.8–2 s', () => {
  const vad = new Vad();
  vad.setHangover(100);
  assert.equal(vad.options.hangoverMs, 800);
  const events = run(vad, join(silence(1000), speech(800), silence(1000), speech(800), silence(1500)));
  assert.equal(ends(events).length, 2);
});

test('coughs, clicks and hum never become a segment', () => {
  for (const signal of [join(silence(1000), cough(), silence(1500)), clicks(3000), join(silence(500), hum(3000))]) {
    assert.equal(ends(run(new Vad(), signal)).length, 0);
  }
});

test('a segment is cut at the maximum length and flush ends one early', () => {
  const vad = new Vad({ maxSegmentMs: 2000 });
  assert.equal(ends(run(vad, join(silence(500), speech(5000)))).length, 2);
  const early = new Vad();
  run(early, join(silence(500), speech(1000)));
  assert.equal(early.flush().type, 'end');
  assert.equal(early.flush(), null);
});

test('the noise floor adapts so a steady fan does not hide speech above it', () => {
  const rng = random(9);
  const events = run(new Vad(), join(hum(1500, rng), speech(1500, rng), hum(1500, rng)));
  assert.equal(ends(events).length, 1);
});

test('short words of 200–300 ms are sent, not dropped', () => {
  for (const ms of [200, 240, 300]) {
    for (let seed = 1; seed <= 10; seed += 1) {
      const events = run(new Vad(), join(silence(800, 0.001, random(seed)), word(ms, random(seed + 50)), silence(1500, 0.001, random(seed))));
      assert.equal(ends(events).length, 1, `${ms} ms word, seed ${seed}`);
      assert.ok(Math.abs(ends(events)[0].speechMs - ms) <= 40, `speech ${ends(events)[0].speechMs} for ${ms}`);
    }
  }
});

test('a dropout frame before room tone cannot open a segment that never ends', () => {
  const events = run(new Vad(), join(new Float32Array(320), pink(8000, 0.008), silence(1500, 0.001)));
  assert.equal(ends(events).length, 0);
  const drop = events.find((e) => e.type === 'drop');
  assert.ok(!events.some((e) => e.type === 'start') || drop?.reason === 'steady', JSON.stringify(events));
});

test('the floor rises through steady room tone, so speech above it still starts a segment', () => {
  const rng = random(21);
  const events = run(new Vad(), join(silence(300, 0.001, rng), pink(3000, 0.006, rng), speech(1200, rng), pink(2000, 0.006, rng)));
  assert.equal(ends(events).length, 1);
});

test('a segment announces it is closing before it ends', () => {
  const events = run(new Vad(), join(silence(800), speech(1000), silence(1500)));
  assert.deepEqual(events.map((e) => e.type), ['start', 'closing', 'end']);
});

test('speech that returns while closing resumes the segment instead of ending it', () => {
  const events = run(new Vad(), join(silence(800), speech(1000), silence(500), speech(800), silence(1500)));
  assert.deepEqual(events.map((e) => e.type), ['start', 'closing', 'resume', 'closing', 'end']);
});

test('a flat 120 ms burst is dropped as too short', () => {
  const burst = Float32Array.from({ length: 1920 }, (_, i) => (i % 2 ? 0.2 : -0.2));
  const events = run(new Vad(), join(silence(800), burst, silence(1500)));
  assert.equal(ends(events).length, 0);
  assert.deepEqual(events.filter((e) => e.type === 'drop').map((e) => e.reason), ['short']);
});

test('the first 300 ms only measure the room, so a loud room the microphone opens into never starts a segment', () => {
  const events = run(new Vad(), pink(800, 0.008, random(31)));
  assert.deepEqual(events.filter((e) => e.type === 'start'), []);
});

test('speech the instant the microphone opens is not kept as the room: the floor falls back for the next sentence', () => {
  const events = run(new Vad(), join(speech(1000), silence(1500), speech(1000), silence(1500)));
  assert.ok(ends(events).length >= 1);
});
