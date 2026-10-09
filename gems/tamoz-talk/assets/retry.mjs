// Every update carries a browser-made id; a resend reuses it, so admission dedup makes resending harmless.
export const MAX_UPDATE_ID = 2 ** 53 - 1;
export const DELAYS_MS = Object.freeze([500, 1000, 2000, 4000, 8000]);

export function newUpdateId(now = Date.now(), random = Math.random) {
  return now * 1000 + Math.floor(random() * 1000);
}

// send(): Promise<{status}>; resolves 'admitted', 'refused' (a 4xx that a resend cannot fix) or keeps trying.
export async function sendUntilSettled(send, { sleep, delays = DELAYS_MS, onRetry = () => {} } = {}) {
  for (let attempt = 0; ; attempt += 1) {
    let status = 0;
    try {
      status = (await send()).status;
    } catch {
      status = 0;
    }
    if (status === 200) return { outcome: 'admitted', attempts: attempt + 1 };
    if (status >= 400 && status < 500 && status !== 408 && status !== 429) {
      return { outcome: 'refused', status, attempts: attempt + 1 };
    }
    onRetry(status, attempt);
    await sleep(delays[Math.min(attempt, delays.length - 1)]);
  }
}
