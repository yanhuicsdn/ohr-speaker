# ohr-speaker 🔊

> On-device speech-to-text with **speaker diarization**, powered by Apple Intelligence

[**中文版**](README_ZH.md) | English

ohr-speaker is an enhanced fork of [ohr](https://github.com/Arthur-Ficial/ohr) that integrates [FluidAudio](https://github.com/FluidInference/FluidAudio) offline speaker diarization on top of the original Apple SpeechAnalyzer transcription engine.

**100% on-device. No cloud. No API keys. Your data never leaves your machine.**

---

## Features

- 🎤 **Apple Intelligence Transcription** — Powered by macOS SpeechAnalyzer, millisecond latency
- 🗣️ **Speaker Diarization** — Automatically detects and labels different speakers (`--speakers` flag)
- 📝 **Multiple Output Formats** — Plain text, JSON, SRT subtitles, VTT subtitles
- 🎙️ **Live Microphone Transcription** — Real-time `--listen` mode
- 🖥️ **OpenAI-Compatible Server** — `--serve` mode, compatible with OpenAI Whisper API
- 📦 **Multi-format Support** — m4a, wav, mp3, mp4, caf, aiff, flac
- 🔒 **Privacy First** — All processing is local, no data uploaded

## Installation

### Prerequisites

- macOS 26+ (Apple Silicon)
- Xcode 26.6+ or Xcode-beta 27+
- ~700 MB disk space (first run auto-downloads FluidAudio models)

### Build from Source

```bash
git clone https://github.com/yanhuicsdn/ohr-speaker.git
cd ohr-speaker

# Using Xcode-beta toolchain (macOS 27+)
DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer" swift build -c release

# Using Xcode stable (macOS 26+)
swift build -c release

# Copy the binary to your PATH
cp .build/release/ohr /usr/local/bin/ohr-speaker
```

### Download Binary

Download the pre-built binary from the [Releases](https://github.com/yanhuicsdn/ohr-speaker/releases) page.

## Usage

### Basic Transcription

```bash
ohr-speaker audio.wav
```

### With Speaker Diarization

```bash
ohr-speaker --speakers audio.wav
```

Sample output:

```
【S1】
There is usually a platform management layer with a user center...

【S2】
Give them the full version so they can use it...

【S1】
Yes, provincial business layers have isolation requirements for permissions...
```

### Output as SRT Subtitles

```bash
ohr-speaker --speakers -o srt audio.wav > subtitles.srt
```

### Output as JSON

```bash
ohr-speaker --speakers -o json audio.wav
```

### Live Microphone Transcription

```bash
ohr-speaker --listen --speakers
```

### Start OpenAI-Compatible Server

```bash
ohr-speaker --serve --port 11434
```

Then call from any OpenAI Whisper client:

```bash
curl http://localhost:11434/v1/audio/transcriptions \
  -F "file=@audio.wav" \
  -F "model=whisper-1" \
  -F "diarize=true"
```

### Complete Options

```
USAGE:
  ohr <file>                   Transcribe an audio file
  ohr -o srt <file>            Transcribe to SRT subtitles
  ohr -o vtt <file>            Transcribe to VTT subtitles
  ohr -o json <file>           Transcribe to JSON with segments
  ohr --listen                 Live microphone transcription
  ohr --serve                  Start OpenAI-compatible HTTP server
  cat audio.wav | ohr          Transcribe from stdin

OPTIONS:
  -o, --output <format>        Output: plain (default), json, srt, vtt
  --json                       Shorthand for -o json
  --srt                        Shorthand for -o srt
  --vtt                        Shorthand for -o vtt
  --timestamps                 Show timestamps in plain text output
  --speakers                   Enable speaker diarization (requires FluidAudio)
  -l, --language <code>        Language code (e.g. en-US, de-DE)
  -q, --quiet                  Suppress headers and chrome
  --no-color                   Disable ANSI colors
```

## Differences from Upstream ohr

| Feature | ohr | ohr-speaker |
|---------|-----|-------------|
| Speaker Diarization | ❌ | ✅ `--speakers` |
| Transcription Engine | Apple SpeechAnalyzer | Apple SpeechAnalyzer |
| Diarization Engine | — | FluidAudio OfflineDiarizer |
| Model Download | 0 MB | ~700 MB (one-time) |
| Output Formats | plain/json/srt/vtt | plain/json/srt/vtt + speaker labels |
| Server Mode | ✅ | ✅ (supports `diarize` parameter) |

## Performance

| Audio Duration | Transcription Only | Additional Diarization |
|---------------|-------------------|----------------------|
| 1 min | ~1s | ~1s |
| 10 min | ~3s | ~2s |
| 31 min | ~10s | ~5s |
| 1 hour | ~20s | ~10s |

## How It Works

1. **Transcription**: Uses Apple's `SpeechAnalyzer` + `SpeechTranscriber` framework to convert audio into timestamped text segments
2. **Diarization**: Uses FluidAudio's `OfflineDiarizerManager` to perform speaker segmentation on the audio
3. **Alignment**: Uses a time-overlap-maximization algorithm to align transcription segments with speaker segments, assigning each text segment a speaker label

## Credits

- [Arthur-Ficial/ohr](https://github.com/Arthur-Ficial/ohr) — The original ohr project
- [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio) — FluidAudio diarization engine
- Apple Speech Framework — macOS built-in speech recognition capabilities

## License

[MIT](LICENSE)