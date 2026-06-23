import Foundation
import AVFoundation

/// A gentle, synthesized "dialing" loop played while a call is ringing the other side — no audio
/// asset needed. Stops the moment the call connects (or ends). Works for 1:1 and group dialing.
@MainActor
final class CallTones {
    static let shared = CallTones()
    private var player: AVAudioPlayer?

    func startRingback() {
        guard player == nil, let data = Self.ringbackWAV() else { return }
        player = try? AVAudioPlayer(data: data)
        player?.numberOfLoops = -1
        player?.volume = 0.45
        player?.prepareToPlay()
        player?.play()
    }

    /// A more insistent looping "incoming call" ringtone, used on Mac (no CallKit system ring).
    /// Distinct cadence from the dialing ringback so the two are never confused.
    func startRingtone() {
        guard player == nil, let data = Self.ringtoneWAV() else { return }
        player = try? AVAudioPlayer(data: data)
        player?.numberOfLoops = -1
        player?.volume = 0.7
        player?.prepareToPlay()
        player?.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }

    /// Synthesize a warm, looping two-note arpeggio (a friendlier take on a ringback cadence),
    /// rendered to an in-memory 16-bit PCM WAV so AVAudioPlayer can loop it seamlessly.
    private static func ringbackWAV() -> Data? {
        let sampleRate = 44_100.0
        let beat = 0.5                  // seconds per note
        let notes: [Double] = [523.25, 659.25, 783.99, 659.25]   // C5 E5 G5 E5 — a gentle major arp
        let gap = 1.0                   // silence after the phrase, so it feels like "ringing"
        let phrase = Double(notes.count) * beat
        let total = phrase + gap
        let frameCount = Int(total * sampleRate)
        var samples = [Int16](repeating: 0, count: frameCount)

        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            guard t < phrase else { continue }   // gap = silence
            let noteIdx = min(notes.count - 1, Int(t / beat))
            let local = t - Double(noteIdx) * beat
            let freq = notes[noteIdx]
            // Soft attack/decay envelope per note so it's pleasant, not harsh.
            let env = sin(Double.pi * (local / beat))
            let value = sin(2 * Double.pi * freq * t) * env * 0.35
            samples[i] = Int16(max(-1, min(1, value)) * Double(Int16.max))
        }

        return wav(samples, sampleRate: Int(sampleRate))
    }

    /// Synthesize a brighter, more urgent two-tone "ring-ring" burst followed by a pause, looped —
    /// reads as an incoming call rather than a gentle dialing tone.
    private static func ringtoneWAV() -> Data? {
        let sampleRate = 44_100.0
        let ring = 0.4                  // seconds per ring burst
        let innerGap = 0.2              // short gap between the two bursts of a "ring-ring"
        let trailGap = 1.8              // long silence after the pair, the classic ring cadence
        let freqs: [Double] = [880.0, 660.0]   // alternating two-tone within each burst
        let total = ring + innerGap + ring + trailGap
        let frameCount = Int(total * sampleRate)
        var samples = [Int16](repeating: 0, count: frameCount)

        func renderBurst(start: Double) {
            let s = Int(start * sampleRate)
            let e = Int((start + ring) * sampleRate)
            for i in s..<min(e, frameCount) {
                let t = Double(i) / sampleRate
                let local = t - start
                // Alternate the two tones a few times per burst for the warble.
                let freq = freqs[Int(local * 12) % freqs.count]
                let env = sin(Double.pi * (local / ring))
                let value = sin(2 * Double.pi * freq * t) * env * 0.5
                samples[i] = Int16(max(-1, min(1, value)) * Double(Int16.max))
            }
        }
        renderBurst(start: 0)
        renderBurst(start: ring + innerGap)

        return wav(samples, sampleRate: Int(sampleRate))
    }

    private static func wav(_ samples: [Int16], sampleRate: Int) -> Data {
        var d = Data()
        let byteRate = sampleRate * 2
        let dataSize = samples.count * 2
        func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func u16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        d.append("RIFF".data(using: .ascii)!); d.append(u32(36 + dataSize)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); d.append(u32(16)); d.append(u16(1)); d.append(u16(1))
        d.append(u32(sampleRate)); d.append(u32(byteRate)); d.append(u16(2)); d.append(u16(16))
        d.append("data".data(using: .ascii)!); d.append(u32(dataSize))
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
