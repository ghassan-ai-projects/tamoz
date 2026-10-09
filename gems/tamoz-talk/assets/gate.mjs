// When the microphone may feed the endpointer, and when a reply may start: in half-duplex Tamoz never hears
// itself, because capture is off while it speaks and for a short tail after.
export const HALF_DUPLEX_TAIL_MS = 400;
export const PTT_TAIL_MS = 250;

export function capturing(s, now) {
  if (!s.voice || s.mode === 'muted') return false;
  if (s.fullDuplex) return true;
  return !s.playing && now >= s.tailUntil;
}

export function holdsPtt(s, now) {
  return (s.pressed || now < s.pttUntil) && (s.fullDuplex || !s.playing);
}

export function userSpeaking(s, now) {
  return s.vad.speaking || s.pressed || now < s.pttUntil;
}
