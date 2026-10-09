// C9: the endpointing eval (EVAL §7), on generated signals with fixed seeds.
import test from 'node:test';
import assert from 'node:assert/strict';
import { Vad } from '../../assets/vad.mjs';
import { silence, speech, join, run, cough, clicks, hum, mix, random, pink } from './signals.mjs';

const segments = (vad, signal) => run(vad, signal).filter((e) => e.type === 'end').length;

// Pauses are room tone at a level that varies per seed, so the floor, the thresholds and the hang-over all matter.
function sentence(seed, pauseMs) {
  const rng = random(seed);
  const room = 0.002 + (seed % 7) * 0.001;
  return join(pink(800, room, rng), speech(600 + seed % 5 * 100, rng), pink(pauseMs, room, rng),
    speech(500 + seed % 7 * 100, rng), pink(1600, room, rng));
}

test('premature cuts at the 0.8 s setting with 0.5–0.7 s pauses are at most 5%', () => {
  let cut = 0;
  for (let seed = 1; seed <= 60; seed += 1) {
    const vad = new Vad();
    vad.setHangover(800);
    if (segments(vad, sentence(seed, seed % 2 ? 500 : 700)) > 1) cut += 1;
  }
  assert.ok(cut / 60 <= 0.05, `premature cuts ${cut}/60`);
});

test('premature cuts at the default hang-over with 1.0 s pauses are at most 2%', () => {
  let cut = 0;
  for (let seed = 1; seed <= 60; seed += 1) if (segments(new Vad(), sentence(seed, 1000)) > 1) cut += 1;
  assert.ok(cut / 60 <= 0.02, `premature cuts ${cut}/60`);
});

test('false triggers on 100 noise-only clips are at most 2%', () => {
  let triggered = 0;
  for (let seed = 1; seed <= 100; seed += 1) {
    const rng = random(seed * 7);
    const kinds = [() => clicks(2500, rng), () => join(silence(400, 0.001, rng), hum(2500, rng)),
      () => join(silence(800, 0.001, rng), cough(rng), silence(1200, 0.001, rng)), () => pink(2500, 0.008, rng),
      () => join(new Float32Array(320), pink(2500, 0.006, rng))];
    if (segments(new Vad(), kinds[seed % kinds.length]()) > 0) triggered += 1;
  }
  assert.ok(triggered / 100 <= 0.02, `false triggers ${triggered}/100`);
});

test('reported: end-of-turn delay and echo at -25 dB (full-duplex)', () => {
  let echoTriggers = 0;
  for (let seed = 1; seed <= 50; seed += 1) {
    const rng = random(seed * 11);
    const echo = mix(silence(3000, 0.001, rng), speech(3000, rng), 10 ** (-25 / 20));
    if (segments(new Vad(), echo) > 0) echoTriggers += 1;
  }
  console.log(`C9 report: false barge-in from -25 dB echo ${echoTriggers}/50 (report only; real AEC not modeled)`);
});

test('controls: a naive 300 ms cutter fails the cut grader and an ungated VAD fails the noise grader', () => {
  let cut = 0;
  for (let seed = 1; seed <= 60; seed += 1) if (segments(new Vad({ hangoverMs: 300 }), sentence(seed, 1000)) > 1) cut += 1;
  assert.ok(cut / 60 > 0.05, `the naive cutter split only ${cut}/60`);
  let triggered = 0;
  for (let seed = 1; seed <= 100; seed += 1) {
    const rng = random(seed * 7);
    const ungated = new Vad({ minSpeechMs: 0, minVoicedRatio: 0, peakRatio: 0, noiseCheckMs: 1e9 });
    if (segments(ungated, join(silence(800, 0.001, rng), cough(rng), silence(1200, 0.001, rng))) > 0) triggered += 1;
  }
  assert.ok(triggered / 100 > 0.02, `the ungated VAD fired on only ${triggered}/100 coughs`);
});

test('reported: end-of-turn delay at the default hang-over', () => {
  const delays = [];
  for (let seed = 1; seed <= 30; seed += 1) {
    const rng = random(seed * 13);
    const signal = join(silence(800, 0.001, rng), speech(1200, rng), silence(2500, 0.001, rng));
    const vad = new Vad();
    let frame = 0;
    for (let i = 0; i + 320 <= signal.length; i += 320) {
      frame += 1;
      if (vad.push(signal.subarray(i, i + 320))?.type === 'end') break;
    }
    delays.push(frame * 20 - 2000);
  }
  delays.sort((a, b) => a - b);
  console.log(`C9 report: end-of-turn delay median ${delays[15]} ms (default hang-over 1200 ms)`);
  assert.ok(delays[15] >= 1100 && delays[15] <= 1400);
});

test('control: a frozen floor fails the room-tone grader', () => {
  let stuck = 0;
  for (let seed = 1; seed <= 20; seed += 1) {
    const rng = random(seed * 17);
    const vad = new Vad({ floorFall: 0, floorRise: 0, calibrationFrames: 0 });
    vad.floor = 0.002;
    const events = run(vad, join(pink(2500, 0.008, rng), silence(500, 0.001, rng)));
    if (events.some((e) => e.type === 'start')) stuck += 1;
  }
  assert.ok(stuck > 0, 'a floor that never moves must mistake room tone for speech');
});
