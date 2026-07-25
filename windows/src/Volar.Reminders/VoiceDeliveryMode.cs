// VoiceDeliveryMode.cs — port of Sources/App/AppState.swift's `VoiceDeliveryMode` enum (Phase 4
// contract B). Owned here rather than in an App-wiring project (which does not exist yet in this
// Windows port — that is Wave 3) because `ReminderScheduler` needs the type itself to compile;
// see `IReminderSettingsProvider` for how the scheduler actually reads the current mode.
namespace Volar.Reminders;

/// <summary>
/// How reminders are delivered: the visual toast always fires (once the Wave-3 toast adapter is
/// wired); this only gates the ADDITIONAL spoken channel.
/// </summary>
public enum VoiceDeliveryMode
{
    VisualOnly,
    VisualPlusVoice,
    VoiceOnly
}
