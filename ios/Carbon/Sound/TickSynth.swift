// Synthesized ticks, no audio files. They route to the glasses speakers over
// Bluetooth A2DP and mix with other audio (M0 U7).

import AVFoundation

final class TickSynth {
    enum Sound {
        case start   // single high tick, about 2 kHz, 25 ms
        case done    // double lower tick, about 1.2 kHz, 2 × 30 ms with a 60 ms gap
        case error   // soft low buzz, about 180 Hz, 120 ms, quieter
    }

    var isEnabled = true

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [Sound: AVAudioPCMBuffer] = [:]
    private var isReady = false

    func play(_ sound: Sound) {
        guard isEnabled else { return }
        do {
            try prepareIfNeeded()
            guard let buffer = buffers[sound] else { return }
            player.scheduleBuffer(buffer, at: nil)
            player.play()
        } catch {
            // Sound is decoration; a failed tick must never affect a scan.
        }
    }

    private func prepareIfNeeded() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        if !isReady {
            buffers = [
                .start: render([(2_000, 0.025)], gap: 0, peak: 0.126),
                .done: render([(1_200, 0.030), (1_200, 0.030)], gap: 0.060, peak: 0.126),
                .error: render([(180, 0.120)], gap: 0, peak: 0.063),
            ]
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            isReady = true
        }
        if !engine.isRunning {
            try engine.start()
        }
    }

    /// Sine tones with a fast exponential decay (no click at the end). Peak 0.126 is about -18 dBFS.
    private func render(_ tones: [(frequency: Double, duration: Double)], gap: Double, peak: Float) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let total = tones.reduce(0) { $0 + $1.duration } + gap * Double(max(tones.count - 1, 0))
        let frames = AVAudioFrameCount(total * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { samples[i] = 0 }

        var offset = 0
        for tone in tones {
            let count = Int(tone.duration * rate)
            for i in 0..<count where offset + i < Int(frames) {
                let t = Double(i) / rate
                let envelope = exp(-t * 6 / tone.duration)
                samples[offset + i] = peak * Float(envelope * sin(2 * .pi * tone.frequency * t))
            }
            offset += count + Int(gap * rate)
        }
        return buffer
    }
}
