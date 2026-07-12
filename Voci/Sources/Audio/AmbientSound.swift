// Sources/Audio/AmbientSound.swift — synthesized ambient sound loop (rain/snow/embers)
import AVFoundation

/// Synthesized ambient sound player — mirrors `useAmbientSound` in `voci-ambient.jsx`: a
/// 2-second looped noise buffer (white noise for rain, a leaky-integrator "brown-ish" noise for
/// snow/embers) routed through a low-pass filter, with a short fade-in gain ramp instead of an
/// instant on/off. No audio assets are shipped — the buffer is synthesized in memory.
@MainActor
final class AmbientSound {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let filter = AVAudioUnitEQ(numberOfBands: 1)
    private let mixer = AVAudioMixerNode()

    private var fadeTask: Task<Void, Never>?
    private(set) var isPlaying = false

    init() {
        filter.bands[0].filterType = .lowPass
        filter.bands[0].bypass = false
    }

    /// `useAmbientSound().toggle(mode)`.
    func toggle(_ mode: AmbientMode) {
        if isPlaying {
            stop()
        } else {
            start(mode)
        }
    }

    /// `useAmbientSound().start(mode)` — mirrors the JS `start()`, which always tears down any
    /// existing audio graph first. No-ops for `.none`/`.custom` (there is no ambient *sound* for
    /// those visual modes in the prototype). Degrades silently (no throw, no crash) if the audio
    /// engine can't start — e.g. no output device, or the sandbox denies audio.
    func start(_ mode: AmbientMode) {
        stop()
        guard mode == .rain || mode == .snow || mode == .embers else { return }
        guard let buffer = makeNoiseBuffer(for: mode) else { return }

        let format = buffer.format
        engine.attach(player)
        engine.attach(filter)
        engine.attach(mixer)
        mixer.outputVolume = 0

        engine.connect(player, to: filter, format: format)
        engine.connect(filter, to: mixer, format: format)
        engine.connect(mixer, to: engine.mainMixerNode, format: format)

        filter.bands[0].frequency = lowPassFrequency(for: mode)

        do {
            try engine.start()
        } catch {
            // Audio unavailable — degrade silently, matching the JS `try { … } catch (e) {}`.
            teardownGraph()
            return
        }

        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        isPlaying = true
        rampVolume(to: targetVolume(for: mode))
    }

    /// `useAmbientSound().stop()`.
    func stop() {
        fadeTask?.cancel()
        fadeTask = nil
        player.stop()
        engine.stop()
        teardownGraph()
        isPlaying = false
    }

    private func teardownGraph() {
        if engine.attachedNodes.contains(player) { engine.detach(player) }
        if engine.attachedNodes.contains(filter) { engine.detach(filter) }
        if engine.attachedNodes.contains(mixer) { engine.detach(mixer) }
    }

    // MARK: - Buffer synthesis

    /// White noise for rain (`w * 0.5`); a one-pole leaky integrator for snow/embers
    /// (`last = (last + 0.02*w) / 1.02; last * 3.5`) — the same running-average shape the JS
    /// prototype uses to fake a low, brown-ish rumble before the low-pass filter smooths it further.
    private func makeNoiseBuffer(for mode: AmbientMode) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else { return nil }
        let frameCount = AVAudioFrameCount(2 * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount

        var last: Float = 0
        for i in 0..<Int(frameCount) {
            let w = Float.random(in: -1...1)
            last = (last + 0.02 * w) / 1.02
            data[i] = mode == .rain ? w * 0.5 : last * 3.5
        }
        return buffer
    }

    private func lowPassFrequency(for mode: AmbientMode) -> Float {
        switch mode {
        case .rain: return 1500
        case .snow: return 420
        default: return 300 // embers (only reachable modes here are rain/snow/embers)
        }
    }

    private func targetVolume(for mode: AmbientMode) -> Float {
        mode == .rain ? 0.10 : 0.13
    }

    /// Linear fade-in over ~1.4s — `AVAudioEngine` has no built-in parameter-ramp API like Web
    /// Audio's `linearRampToValueAtTime`, so this steps `mixer.outputVolume` on a `MainActor` task.
    private func rampVolume(to target: Float, duration: TimeInterval = 1.4, steps: Int = 28) {
        fadeTask?.cancel()
        fadeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stepNanos = UInt64((duration / Double(steps)) * 1_000_000_000)
            for step in 1...steps {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: stepNanos)
                if Task.isCancelled { return }
                self.mixer.outputVolume = target * Float(step) / Float(steps)
            }
        }
    }
}
