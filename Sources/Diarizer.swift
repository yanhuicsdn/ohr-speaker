// ============================================================================
// Diarizer.swift — FluidAudio speaker diarization wrapper
// Part of ohr — On-device speech-to-text from the command line
// ============================================================================

import Foundation
import AVFAudio
import FluidAudio
import OhrCore

// MARK: - Speaker Segment

/// A speaker segment with timing and label.
struct SpeakerSegment: Sendable {
    let speakerId: String
    let start: Double
    let end: Double
}

// MARK: - Speaker Label Mapping

/// Map raw speaker IDs (SPEAKER_00, SPEAKER_01) to short labels (Speaker 1, Speaker 2).
/// This gives nicer output than raw IDs.
private func labelForSpeaker(_ speakerId: String) -> String {
    // Try to extract the number from SPEAKER_00, SPEAKER_01, etc.
    let parts = speakerId.split(separator: "_")
    if parts.count == 2, let num = Int(parts[1]) {
        return "Speaker \(num + 1)"
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

    // Convert FluidAudio result to our SpeakerSegment type
    let segments = result.segments.map { seg in
        SpeakerSegment(
            speakerId: labelForSpeaker(seg.speakerId),
            start: Double(seg.startTimeSeconds),
            end: Double(seg.endTimeSeconds)
        )
    }

    return segments
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
private func bestSpeaker(
    for range: ClosedRange<Double>,
    candidates: [SpeakerSegment]
) -> String? {
    var bestOverlap: Double = 0
    var bestSpeaker: String? = nil

    for candidate in candidates {
        let overlapStart = max(range.lowerBound, candidate.start)
        let overlapEnd = min(range.upperBound, candidate.end)
        let overlap = max(0, overlapEnd - overlapStart)

        if overlap > bestOverlap {
            bestOverlap = overlap
            bestSpeaker = candidate.speakerId
        }
    }

    return bestSpeaker
}