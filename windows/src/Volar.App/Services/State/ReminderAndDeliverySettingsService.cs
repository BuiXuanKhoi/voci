// Services/State/ReminderAndDeliverySettingsService.cs — port of AppState.swift's §1.3 reminder/
// voice-delivery settings (`voiceDeliveryMode`/`globalReminderPolicy`, lines 233-241,
// `setVoiceDeliveryMode`/`setGlobalReminderPolicy`, lines 2130-2145) plus the FR-016 overdue-
// reschedule scan (`offerRescheduleForOverdueTasks`, lines 2196-2220). Inventory cluster G.
//
// SCOPE NOTE (stage-1 review, binding): wave3c-services.md's "Opus review notes from stage 1"
// explicitly assigns `offerRescheduleForOverdueTasks` to this file — "it already owns the
// scheduler's settings surface." That phrase is realized literally here: this class implements
// `Volar.Reminders.IReminderSettingsProvider`, the exact seam `ReminderScheduler` reads
// `CurrentVoiceDeliveryMode`/`CurrentGlobalReminderPolicy` through (`IReminderSettingsProvider.cs`'s
// own header: Swift reads these two values directly out of `UserDefaults`; this project's
// `ReminderScheduler` is pure/no-I/O, so this interface is its injection seam instead). C5 must
// register this class as the `IReminderSettingsProvider` implementation `ReminderScheduler` is
// constructed with, replacing `DefaultReminderSettingsProvider` — see this task's final report,
// "handoff."
//
// NOT IN SCOPE (flagged, not silently invented): `reminderBanner`/`showReminderPreview()`/
// `dismissBanner()` (§1.5 rows 29/33/34, `AppState.swift:1787-1805`) are NOT ported here. The
// frozen wave3c-services.md text for cluster G lists exactly "voice-delivery mode, global reminder
// policy, the scheduler's settings surface, plus OfferRescheduleForOverdueTasks" — it does not
// mention the banner. `showReminderPreview()`'s own logic is a two-line read of
// `ITaskListService.ActiveTask` (already a public, frozen-interface property) with a hardcoded
// fallback string; Wave 4's shell/ViewModel can inline that directly, the same way Opus's stage-1
// review already routed the `detailTask`/`detailTaskID`/`openDetail`/`closeDetail` trio there for
// being "pure UI selection state." Recommended for Wave 4, not silently dropped.
using System.Text.Json;
using Volar.Domain;
using Volar.Reminders;

namespace Volar.App.Services.State;

public sealed class ReminderAndDeliverySettingsService : IReminderSettingsProvider
{
    /// <summary>`AppState.voiceDeliveryModeKey` (`AppState.swift:374`) — `static` (not `private`) in
    /// the Swift original as a deliberate sibling-read seam; this port's equivalent seam is
    /// <see cref="IReminderSettingsProvider"/> itself; the raw string key is kept public anyway for
    /// parity/diagnostics.</summary>
    public const string VoiceDeliveryModeKey = "volar.voiceDeliveryMode";

    /// <summary>`AppState.globalReminderPolicyKey` (`AppState.swift:377`).</summary>
    public const string GlobalReminderPolicyKey = "volar.globalReminderPolicy";

    private readonly ISettingsStore _settings;
    private readonly ITaskListService _taskList;
    private readonly ReminderScheduler? _scheduler;
    private VoiceDeliveryMode _voiceDeliveryMode;
    private ReminderPolicy _globalReminderPolicy;

    /// <param name="scheduler">Nullable — mirrors every other `scheduler?.` call site in this
    /// codebase (Swift's own `scheduler: ReminderScheduler?` is `nil` when there is no store).
    /// <see cref="OfferRescheduleForOverdueTasks"/> degrades to a no-op without one.</param>
    public ReminderAndDeliverySettingsService(
        ISettingsStore settings,
        ITaskListService taskList,
        ReminderScheduler? scheduler = null)
    {
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _taskList = taskList ?? throw new ArgumentNullException(nameof(taskList));
        _scheduler = scheduler;

        // Mirrors AppState.init's load-back (`AppState.swift:439-447`): persisted choice wins, the
        // library default is only the fallback for a fresh install / first read.
        _voiceDeliveryMode = ParseVoiceDeliveryMode(_settings.GetString(VoiceDeliveryModeKey))
            ?? VoiceDeliveryMode.VisualPlusVoice;
        _globalReminderPolicy = LoadGlobalReminderPolicy(_settings.GetString(GlobalReminderPolicyKey))
            ?? ReminderPolicy.DefaultPolicy;
    }

    // MARK: - IReminderSettingsProvider (the seam ReminderScheduler actually reads)

    public VoiceDeliveryMode CurrentVoiceDeliveryMode => _voiceDeliveryMode;

    public ReminderPolicy CurrentGlobalReminderPolicy => _globalReminderPolicy;

    // MARK: - Settings surface (SettingsView bindings)

    /// <summary>Convenience alias so a Settings UI can bind/read without depending on the
    /// <see cref="IReminderSettingsProvider"/> interface name — same value as
    /// <see cref="CurrentVoiceDeliveryMode"/>.</summary>
    public VoiceDeliveryMode VoiceDeliveryMode => _voiceDeliveryMode;

    public ReminderPolicy GlobalReminderPolicy => _globalReminderPolicy;

