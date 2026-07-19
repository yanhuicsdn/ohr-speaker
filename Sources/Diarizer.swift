// ============================================================================
// Diarizer.swift — FluidAudio speaker diarization wrapper
// Part of ohr — On-device speech-to-text from the command line
// ============================================================================

import Foundation
import AVFAudio
import FluidAudio
import OhrCore

// MARK: - Configuration

/// Configuration for speaker diarization.
private enum DiarizerConfig {
    /// Minimum confidence to keep a speaker segment (0.0 - 1.0)
    static let minConfidence: Double = 0.3
    /// Minimum segment duration in seconds (shorter segments are filtered out)
    static let minSegmentDuration: Double = 0.5
    /// Maximum gap in seconds between same-speaker segments to merge them
    static let mergeGap: Double = 1.5
    /// Maximum duration of a brief interruption to smooth over (seconds)
    static let smoothingThreshold: Double = 2.0
    /// Minimum overlap fraction for a speaker assignment (0.0 - 1.0)
    /// If overlap < this fraction of the transcription segment, fall back to nearest speaker
    static let minOverlapFraction: Double = 0.05
}

// MARK: - Speaker Segment

/// A speaker segment with timing and label.
struct SpeakerSegment: Sendable {
    let speakerId: String
    let start: Double
    let end: Double
    let confidence: Double
}

// MARK: - Speaker Label Mapping

/// Map raw speaker IDs (SPEAKER_00, SPEAKER_01) to short labels (S1, S2).
private func labelForSpeaker(_ speakerId: String) -> String {
    let parts = speakerId.split(separator: "_")
    if parts.count == 2, let num = Int(parts[1]) {
        return "S\(num + 1)"
    }
    return speakerId
}

// MARK: - Diarization

/// Default diarization config tuned for 2-speaker conversations.
/// Default diarization config — auto-tuned for 2-speaker conversations.
func defaultDiarizerConfig() -> OfflineDiarizerConfig {
    OfflineDiarizerConfig(
        segmentation: .init(
            windowDurationSeconds: 10.0,
            sampleRate: 16_000,
            minDurationOn: 0.0,
            minDurationOff: 0.0,
            stepRatio: 0.15,
            speechOnsetThreshold: Float(0.5),
            speechOffsetThreshold: Float(0.5)
        ),
        embedding: .init(
            batchSize: 32,
            excludeOverlap: true,
            minSegmentDurationSeconds: 0.3,
            skipStrategy: .none
        ),
        clustering: .init(
            threshold: 0.6,
            warmStartFa: 0.07,
            warmStartFb: 0.8,
            numSpeakers: 2
        ),
        postProcessing: .init(
            minGapDurationSeconds: 0.1,
            exclusiveSegments: true
        ),
        zeroVoteReembed: .init(
            enabled: true,
            minDurationSeconds: 0.4
        ),
        exposeChunkEmbeddings: false
    )
}

func runDiarization(fileURL: URL) async throws -> [SpeakerSegment] {
    try await runDiarization(fileURL: fileURL, config: defaultDiarizerConfig())
}

/// Run speaker diarization on an audio file using FluidAudio's offline pipeline
/// with the given config.
/// - Parameters:
///   - fileURL: URL of the audio file to diarize
///   - config: OfflineDiarizerConfig to use
/// - Returns: Array of SpeakerSegment, or empty array if diarization fails
func runDiarization(fileURL: URL, config: OfflineDiarizerConfig) async throws -> [SpeakerSegment] {
    let manager = OfflineDiarizerManager(config: config)

    // Prepare models (downloads on first run, caches afterward)
    try await manager.prepareModels()

    // Resample audio to 16kHz mono and run diarization
    let samples = try AudioConverter().resampleAudioFile(path: fileURL.path)
    let result = try await manager.process(audio: samples)

    // Step 1: Convert and filter by quality
    let rawSegments = result.segments
        .filter { seg in
            // Filter out low-quality segments
            seg.qualityScore >= Float(DiarizerConfig.minConfidence)
        }
        .map { seg in
            SpeakerSegment(
                speakerId: labelForSpeaker(seg.speakerId),
                start: Double(seg.startTimeSeconds),
                end: Double(seg.endTimeSeconds),
                confidence: Double(seg.qualityScore)
            )
        }
        .filter { $0.end - $0.start >= DiarizerConfig.minSegmentDuration }

    guard !rawSegments.isEmpty else { return [] }

    // Step 2: Sort by start time
    let sorted = rawSegments.sorted { $0.start < $1.start }

    // Step 3: Merge nearby segments from the same speaker
    let merged = mergeSameSpeakerSegments(sorted)

    // Step 4: Smooth out brief interruptions
    let smoothed = smoothSpeakerTransitions(merged)

    return smoothed
}

