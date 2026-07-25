// ReminderContextGate.cs — port of Sources/Reminders/ReminderContextGate.swift: voice-suppression
// gate (contract §B). Constitution I / the contract's explicit instruction: "fail toward
// SUPPRESSED when unsure." Every concrete signal below either (a) produces a definite true/false
// from an injected extension point, or (b) defaults to "no signal" (not suppressing on that axis
// alone) until a caller wires it — see the doc comment on each property.
namespace Volar.Reminders;

/// <summary>A closed time window, mirroring Swift's <c>DateInterval</c> (used here for busy-calendar
/// windows).</summary>
public readonly record struct ReminderTimeRange(DateTimeOffset Start, DateTimeOffset End)
{
    public bool Contains(DateTimeOffset instant) => instant >= Start && instant <= End;
}

public sealed class ReminderContextGate
{
    /// <summary>
    /// Calendar-busy windows. Injected by the caller — empty until calendar integration lands
    /// (contract §B says so explicitly: "busyIntervals injected — [] until P3"). A `now` inside any
    /// interval here suppresses voice.
    /// </summary>
    public IReadOnlyList<ReminderTimeRange> BusyIntervals { get; set; } = Array.Empty<ReminderTimeRange>();

    // MARK: - Extension points
    //
    // The first four mirror the Swift original 1:1 (mic capture / other audio / screen-sharing /
    // Focus-DND all have no stable, unprivileged public API this pure project can call directly —
    // same reasoning Swift gave for leaving them as `nil`-by-default injection points).
    public Func<bool>? IsLocalMicCaptureActive { get; set; }

    public Func<bool>? IsOtherAudioPlaying { get; set; }

    public Func<bool>? IsScreenBeingShared { get; set; }

    public Func<bool>? IsDoNotDisturbOn { get; set; }

    /// <summary>
    /// Windows deviation (documented, not a gap): Swift's fifth signal
    /// (<c>isAnotherAppUsingMicrophone</c>) was a CONCRETE, no-extra-entitlement AVFoundation check
    /// (<c>AVCaptureDevice.isInUseByAnotherApplication</c>) called directly from this file. There is
    /// no framework-free Windows equivalent this pure project can call without violating the "no
    /// Windows App SDK" dependency rule, so it is demoted here from "concrete check" to a fifth
    /// injectable extension point — defaults to no signal (not suppressing), same as the other
    /// four, until a Wave-3 caller wires a real WASAPI/MediaCapture-backed check.
    /// </summary>
    public Func<bool>? IsAnotherAppUsingMicrophone { get; set; }

    /// <summary>
    /// <see langword="true"/> suppresses the voice rung for this fire (visual delivery is
    /// unaffected either way — this gate only ever guards the spoken channel, never the toast
    /// banner).
    /// </summary>
    public bool ShouldSuppressVoice(DateTimeOffset now)
    {
        foreach (var range in BusyIntervals)
        {
            if (range.Contains(now))
            {
                return true;
            }
        }
        if (IsLocalMicCaptureActive?.Invoke() == true)
        {
            return true;
        }
        if (IsOtherAudioPlaying?.Invoke() == true)
        {
            return true;
        }
        if (IsScreenBeingShared?.Invoke() == true)
        {
            return true;
        }
        if (IsDoNotDisturbOn?.Invoke() == true)
        {
            return true;
        }
        if (IsAnotherAppUsingMicrophone?.Invoke() == true)
        {
            return true;
        }
        return false;
    }
}
