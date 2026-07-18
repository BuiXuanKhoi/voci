// Ambient/AmbientSoundPlayer.cs — ported from Sources/Audio/AmbientSound.swift (131 lines).
//
// Synthesized ambient sound player: a 2-second looped noise buffer (white noise for rain, a
// leaky-integrator "brown-ish" noise for snow/embers) routed through a low-pass filter, with a
// linear fade-in instead of an instant on/off. No audio assets are shipped — the buffer is
// synthesized in memory, exactly like the mac original (`AVAudioPCMBuffer` built in code, no
// bundled sound files).
//
// ## Graph mapping (mac AVAudioEngine -> Windows NAudio)
// mac: AVAudioPlayerNode (loops a pre-rendered 2s buffer) -> AVAudioUnitEQ (low-pass) ->
//      AVAudioMixerNode (fade-in via `outputVolume`) -> mainMixerNode -> output.
// Windows: LoopingNoiseSampleProvider (loops a pre-rendered 2s buffer, same synthesis formula) ->
//      LowPassSampleProvider (wraps NAudio.Dsp.BiQuadFilter.LowPassFilter, sample-by-sample) ->
//      RampedVolumeSampleProvider (fade-in via a `Task`-driven step ramp, mirrors the Swift
//      original's own `Task`-based `rampVolume` almost line-for-line) -> SampleToWaveProvider ->
//      WaveOutEvent. Same 4-stage pipeline shape as the mac graph, one NAudio primitive per
//      AVFoundation node.
using NAudio.Dsp;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Volar.Speech.Ambient;

public sealed class AmbientSoundPlayer : IDisposable
{
    private const int SampleRate = 44_100;
    private const int BufferSeconds = 2;

    private WaveOutEvent? _output;
    private RampedVolumeSampleProvider? _volumeStage;
    private CancellationTokenSource? _fadeCts;

    public bool IsPlaying { get; private set; }

    /// <summary>`useAmbientSound().toggle(mode)`.</summary>
    public void Toggle(AmbientMode mode)
    {
        if (IsPlaying) Stop(); else Start(mode);
    }

    /// <summary>`useAmbientSound().start(mode)` — always tears down any existing audio graph first,
    /// exactly like the mac original. No-ops for <see cref="AmbientMode.None"/>. Degrades silently
    /// (no throw) if the output device can't be opened — matches the Swift `try { … } catch (e) {}`
    /// fallback in the JS-ported comment.</summary>
    public void Start(AmbientMode mode)
    {
        Stop();
        if (mode is not (AmbientMode.Rain or AmbientMode.Snow or AmbientMode.Embers or AmbientMode.Custom))
        {
            return;
        }

        var noiseBuffer = MakeNoiseBuffer(mode);
        var loop = new LoopingNoiseSampleProvider(noiseBuffer, SampleRate);
        var filter = BiQuadFilter.LowPassFilter(SampleRate, LowPassFrequency(mode), q: 1.0f);
        var filtered = new LowPassSampleProvider(loop, filter);
        var volumeStage = new RampedVolumeSampleProvider(filtered);

        var output = new WaveOutEvent();
        try
        {
            output.Init(new SampleToWaveProvider(volumeStage));
            output.Play();
        }
        catch
        {
            // No usable output device / driver rejected the format — degrade silently, matching
            // the Swift `catch (e) {}` fallback in AmbientSound.start(_:).
            output.Dispose();
            return;
        }

        _output = output;
        _volumeStage = volumeStage;
        IsPlaying = true;

        _fadeCts = new CancellationTokenSource();
        _ = volumeStage.RampToAsync(TargetVolume(mode), TimeSpan.FromSeconds(1.4), steps: 28, _fadeCts.Token);
    }

    /// <summary>`useAmbientSound().stop()`.</summary>
    public void Stop()
    {
        _fadeCts?.Cancel();
        _fadeCts?.Dispose();
        _fadeCts = null;

        _output?.Stop();
        _output?.Dispose();
        _output = null;
        _volumeStage = null;
        IsPlaying = false;
    }

    public void Dispose() => Stop();

    // MARK: - Buffer synthesis (mirrors AmbientSound.makeNoiseBuffer exactly)

