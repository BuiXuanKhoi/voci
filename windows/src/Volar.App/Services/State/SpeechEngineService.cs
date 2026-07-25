// Services/State/SpeechEngineService.cs — Wave 3-C stage 2, agent C3. Inventory cluster F (the
// freemium speech-tier picker), ported from AppState.swift's `selectedEngine` (674-680) and
// `setSpeechEngine(_:)` (852-858) only.
//
// WINDOWS DELTA (deliberate, not a placeholder — see appstate-inventory.md §7 and
// Volar.Speech.SpeechEngineChoice's own "PARITY NOTE"): Swift's cluster F has THREE engines
// (`speech` = Apple on-device streaming, `whisper` = WhisperKit, `groq` = cloud) plus a pile of
// Apple-Speech-framework-only surface: `allowServerRecognition`/`recognitionLocaleID`/
// `pendingServerConsent`/`useServerRecognition()`/`setRecognitionLocale(_:)`/
// `openDictationSettings()`. None of that has a Windows analog — there is no OS-level streaming
// STT framework this port targets, both Windows engines auto-detect language (no locale setting),
// and neither needs a "fall back to Apple's servers" consent prompt. This file therefore ports
// ONLY the two members that survive the platform cut: which engine is selected, and persisting the
// user's choice. Everything else in cluster F is dropped, not stubbed — see this wave's final
// report, self-review "parity".
//
// Batch-only (decision 8): both engines this service ever returns have
// `ISpeechEngine.SupportsPartialResults == false` — there is no live-caption path to wire here.
using Volar.Domain;
using Volar.Speech;
using Volar.Speech.Groq;
using Volar.Speech.Whisper;

namespace Volar.App.Services.State;

/// <summary>
/// Narrow read surface <see cref="Services.State.CaptureFlowService"/> depends on instead of the
/// concrete <see cref="SpeechEngineService"/> class, so capture-flow tests can substitute a fake
/// engine-selection policy without constructing a real <see cref="WhisperNetEngine"/>/
/// <see cref="GroqEngine"/> pair (which in turn need a model directory / HTTP credential plumbing
/// that has nothing to do with what <c>CaptureFlowService</c> itself is testing).
/// </summary>
public interface ISpeechEngineProvider
{
    /// <summary>Whichever engine the NEXT capture should route to, per the current
    /// <see cref="SpeechEngineChoice"/> and (for <see cref="SpeechEngineChoice.GroqCloud"/>)
    /// whether a credential is actually configured. Recomputed on every read — never cached —
    /// mirroring every other read-through property in this wave (decision 5's spirit extended to
    /// this cluster: nothing here is a second source of truth for engine READINESS, only for the
    /// user's persisted CHOICE).</summary>
    ISpeechEngine SelectedEngine { get; }
}

/// <summary>
/// Cluster F: the two-tier (free on-device / paid cloud) speech-engine picker. Owns
/// <see cref="Choice"/> (persisted via <see cref="Adapters.SpeechEngineChoiceStore"/>, matching the
/// wave contract's explicit ask) and the fallback policy <see cref="SelectedEngine"/> implements.
/// </summary>
/// <remarks>
/// Depends on the CONCRETE <see cref="WhisperNetEngine"/> (not the bare <see cref="ISpeechEngine"/>
/// interface) specifically so this service can eagerly call <see cref="WhisperNetEngine.PrepareAsync"/>
/// — mirrors Swift's `setSpeechEngine`/`activateServices` firing `Task { await whisper.prepare() }`.
/// <see cref="GroqEngine"/> is likewise concrete because <see cref="GroqEngine.IsConfigured"/> is not
/// part of the shared <see cref="ISpeechEngine"/> contract (by design — see that property's own
/// remarks in GroqEngine.cs). Both types are still perfectly unit-testable on their own (each takes
/// an injectable <c>IAudioCaptureService</c>/credential-provider seam, per their file headers), so
/// this is not a testability regression — it just means this service's own tests construct real
/// engine instances wired to fakes at the leaf, rather than faking <c>ISpeechEngineProvider</c>
/// itself (that fake lives in <c>CaptureFlowService</c>'s tests instead, where it belongs).
/// </remarks>
public sealed class SpeechEngineService : ISpeechEngineProvider
{
    private readonly WhisperNetEngine _whisper;
    private readonly GroqEngine _groq;
    private readonly ISettingsStore _settings;
    private SpeechEngineChoice _choice;

