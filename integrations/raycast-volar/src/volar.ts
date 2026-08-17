// Shared helper — the one place this extension knows anything about Volar.
//
// Everything here rides on `volar://capture`, the URL scheme the Mac app already registers
// (docs/url-scheme.md). That is the entire integration surface: no local server, no file drop, no
// database. If the scheme ever changes, it changes here and nowhere else.

/** Same 2000-character ceiling every other Volar capture entry point enforces. */
const MAX_TEXT = 2000;

/**
 * Builds `volar://capture?text=…&source=…`.
 *
 * `URLSearchParams` percent-encodes both values, which is what stops a sentence containing `&`,
 * `#`, or Vietnamese diacritics from truncating the URL halfway through.
 */
export function captureURL(text: string, source = "Raycast"): string {
  const trimmed = text.trim().slice(0, MAX_TEXT);
  const params = new URLSearchParams({ text: trimmed, source });
  return `volar://capture?${params.toString()}`;
}

/**
 * Volar shows its own confirm card for anything that arrives this way — the user is at their Mac
 * with their eyes on the screen, so a one-second glance is the cheapest place to catch a
 * mis-parsed date. This message is deliberately "sent", not "added": claiming the task exists
 * before Volar has confirmed it would be a lie about half a second long, and the wrong half.
 */
export const SENT_MESSAGE = "Sent to Volar";