    /// <summary>White noise for rain (<c>w * 0.5</c>); a one-pole leaky integrator for snow/embers
    /// (<c>last = (last + 0.02*w) / 1.02; last * 3.5</c>) — the same running-average shape the mac
    /// original uses to fake a low, brown-ish rumble before the low-pass filter smooths it
    /// further. A fixed pre-rendered <see cref="BufferSeconds"/>-long buffer, looped indefinitely —
    /// same approach as the mac original's `scheduleBuffer(buffer, at: nil, options: .loops)`
    /// rather than generating noise continuously, so this port has the same (inaudible-in-practice
    /// at 2s) periodicity the mac version has.</summary>
    private static float[] MakeNoiseBuffer(AmbientMode mode)
    {
        var frameCount = SampleRate * BufferSeconds;
        var data = new float[frameCount];
        var random = Random.Shared;
        float last = 0;
        var isRainLike = mode is AmbientMode.Rain or AmbientMode.Custom;
        for (var i = 0; i < frameCount; i++)
        {
            var w = (float)(random.NextDouble() * 2.0 - 1.0);
            last = (last + 0.02f * w) / 1.02f;
            data[i] = isRainLike ? w * 0.5f : last * 3.5f;
        }
        return data;
    }

    private static float LowPassFrequency(AmbientMode mode) => mode switch
    {
        AmbientMode.Rain or AmbientMode.Custom => 1500f,
        AmbientMode.Snow => 420f,
        _ => 300f, // embers (the only other reachable mode here)
    };

    private static float TargetVolume(AmbientMode mode) =>
        mode is AmbientMode.Rain or AmbientMode.Custom ? 0.10f : 0.13f;

    /// <summary>Loops a pre-rendered mono float buffer indefinitely — the NAudio analog of
    /// `AVAudioPlayerNode.scheduleBuffer(_:at:options: .loops)`.</summary>
    private sealed class LoopingNoiseSampleProvider(float[] buffer, int sampleRate) : ISampleProvider
    {
        private int _position;

        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(sampleRate, 1);

        public int Read(float[] destination, int offset, int count)
        {
            for (var i = 0; i < count; i++)
            {
                destination[offset + i] = buffer[_position];
                _position = (_position + 1) % buffer.Length;
            }
            return count; // an infinite loop always fills the whole request, unlike a finite source
        }
    }

    /// <summary>Applies a <see cref="BiQuadFilter"/> sample-by-sample — the NAudio analog of
    /// `AVAudioUnitEQ` with one low-pass band.</summary>
    private sealed class LowPassSampleProvider(ISampleProvider source, BiQuadFilter filter) : ISampleProvider
    {
        public WaveFormat WaveFormat => source.WaveFormat;

        public int Read(float[] buffer, int offset, int count)
        {
            var read = source.Read(buffer, offset, count);
            for (var i = 0; i < read; i++)
            {
                buffer[offset + i] = filter.Transform(buffer[offset + i]);
            }
            return read;
        }
    }

    /// <summary>Multiplies every sample by a volume that ramps over time — the NAudio analog of
    /// `AVAudioMixerNode.outputVolume`, which has no built-in ramp API on either platform, so both
    /// originals (this one and the Swift `rampVolume`) step the value on a timer/task instead of
    /// using a native parameter-automation API.</summary>
    private sealed class RampedVolumeSampleProvider(ISampleProvider source) : ISampleProvider
    {
        private volatile float _volume;

        public WaveFormat WaveFormat => source.WaveFormat;

        public int Read(float[] buffer, int offset, int count)
        {
            var read = source.Read(buffer, offset, count);
            var gain = _volume;
            for (var i = 0; i < read; i++)
            {
                buffer[offset + i] *= gain;
            }
            return read;
        }

        /// <summary>Linear fade over <paramref name="duration"/> in <paramref name="steps"/>
        /// discrete jumps — mirrors `AmbientSound.rampVolume(to:duration:steps:)` (1.4s / 28 steps
        /// by default) almost line-for-line, including cancellation via a token instead of Swift's
        /// `Task.isCancelled` checks.</summary>
        public async Task RampToAsync(float target, TimeSpan duration, int steps, CancellationToken cancellationToken)
        {
            var stepDelay = duration / steps;
            for (var step = 1; step <= steps; step++)
            {
                if (cancellationToken.IsCancellationRequested) return;
                try
                {
                    await Task.Delay(stepDelay, cancellationToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                if (cancellationToken.IsCancellationRequested) return;
                _volume = target * step / steps;
            }
        }
    }
}