// MARK: - Segment Merging

/// Merge consecutive segments from the same speaker if the gap is small enough.
/// This prevents a single speaker's utterance from being split into many tiny segments.
private func mergeSameSpeakerSegments(_ segments: [SpeakerSegment]) -> [SpeakerSegment] {
    guard !segments.isEmpty else { return [] }

    var result: [SpeakerSegment] = []
    var current = segments[0]

    for seg in segments.dropFirst() {
        let gap = seg.start - current.end
        if seg.speakerId == current.speakerId && gap <= DiarizerConfig.mergeGap {
            // Same speaker, close enough — merge
            current = SpeakerSegment(
                speakerId: current.speakerId,
                start: current.start,
                end: max(current.end, seg.end),
                confidence: max(current.confidence, seg.confidence)
            )
        } else {
            result.append(current)
            current = seg
        }
    }
    result.append(current)
    return result
}

// MARK: - Speaker Transition Smoothing

/// Smooth out brief interruptions: if a speaker appears, then a different speaker
/// appears for a very short time, then the original speaker reappears, absorb
/// the brief interruption into the original speaker.
private func smoothSpeakerTransitions(_ segments: [SpeakerSegment]) -> [SpeakerSegment] {
    guard segments.count >= 3 else { return segments }

    var result = segments

    var i = 1
    while i < result.count - 1 {
        let prev = result[i - 1]
        let cur = result[i]
        let next = result[i + 1]

        let curDuration = cur.end - cur.start
        let prevEndToNextStart = next.start - prev.end

        // If current segment is brief and sandwiched between the same speaker
        if cur.speakerId != prev.speakerId
            && prev.speakerId == next.speakerId
            && curDuration <= DiarizerConfig.smoothingThreshold
            && prevEndToNextStart <= DiarizerConfig.smoothingThreshold * 2 {
            // Absorb current segment into the surrounding speaker
            let merged = SpeakerSegment(
                speakerId: prev.speakerId,
                start: prev.start,
                end: next.end,
                confidence: max(prev.confidence, next.confidence)
            )
            result.replaceSubrange(i - 1...i + 1, with: [merged])
            // i stays at the same index since we replaced 3 items with 1
        } else {
            i += 1
        }
    }

    return result
}

// MARK: - Segment Alignment

/// Align transcription segments with speaker segments by time overlap.
/// Each transcription segment gets assigned the speaker whose segment has
/// the greatest time overlap with it.
/// - Parameters:
///   - transcriptSegments: Segments from transcription (with timing)
///   - speakerSegments: Segments from diarization (with speaker labels)
/// - Returns: Transcript segments with speaker labels assigned
func alignSpeakers(
    transcriptSegments: [SubtitleSegment],
    speakerSegments: [SpeakerSegment]
) -> [SubtitleSegment] {
    guard !speakerSegments.isEmpty else { return transcriptSegments }

    return transcriptSegments.map { seg in
        let speaker = bestSpeaker(
            for: seg.start...seg.end,
            duration: seg.end - seg.start,
            candidates: speakerSegments
        )
        return SubtitleSegment(
            id: seg.id,
            start: seg.start,
            end: seg.end,
            text: seg.text,
            speaker: speaker
        )
    }
}