    public SpeechEngineService(WhisperNetEngine whisper, GroqEngine groq, ISettingsStore settings)
    {
        _whisper = whisper ?? throw new ArgumentNullException(nameof(whisper));
        _groq = groq ?? throw new ArgumentNullException(nameof(groq));
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _choice = Adapters.SpeechEngineChoiceStore.Get(settings);
    }

    /// <summary>The user's persisted preference. Read once at construction, then held in memory and
    /// re-persisted on every <see cref="SetChoice"/> call — mirrors every other `private(set)`
    /// stored-and-persisted property elsewhere in this port (e.g. `TaskListService`'s pattern is
    /// read-through-a-collaborator; this one has no collaborator to read through, so it is genuinely
    /// this service's own state, matching Swift's `speechEngineChoice` being a plain stored
    /// property).</summary>
    public SpeechEngineChoice Choice => _choice;

    /// <summary>Port of `setSpeechEngine(_:)`. Persists the choice, then fires the SAME eager-prepare
    /// side effect Swift's setter does — except Windows must prepare Whisper whenever it is (or
    /// might become, via the Groq-unconfigured fallback) the engine <see cref="SelectedEngine"/>
    /// would actually pick next, not only when the user explicitly picks the on-device tier (Swift's
    /// `.whisperKit` is opt-in; Windows' `WhisperOnDevice` is the default AND the universal
    /// fallback, so it needs to be ready far more often) — see <see cref="PrepareIfNeededAsync"/>.
    /// </summary>
    public void SetChoice(SpeechEngineChoice choice)
    {
        _choice = choice;
        Adapters.SpeechEngineChoiceStore.Set(_settings, choice);
        // Fire-and-forget by design (mirrors Swift's detached `_Concurrency.Task { await
        // whisper.prepare() }`): the caller (a Settings picker, or C5's startup call) must not block
        // on a first-run model download. WhisperNetEngine.PrepareAsync already swallows every
        // failure into its own `EngineState.Failed` (see that method's doc comment) — nothing here
        // can turn into an unobserved-task-exception crash.
        _ = PrepareIfNeededAsync();
    }

    /// <summary>Eagerly loads the Whisper.net model when <see cref="SelectedEngine"/> would resolve
    /// to it right now — call once at app startup (mirrors Swift's `activateServices()` conditional
    /// prepare) and again from <see cref="SetChoice"/> whenever the effective engine could have
    /// changed. A no-op (immediately-completed <see cref="Task"/>) when Groq is both selected and
    /// configured, since <see cref="GroqEngine"/> has no "prepare" step at all — it only needs
    /// credentials, checked lazily per-request.</summary>
    public Task PrepareIfNeededAsync(CancellationToken cancellationToken = default) =>
        SelectedEngine is WhisperNetEngine whisper
            ? whisper.PrepareAsync(cancellationToken: cancellationToken)
            : Task.CompletedTask;

    /// <inheritdoc/>
    /// <remarks>
    /// Port of `AppState.selectedEngine` (674-680), collapsed from Swift's three-way switch to
    /// Windows' two engines: <see cref="SpeechEngineChoice.GroqCloud"/> only actually returns
    /// <see cref="GroqEngine"/> when <see cref="GroqEngine.IsConfigured"/> is <see langword="true"/>;
    /// otherwise (and for every other choice) it falls back to <see cref="WhisperNetEngine"/> — the
    /// SAME "choosing cloud before a key exists degrades quietly to on-device instead of
    /// hard-erroring at upload time" contract Wave 3-B established for parsing and this wave's brief
    /// explicitly reasserts as an acceptance criterion for speech. Unlike Swift, there is no
    /// `isModelReady`-style gate on the Whisper branch: Whisper.net is this port's UNIVERSAL floor
    /// (every other tier falls back to it), so gating it on its own readiness would risk returning
    /// no usable engine at all when the model simply hasn't finished downloading yet — instead an
    /// unprepared <see cref="WhisperNetEngine"/> surfaces a clear <see cref="ISpeechEngine.OnError"/>
    /// ("model is not loaded yet") the moment <see cref="ISpeechEngine.Stop"/> is called, which
    /// <see cref="CaptureFlowService"/> already has a general error-handling path for.
    /// </remarks>
    public ISpeechEngine SelectedEngine => _choice switch
    {
        SpeechEngineChoice.GroqCloud => _groq.IsConfigured ? _groq : _whisper,
        _ => _whisper,
    };
}
