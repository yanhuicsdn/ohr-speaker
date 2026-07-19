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

/// Run speaker diarization on an audio file using FluidAudio's offline pipeline.
/// Returns a list of speaker segments sorted by time.
/// - Parameter fileURL: URL of the audio file to diarize
/// - Returns: Array of SpeakerSegment, or empty array if diarization fails
func runDiarization(fileURL: URL) async throws -> [SpeakerSegment] {
    let config = OfflineDiarizerConfig()
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