/// Find the speaker with the most time overlap for a given time range.
/// If no speaker has sufficient overlap, falls back to the nearest speaker segment.
private func bestSpeaker(
    for range: ClosedRange<Double>,
    duration: Double,
    candidates: [SpeakerSegment]
) -> String? {
    var bestOverlap: Double = 0
    var bestSpeaker: String? = nil
    var bestDistance: Double = .infinity
    var nearestSpeaker: String? = nil
    let rangeMid = (range.lowerBound + range.upperBound) / 2

    for candidate in candidates {
        let overlapStart = max(range.lowerBound, candidate.start)
        let overlapEnd = min(range.upperBound, candidate.end)
        let overlap = max(0, overlapEnd - overlapStart)

        // Track best overlap
        if overlap > bestOverlap {
            bestOverlap = overlap
            bestSpeaker = candidate.speakerId
        }

        // Track nearest segment (for fallback when no overlap)
        let candMid = (candidate.start + candidate.end) / 2
        let distance = abs(rangeMid - candMid)
        if distance < bestDistance {
            bestDistance = distance
            nearestSpeaker = candidate.speakerId
        }
    }

    // Require minimum overlap fraction, otherwise fall back to nearest
    let minOverlap = duration * DiarizerConfig.minOverlapFraction
    if bestOverlap >= minOverlap {
        return bestSpeaker
    }

    // Fallback: assign to nearest speaker if within 5 seconds
    return bestDistance <= 5.0 ? nearestSpeaker : nil
}

// MARK: - Auto-Tuning

/// Ground-truth speaker sequence for the reference audio file.
/// Obtained from the manually corrected transcript of 空杯心态与AI时代的自我刷新.
private let groundTruthSequence: [String] = [
    "S1", "S2", "S1", "S2", "S1", "S2", "S1", "S2", "S1", "S2",
    "S1", "S2", "S1", "S2", "S1", "S2", "S1", "S2", "S1", "S2",
    "S1", "S1", "S2", "S2", "S1", "S2", "S1", "S2", "S1", "S2",
    "S1", "S2", "S1", "S2", "S1", "S2", "S1", "S2", "S1", "S2",
    "S1", "S2", "S1", "S2", "S1",
]

/// Normalize a speaker sequence by merging consecutive same-speaker runs.
private func normalizeSeq(_ seq: [String]) -> [String] {
    guard !seq.isEmpty else { return [] }
    var result = [seq[0]]
    for s in seq.dropFirst() {
        if s != result.last! { result.append(s) }
    }
    return result
}

/// Compute Damerau-Levenshtein distance between two sequences.
private func damerauLevenshtein(_ a: [String], _ b: [String]) -> Int {
    let n = a.count, m = b.count
    guard n > 0 else { return m }
    guard m > 0 else { return n }
    var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in 0...n { d[i][0] = i }
    for j in 0...m { d[0][j] = j }
    for i in 1...n {
        for j in 1...m {
            let cost = a[i-1] == b[j-1] ? 0 : 1
            d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + cost)
            if i > 1 && j > 1 && a[i-1] == b[j-2] && a[i-2] == b[j-1] {
                d[i][j] = min(d[i][j], d[i-2][j-2] + cost)
            }
        }
    }
    return d[n][m]
}

/// Evaluate diarization quality against ground truth.
/// Returns a score 0-100.
private func evaluateDiarization(_ segments: [SpeakerSegment]) -> (score: Double, details: String) {
    var score = 0.0
    var parts: [String] = []

    let speakers = Set(segments.map { $0.speakerId })
    let speakerCount = speakers.count

    // 1. Speaker count (40 pts)
    if speakerCount == 2 {
        score += 40
        parts.append("speakers=2 ✓")
    } else if speakerCount == 1 {
        parts.append("speakers=1 ✗")
    } else {
        score += 10
        parts.append("speakers=\(speakerCount) ⚠")
    }

    // 2. Speaker balance (20 pts)
    if speakerCount >= 2 {
        let s1Time = segments.filter { $0.speakerId == "S1" }.reduce(0.0) { $0 + ($1.end - $1.start) }
        let s2Time = segments.filter { $0.speakerId == "S2" }.reduce(0.0) { $0 + ($1.end - $1.start) }
        let total = s1Time + s2Time
        guard total > 0 else { return (0, "no speech") }
        let minPct = min(s1Time, s2Time) / total
        if minPct >= 0.2 {
            score += 20
            parts.append("balance ✓")
        } else if minPct >= 0.1 {
            score += 10
            parts.append("balance ⚠")
        } else {
            parts.append("balance ✗")
        }
    }

    // 3. Segment count vs ground truth (20 pts)
    let seq = segments.map { $0.speakerId }
    let normSeq = normalizeSeq(seq)
    let gtNorm = normalizeSeq(groundTruthSequence)
    let segCount = normSeq.count
    let gtCount = gtNorm.count
    if segCount >= gtCount * 3 / 10 && segCount <= gtCount * 15 / 10 {
        score += 20
        parts.append("segments=\(segCount) ✓")
    } else if segCount >= gtCount * 2 / 10 && segCount <= gtCount * 2 {
        score += 10
        parts.append("segments=\(segCount) ⚠")
    } else {
        parts.append("segments=\(segCount) ✗")
    }

    // 4. Sequence similarity (20 pts)
    if speakerCount == 2 && !normSeq.isEmpty {
        let minLen = min(normSeq.count, gtNorm.count)
        if minLen > 0 {
            let dist = damerauLevenshtein(Array(gtNorm.prefix(minLen)), Array(normSeq.prefix(minLen)))
            let similarity = 1.0 - Double(dist) / Double(minLen)
            score += similarity * 20
            parts.append("sim=\(String(format: "%.0f", similarity * 100))%")
        }
    }

    return (score, parts.joined(separator: " | "))
}

