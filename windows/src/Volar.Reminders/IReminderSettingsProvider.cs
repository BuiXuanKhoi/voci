// IReminderSettingsProvider.cs — Settings seam.
//
// Swift's `ReminderScheduler.swift` reads `VoiceDeliveryMode`/global `ReminderPolicy` directly out
// of `UserDefaults` via two static helpers (`currentVoiceDeliveryMode()`/
// `currentGlobalReminderPolicy()`), using key constants owned by `AppState` (App-wiring). That
// out-of-band read is itself I/O and a dependency on a settings store this project must not take
// (Volar.Reminders is pure/no-I/O per this task's brief, and the App-wiring layer doesn't exist
// yet — it's Wave 3). This interface is the injection seam instead, mirroring the pattern
// `Volar.Data/IRecurrenceResetter.cs` already uses for its own not-yet-available dependency:
// Wave 3's app-wiring agent should implement this against whatever local-settings store it builds.
using Volar.Domain;

namespace Volar.Reminders;

public interface IReminderSettingsProvider
{
    VoiceDeliveryMode CurrentVoiceDeliveryMode { get; }

    ReminderPolicy CurrentGlobalReminderPolicy { get; }
}

/// <summary>
/// Default provider — visual+voice / global default policy, matching Swift's own fallback
/// (<c>raw.flatMap(...) ?? .visualPlusVoice</c>, <c>... ?? .defaultPolicy</c>) for when nothing is
/// configured yet. Safe to use directly (and used as <see cref="ReminderScheduler"/>'s own default)
/// until Wave 3 wires a real settings-backed provider.
/// </summary>
public sealed class DefaultReminderSettingsProvider : IReminderSettingsProvider
{
    public VoiceDeliveryMode CurrentVoiceDeliveryMode => VoiceDeliveryMode.VisualPlusVoice;

    public ReminderPolicy CurrentGlobalReminderPolicy => ReminderPolicy.DefaultPolicy;
}