    /// <summary>Mirrors `setVoiceDeliveryMode(_:)` (`AppState.swift:2134-2137`).</summary>
    public void SetVoiceDeliveryMode(VoiceDeliveryMode mode)
    {
        _voiceDeliveryMode = mode;
        _settings.SetString(VoiceDeliveryModeKey, RawVoiceDeliveryMode(mode));
    }

    /// <summary>Mirrors `setGlobalReminderPolicy(_:)` (`AppState.swift:2140-2144`).</summary>
    public void SetGlobalReminderPolicy(ReminderPolicy policy)
    {
        _globalReminderPolicy = policy;
        _settings.SetString(GlobalReminderPolicyKey, EncodeGlobalReminderPolicy(policy));
    }

    // MARK: - FR-016 overdue-reschedule scan (assigned here by the stage-1 review)

    /// <summary>
    /// Mirrors `offerRescheduleForOverdueTasks(now:)` (`AppState.swift:2210-2220`): for every open
    /// task past its deadline with no already-outstanding resurface/reschedule record, offers one
    /// reschedule nudge. Deduped against `ReminderScheduler.RecordsForTask` so a re-run of this scan
    /// (e.g. a second `activateServices()`-equivalent call) never piles up a second offer on top of
    /// one the user hasn't acted on yet — exactly the Swift original's own dedupe rule
    /// (`offsetKind == "resurface" && state != "satisfied"`).
    /// </summary>
    public void OfferRescheduleForOverdueTasks(DateTimeOffset now)
    {
        if (_scheduler is null)
        {
            return;
        }
        foreach (var task in _taskList.OpenTasks)
        {
            if (task.Deadline is not DateTimeOffset deadline || deadline >= now)
            {
                continue;
            }
            var alreadyOutstanding = false;
            foreach (var record in _scheduler.RecordsForTask(task.Id))
            {
                if (record.OffsetKind == "resurface" && record.State != "satisfied")
                {
                    alreadyOutstanding = true;
                    break;
                }
            }
            if (alreadyOutstanding)
            {
                continue;
            }
            _scheduler.OfferReschedule(task.Id, now);
        }
    }

    // MARK: - Raw-value round trip (mirrors VoiceDeliveryMode's Swift rawValue strings exactly)

    private static string RawVoiceDeliveryMode(VoiceDeliveryMode mode) => mode switch
    {
        VoiceDeliveryMode.VisualOnly => "visualOnly",
        VoiceDeliveryMode.VoiceOnly => "voiceOnly",
        _ => "visualPlusVoice",
    };

    private static VoiceDeliveryMode? ParseVoiceDeliveryMode(string? raw) => raw switch
    {
        "visualOnly" => VoiceDeliveryMode.VisualOnly,
        "visualPlusVoice" => VoiceDeliveryMode.VisualPlusVoice,
        "voiceOnly" => VoiceDeliveryMode.VoiceOnly,
        _ => null, // absent/garbage -> caller falls back to the library default, never throws.
    };

    // MARK: - ReminderPolicy JSON round trip
    //
    // A hand-written DTO rather than `JsonSerializer.Serialize<ReminderPolicy>` directly — same
    // rationale as FileDelegationMetaStore.cs's own DTO (Adapters/FileDelegationMetaStore.cs):
    // ReminderPolicy is a `readonly record struct` carrying a `TimeSpan?`, and this keeps the wire
    // format explicit and stable rather than depending on System.Text.Json's exact
    // constructor-matching/TimeSpan-converter behavior across framework versions. There is no
    // cross-platform settings file to stay wire-compatible with (fresh Windows install, no
    // migration in scope — mirrors SpeechEngineChoiceStore.cs's identical framing), so this format
    // only ever needs to round-trip against itself.

    private sealed class ReminderPolicyDto
    {
        public double[] OffsetSeconds { get; set; } = Array.Empty<double>();
        public double? RepeatEverySeconds { get; set; }
    }

    private static string EncodeGlobalReminderPolicy(ReminderPolicy policy)
    {
        var offsets = new double[policy.Offsets.Count];
        for (var i = 0; i < policy.Offsets.Count; i++)
        {
            offsets[i] = policy.Offsets[i].TotalSeconds;
        }
        var dto = new ReminderPolicyDto
        {
            OffsetSeconds = offsets,
            RepeatEverySeconds = policy.RepeatEvery?.TotalSeconds,
        };
        return JsonSerializer.Serialize(dto);
    }

    /// <summary>Corrupt/unreadable/absent JSON degrades to <see langword="null"/> (caller falls back
    /// to <see cref="ReminderPolicy.DefaultPolicy"/>) — never throws, matching this codebase's
    /// established "corrupt persisted state never crashes a read path" convention.</summary>
    private static ReminderPolicy? LoadGlobalReminderPolicy(string? raw)
    {
        if (string.IsNullOrEmpty(raw))
        {
            return null;
        }
        try
        {
            var dto = JsonSerializer.Deserialize<ReminderPolicyDto>(raw);
            if (dto is null)
            {
                return null;
            }
            var offsets = new TimeSpan[dto.OffsetSeconds.Length];
            for (var i = 0; i < dto.OffsetSeconds.Length; i++)
            {
                offsets[i] = TimeSpan.FromSeconds(dto.OffsetSeconds[i]);
            }
            var repeatEvery = dto.RepeatEverySeconds is double seconds
                ? TimeSpan.FromSeconds(seconds)
                : (TimeSpan?)null;
            return new ReminderPolicy(offsets, repeatEvery);
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
