// Energy endpointing with an adaptive noise floor. Pure: frames in, segment events out.
export const FRAME_MS = 20;
const STEADY_FRAMES = 50;

export const DEFAULTS = Object.freeze({
  hangoverMs: 1200,
  preRollMs: 300,
  tailMs: 250,
  closingMs: 300,
  startFrames: 3,
  startRatio: 3,
  endRatio: 2,
  peakRatio: 6,
  minVoicedRatio: 0.3,
  minSpeechMs: 180,
  maxSegmentMs: 30000,
  noiseCheckMs: 6000,
  steadyCheckMs: 1500,
  steadyVariation: 0.2,
  floorFall: 0.1,
  floorRise: 0.02,
  minFloor: 0.002,
});

export function rms(frame) {
  let sum = 0;
  for (let i = 0; i < frame.length; i += 1) sum += frame[i] * frame[i];
  return Math.sqrt(sum / Math.max(frame.length, 1));
}

export class Vad {
  constructor(options = {}) {
    this.options = { ...DEFAULTS, ...options };
    this.floor = null;
    this.reset();
  }

  reset() {
    this.speaking = false;
    this.above = 0;
    this.below = 0;
    this.closing = false;
    this.preRoll = [];
    this.frames = [];
    this.levels = [];
  }

  setHangover(ms) {
    this.options.hangoverMs = Math.min(2000, Math.max(800, ms));
  }

  push(frame) {
    const level = rms(frame);
    if (this.floor === null) this.floor = this.options.minFloor;
    return this.speaking ? this.inSpeech(frame, level) : this.inSilence(frame, level);
  }

  voiced(level) {
    return level > this.floor * this.options.startRatio;
  }

  // The floor falls quickly toward quiet frames and rises slowly through room tone; speech never moves it.
  track(level) {
    const o = this.options;
    if (level >= this.floor * o.endRatio) return;
    const rate = level < this.floor ? o.floorFall : o.floorRise;
    this.floor = Math.max(o.minFloor, this.floor + (level - this.floor) * rate);
  }

  inSilence(frame, level) {
    const o = this.options;
    this.preRoll.push({ frame, level });
    const keep = Math.ceil(o.preRollMs / FRAME_MS) + o.startFrames;
    while (this.preRoll.length > keep) this.preRoll.shift();
    if (this.voiced(level)) {
      this.above += 1;
      return this.above >= o.startFrames ? this.begin() : null;
    }
    this.above = 0;
    this.track(level);
    return null;
  }

  begin() {
    this.speaking = true;
    this.frames = this.preRoll.map((entry) => entry.frame);
    this.levels = this.preRoll.map((entry) => entry.level);
    this.preRoll = [];
    this.below = 0;
    return { type: 'start' };
  }

  inSpeech(frame, level) {
    const o = this.options;
    this.frames.push(frame);
    this.levels.push(level);
    this.below = level < this.floor * o.endRatio ? this.below + 1 : 0;
    if (this.below === 0 && this.closing) {
      this.closing = false;
      return { type: 'resume' };
    }
    if (this.below * FRAME_MS >= o.hangoverMs) return this.finish('silence');
    if (this.frames.length * FRAME_MS >= o.maxSegmentMs) return this.finish('max');
    const elapsed = this.frames.length * FRAME_MS;
    if (elapsed >= o.steadyCheckMs && this.frames.length % 25 === 0) {
      const recent = this.levels.slice(-STEADY_FRAMES);
      const level = median(recent);
      if (level >= this.floor * o.endRatio && variation(recent) < o.steadyVariation) return this.settle(level);
    }
    if (elapsed === o.noiseCheckMs && this.span().ratio < o.minVoicedRatio) return this.finish('noise');
    if (!this.closing && this.below * FRAME_MS >= o.closingMs) {
      this.closing = true;
      return { type: 'closing' };
    }
    return null;
  }

  // The last second is steady noise, not speech: the floor rises to it, and whatever came before is the utterance.
  settle(level) {
    this.floor = Math.max(this.options.minFloor, level);
    this.below = STEADY_FRAMES;
    this.levels = this.levels.slice(0, -STEADY_FRAMES);
    const speech = this.span();
    if (speech.ms < this.options.minSpeechMs || speech.peak < level * this.options.peakRatio) {
      this.reset();
      return { type: 'drop', reason: 'steady' };
    }
    return this.finish('silence');
  }

  // Ends the current segment now (Send now, push-to-talk release).
  flush() {
    return this.speaking ? this.finish('flush') : null;
  }

  // Speech is measured over the voiced span, not the pre-roll and tail around it.
  span() {
    const voicedAt = this.levels.map((level, i) => (this.voiced(level) ? i : -1)).filter((i) => i >= 0);
    if (!voicedAt.length) return { ms: 0, ratio: 0, peak: 0 };
    const first = voicedAt[0];
    const last = voicedAt[voicedAt.length - 1];
    const frames = last - first + 1;
    return { ms: frames * FRAME_MS, ratio: voicedAt.length / frames, peak: Math.max(...this.levels) };
  }

  finish(cause) {
    const o = this.options;
    const { ms, ratio, peak } = this.span();
    const tail = Math.ceil(o.tailMs / FRAME_MS);
    const trailing = cause === 'silence' ? Math.max(0, this.below - tail) : 0;
    const frames = this.frames.slice(0, this.frames.length - trailing);
    const floor = this.floor;
    this.reset();
    if (cause === 'noise' || cause === 'steady') return { type: 'drop', reason: cause };
    if (ms < o.minSpeechMs) return { type: 'drop', reason: 'short' };
    if (ratio < o.minVoicedRatio) return { type: 'drop', reason: 'unvoiced' };
    if (peak < floor * o.peakRatio) return { type: 'drop', reason: 'quiet' };
    return { type: 'end', cause, samples: concat(frames), speechMs: ms, voicedRatio: ratio };
  }
}

export function concat(frames) {
  const total = frames.reduce((n, f) => n + f.length, 0);
  const out = new Float32Array(total);
  let offset = 0;
  for (const f of frames) {
    out.set(f, offset);
    offset += f.length;
  }
  return out;
}

// Speech rises and falls from frame to frame; a fan or a room's hum does not.
export function variation(levels) {
  const mean = levels.reduce((a, b) => a + b, 0) / Math.max(levels.length, 1);
  if (mean === 0) return 0;
  const spread = Math.sqrt(levels.reduce((a, b) => a + (b - mean) ** 2, 0) / Math.max(levels.length, 1));
  return spread / mean;
}

export function median(levels) {
  const sorted = [...levels].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)] || 0;
}