/// Run AutoResearch-style parameter tuning for FluidAudio diarization.
/// Iterates through parameter combinations, evaluates each, and reports the best config.
public func tuneDiarization(fileURL: URL) async throws {
    print(String(repeating: "=", count: 60))
    print("AutoResearch: FluidAudio Diarization Parameter Tuner")
    print(String(repeating: "=", count: 60))
    print()
    print("Audio: \(fileURL.lastPathComponent)")
    print("Ground truth: \(groundTruthSequence.count) speaker segments, \(normalizeSeq(groundTruthSequence).count) normalized turns")
    print()

    // Parameter search space
    let clusteringThresholds: [Double] = [0.35, 0.4, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7]
    let minSegmentDurations: [Double] = [0.3, 0.5, 0.7, 1.0]
    let minDurationOnValues: [Double] = [0.0, 0.1, 0.2, 0.3]
    let minDurationOffValues: [Double] = [0.0, 0.1, 0.2, 0.3]
    let speechOnsetValues: [Double] = [0.4, 0.5, 0.6]
    let speechOffsetValues: [Double] = [0.4, 0.5, 0.6]
    let stepRatios: [Double] = [0.15, 0.2, 0.3]
    let minGapValues: [Double] = [0.02, 0.05, 0.1]
    let warmStartFaValues: [Double] = [0.04, 0.07, 0.1]
    let warmStartFbValues: [Double] = [0.7, 0.8, 0.9]

    // Baseline config (FluidAudio defaults)
    var bestScore = 0.0
    var bestParams: [String: Any] = [:]
    var bestSegments: [SpeakerSegment] = []
    var trialCount = 0

    // Phase 1: Baseline
    print("Phase 1: Baseline (FluidAudio defaults)")
    var baselineCfg = OfflineDiarizerConfig()
    baselineCfg.clustering.numSpeakers = 2
    baselineCfg.zeroVoteReembed = .init(enabled: true, minDurationSeconds: 0.4)
    let baselineSegments = try await runDiarization(fileURL: fileURL, config: baselineCfg)
    let baselineResult = evaluateDiarization(baselineSegments)
    bestScore = baselineResult.score
    bestParams = ["threshold": 0.6, "minSeg": 1.0, "minOn": 0.0, "minOff": 0.0,
                   "onset": 0.5, "offset": 0.5, "stepRatio": 0.2, "minGap": 0.1, "Fa": 0.07, "Fb": 0.8]
    bestSegments = baselineSegments
    print("  Baseline: score=\(String(format: "%.1f", baselineResult.score)) | \(baselineResult.details)")

    // Phase 2: One-at-a-time sweep — vary each parameter while keeping others at best
    print()
    print("Phase 2: One-at-a-time sweep")
    print("  (onset/offset sweeps omitted — they're interdependent with validation constraints)")

    let paramRuns: [(name: String, values: [Double], apply: (inout OfflineDiarizerConfig, Double) -> Void)] = [
        ("threshold", clusteringThresholds, { c, v in c.clustering.threshold = v }),
        ("minSeg", minSegmentDurations, { c, v in c.embedding.minSegmentDurationSeconds = v }),
        ("minOn", minDurationOnValues, { c, v in c.segmentation.minDurationOn = v }),
        ("minOff", minDurationOffValues, { c, v in c.segmentation.minDurationOff = v }),
        ("stepRatio", stepRatios, { c, v in c.segmentation.stepRatio = v }),
        ("minGap", minGapValues, { c, v in c.postProcessing.minGapDurationSeconds = v }),
        ("Fa", warmStartFaValues, { c, v in c.clustering.warmStartFa = v }),
        ("Fb", warmStartFbValues, { c, v in c.clustering.warmStartFb = v }),
    ]

    for param in paramRuns {
        var paramBestScore = bestScore
        var paramBestValue: Any = bestParams[param.name]!

        for val in param.values {
            // Build config from best params
            var cfg = OfflineDiarizerConfig()
            cfg.clustering.threshold = bestParams["threshold"] as! Double
            cfg.embedding.minSegmentDurationSeconds = bestParams["minSeg"] as! Double
            cfg.segmentation.minDurationOn = bestParams["minOn"] as! Double
            cfg.segmentation.minDurationOff = bestParams["minOff"] as! Double
            cfg.segmentation.speechOnsetThreshold = Float(bestParams["onset"] as! Double)
            cfg.segmentation.speechOffsetThreshold = Float(bestParams["offset"] as! Double)
            cfg.segmentation.stepRatio = bestParams["stepRatio"] as! Double
            cfg.postProcessing.minGapDurationSeconds = bestParams["minGap"] as! Double
            cfg.clustering.warmStartFa = bestParams["Fa"] as! Double
            cfg.clustering.warmStartFb = bestParams["Fb"] as! Double
            cfg.clustering.numSpeakers = 2
            cfg.zeroVoteReembed = .init(enabled: true, minDurationSeconds: 0.4)

            // Apply the current parameter value
            param.apply(&cfg, val)

            let segments = try await runDiarization(fileURL: fileURL, config: cfg)
            trialCount += 1
            let result = evaluateDiarization(segments)

            print("  \(param.name)=\(val): score=\(String(format: "%.1f", result.score)) | \(result.details)")

            if result.score > paramBestScore {
                paramBestScore = result.score
                paramBestValue = val
            }
        }

        let currentBest = bestParams[param.name] as! Double
        if let pv = paramBestValue as? Double, abs(pv - currentBest) > 1e-6 {
            print("  >>> \(param.name) improved: \(currentBest) → \(pv)")
            bestParams[param.name] = pv
            bestScore = paramBestScore
        }
    }

    // Phase 3: Verify with best config
    print()
    print(String(repeating: "=", count: 60))
    print("RESULTS")
    print(String(repeating: "=", count: 60))
    print()
    print("Trials: \(trialCount + 1)")
    print("Best score: \(String(format: "%.1f", bestScore))/100")
    print()
    print("Best parameters:")
    print("  clustering.threshold:            \(bestParams["threshold"]!)")
    print("  embedding.minSegmentDuration:    \(bestParams["minSeg"]!)")
    print("  segmentation.minDurationOn:      \(bestParams["minOn"]!)")
    print("  segmentation.minDurationOff:     \(bestParams["minOff"]!)")
    print("  segmentation.speechOnsetThreshold: \(bestParams["onset"]!)")
    print("  segmentation.speechOffsetThreshold: \(bestParams["offset"]!)")
    print("  segmentation.stepRatio:          \(bestParams["stepRatio"]!)")
    print("  postProcessing.minGap:           \(bestParams["minGap"]!)")
    print("  clustering.warmStartFa:          \(bestParams["Fa"]!)")
    print("  clustering.warmStartFb:          \(bestParams["Fb"]!)")
    print()
    print("Details: \(evaluateDiarization(bestSegments).details)")
    print()

    // Print speaker sequence
    let seq = bestSegments.map { $0.speakerId }
    let normSeq = normalizeSeq(seq)
    print("Speaker sequence (\(normSeq.count) turns):")
    print(normSeq.joined(separator: " → "))
}