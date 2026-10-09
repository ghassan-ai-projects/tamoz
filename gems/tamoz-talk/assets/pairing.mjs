// A thread's turns run in order: each "Heard" belongs to the oldest voice bubble still open, and each final
// reply closes the oldest open bubble, so a transcription that never came cannot shift later ones.
export const HEARD = /^Heard: «([\s\S]*)»$/;
export const FINAL_KINDS = Object.freeze(['answer', 'failed', 'stopped', 'blocked']);

export function heardText(text) {
  const match = HEARD.exec(text || '');
  return match ? match[1] : null;
}

const open = (bubble) => !bubble.command && !bubble.answered && !bubble.refused;

export function pairHeard(bubbles, text) {
  const heard = heardText(text);
  if (heard === null) return null;
  const bubble = bubbles.find((b) => open(b) && b.voice && b.heard === undefined);
  if (!bubble) return null;
  bubble.heard = heard;
  return bubble;
}

// A send the server refused never gets a Heard or an answer, so it must not hold a place in the order.
export function recordSend(bubble, outcome) {
  if (outcome === 'admitted') bubble.admitted = true;
  else bubble.refused = true;
  return bubble.admitted === true;
}

export function settleOldest(bubbles, kind, partIndex = 0) {
  if (!FINAL_KINDS.includes(kind) || partIndex !== 0) return null;
  const bubble = bubbles.find(open);
  if (!bubble) return null;
  bubble.answered = true;
  if (bubble.voice && bubble.heard === undefined) bubble.heard = null;
  return bubble;
}
