import test from 'node:test';
import assert from 'node:assert/strict';
import { HALF_DUPLEX_TAIL_MS, PTT_TAIL_MS, capturing, holdsPtt, userSpeaking } from '../../assets/gate.mjs';

const base = { voice: true, mode: 'hands-free', fullDuplex: false, playing: null, tailUntil: 0, pressed: false,
  pttUntil: 0, vad: { speaking: false } };

test('half-duplex: the microphone is off while Tamoz speaks and for a tail after', () => {
  assert.equal(capturing(base, 1000), true);
  assert.equal(capturing({ ...base, playing: 7 }, 1000), false);
  const ended = 1000;
  const after = { ...base, tailUntil: ended + HALF_DUPLEX_TAIL_MS };
  assert.equal(capturing(after, ended + HALF_DUPLEX_TAIL_MS - 1), false);
  assert.equal(capturing(after, ended + HALF_DUPLEX_TAIL_MS), true);
  assert.equal(capturing({ ...base, playing: 7, fullDuplex: true }, 1000), true, 'headphones let the user talk over it');
  assert.equal(capturing({ ...base, mode: 'muted' }, 1000), false);
  assert.equal(capturing({ ...base, voice: false }, 1000), false);
});

test('push-to-talk keeps frames while held and for the release tail, never while Tamoz speaks', () => {
  assert.equal(holdsPtt({ ...base, pressed: true }, 0), true);
  assert.equal(holdsPtt({ ...base, pttUntil: PTT_TAIL_MS }, PTT_TAIL_MS - 1), true);
  assert.equal(holdsPtt({ ...base, pttUntil: PTT_TAIL_MS }, PTT_TAIL_MS), false);
  assert.equal(holdsPtt({ ...base, pressed: true, playing: 3 }, 0), false);
  assert.equal(holdsPtt({ ...base, pressed: true, playing: 3, fullDuplex: true }, 0), true);
});

test('a reply waits while the user is speaking, holding the button or in its tail', () => {
  assert.equal(userSpeaking(base, 0), false);
  assert.equal(userSpeaking({ ...base, vad: { speaking: true } }, 0), true);
  assert.equal(userSpeaking({ ...base, pressed: true }, 0), true);
  assert.equal(userSpeaking({ ...base, pttUntil: 100 }, 99), true);
});
