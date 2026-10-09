// Deterministic test signals at 16 kHz: speech-like bursts, pauses, and the noises a mic picks up.
export const RATE = 16000;
export const FRAME = 320;

export function random(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state * 1664525 + 1013904223) >>> 0;
    return state / 2 ** 32;
  };
}

export function silence(ms, level = 0.001, rng = random(1)) {
  return Float32Array.from({ length: (RATE * ms) / 1000 }, () => (rng() * 2 - 1) * level);
}

// Band-limited noise modulated at a syllable rate: loud enough and voiced like speech for an energy detector.
export function speech(ms, rng = random(2), amplitude = 0.2) {
  const n = (RATE * ms) / 1000;
  const out = new Float32Array(n);
  let low = 0;
  for (let i = 0; i < n; i += 1) {
    low = low * 0.7 + (rng() * 2 - 1) * 0.3;
    const syllable = 0.55 + 0.45 * Math.sin((2 * Math.PI * 4 * i) / RATE);
    out[i] = low * amplitude * 3 * syllable;
  }
  return out;
}

export function hum(ms, rng = random(3)) {
  const n = (RATE * ms) / 1000;
  return Float32Array.from({ length: n }, (_, i) => 0.02 * Math.sin((2 * Math.PI * 120 * i) / RATE) + (rng() * 2 - 1) * 0.005);
}

export function clicks(ms, rng = random(4)) {
  const out = silence(ms, 0.001, rng);
  for (let at = 0; at < out.length; at += Math.floor(RATE * (0.08 + rng() * 0.15))) {
    for (let k = 0; k < 40 && at + k < out.length; k += 1) out[at + k] += (rng() * 2 - 1) * 0.5 * Math.exp(-k / 8);
  }
  return out;
}

// A cough: one short broadband burst (about 120–160 ms).
export function cough(rng = random(5)) {
  const n = Math.floor(RATE * (0.12 + rng() * 0.04));
  const burst = Float32Array.from({ length: n }, (_, i) => (rng() * 2 - 1) * 0.5 * Math.exp(-i / (n / 3)));
  return join(silence(300, 0.001, rng), burst, silence(300, 0.001, rng));
}

// A flat-energy short word ("yes", "no").
export function word(ms, rng = random(6), amplitude = 0.2) {
  const n = (RATE * ms) / 1000;
  return Float32Array.from({ length: n }, () => (rng() * 2 - 1) * amplitude);
}

// Pink-ish noise: white noise through a running average, at a given level.
export function pink(ms, level = 0.01, rng = random(7)) {
  let low = 0;
  return Float32Array.from({ length: (RATE * ms) / 1000 }, () => {
    low = low * 0.95 + (rng() * 2 - 1) * 0.05;
    return low * level * 10;
  });
}

export function join(...parts) {
  const out = new Float32Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

export function mix(a, b, gain) {
  return a.map((v, i) => v + (b[i % b.length] || 0) * gain);
}

export function frames(signal) {
  const out = [];
  for (let i = 0; i + FRAME <= signal.length; i += FRAME) out.push(signal.subarray(i, i + FRAME));
  return out;
}

export function run(vad, signal) {
  const events = [];
  for (const f of frames(signal)) {
    const event = vad.push(f);
    if (event) events.push(event);
  }
  return events;
}
