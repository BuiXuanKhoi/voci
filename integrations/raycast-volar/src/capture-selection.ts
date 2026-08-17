import { getSelectedText, open, showHUD } from "@raycast/api";
import { captureURL, SENT_MESSAGE } from "./volar";

/**
 * "Capture Selection" — turn whatever text is selected in the frontmost app into a task.
 *
 * This overlaps with the Mac app's own Services menu entry (right-click → New Task in Volar) and
 * that is fine: they suit different hands. The Services menu wants a right-click; this wants a
 * keyboard shortcut, which is how Raycast users actually work. Both end at the same
 * `volar://capture`, so neither can drift from the other.
 *
 * `getSelectedText()` throws rather than returning empty when Raycast can't read the selection —
 * usually because the frontmost app doesn't expose it, or Accessibility permission hasn't been
 * granted to Raycast. Say which, instead of failing silently.
 */
export default async function CaptureSelection() {
  let text: string;
  try {
    text = (await getSelectedText()).trim();
  } catch {
    await showHUD("Couldn't read the selection — check Raycast's Accessibility permission");
    return;
  }

  if (!text) {
    await showHUD("Nothing selected");
    return;
  }

  await open(captureURL(text, "Raycast Selection"));
  await showHUD(SENT_MESSAGE);
}
