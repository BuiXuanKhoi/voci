import { open, showHUD, LaunchProps } from "@raycast/api";
import { captureURL, SENT_MESSAGE } from "./volar";

/**
 * "Add Task" — type the sentence straight into Raycast's own argument field.
 *
 * `mode: "no-view"` on purpose: this command must never draw a window. The whole point of reaching
 * Volar from Raycast is that the user is already mid-something-else, and a second UI to dismiss is
 * exactly the context switch being avoided. Raycast's HUD is the entire feedback surface.
 */
export default async function AddTask(props: LaunchProps<{ arguments: { text: string } }>) {
  const text = props.arguments.text?.trim() ?? "";
  if (!text) {
    await showHUD("Nothing to add");
    return;
  }
  await open(captureURL(text));
  await showHUD(SENT_MESSAGE);
}
