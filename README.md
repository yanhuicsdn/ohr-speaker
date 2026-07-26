# ohr-speaker 🔊

> On-device speech-to-text with **speaker diarization**, powered by Apple Intelligence & CAM++

[**中文版**](README_ZH.md) | English

ohr-speaker is an enhanced fork of [ohr](https://github.com/Arthur-Ficial/ohr) that integrates three speaker diarization engines — including **CAM++** (阿里达摩院) and **FluidAudio** — on top of the original Apple SpeechAnalyzer transcription engine.

**100% on-device. No cloud. No API keys. Your data never leaves your machine.**

---

## Features

- 🎤 **Apple Intelligence Transcription** — Powered by macOS SpeechAnalyzer, millisecond latency
- 🗣️ **Three Diarization Engines** — CAM++, Offline VBx (WeSpeaker), or Sortformer (`--engine` flag)
- 🇨🇳 **Chinese-Optimized** — CAM++ model trained on 200k Chinese speakers, ~15MB model
- 📝 **Multiple Output Formats** — Plain text, JSON, SRT subtitles, VTT subtitles with speaker labels
- 🎙️ **Live Microphone Transcription** — Real-time `--listen` mode
- 🖥️ **OpenAI-Compatible Server** — `--serve` mode, compatible with OpenAI Whisper API
- 📦 **Multi-format Support** — m4a, wav, mp3, mp4, caf, aiff, flac
- 🔒 **Privacy First** — All processing is local, no data uploaded

## Quick Start

Download a pre-built binary from [Releases](https://github.com/yanhuicsdn/ohr-speaker/releases):

| Binary | Default Engine | Model Size |
|--------|---------------|------------|
| `ohr-cam` | **CAM++** (default) | ~15 MB |
| `ohr-speaker` | Offline VBx (WeSpeaker) | ~700 MB |

```bash
# CAM++ engine (~15 MB model, auto-downloaded on first use)
ohr-cam --speakers meeting.wav

# Or offline VBx engine (legacy, ~700 MB model)
ohr-speaker --speakers meeting.wav
```

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

### Prerequisites

- macOS 26+ (Apple Silicon)
- Xcode 26.6+ or Xcode-beta 27+

## Usage

### Basic Transcription

```bash
ohr-speaker audio.wav
```

### With Speaker Diarization (CAM++ default)

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

### Select a Different Diarization Engine

```bash
# CAM++ (default) — 阿里达摩院, 200k Chinese speakers, ~15MB model
ohr-speaker --speakers --engine campplus audio.wav

# Offline VBx (WeSpeaker) — ~700MB model, PLDA scoring
ohr-speaker --speakers --engine offlineVbx audio.wav

# Sortformer — ~200MB model, ≤4 speakers, CoreML ANE accelerated
ohr-speaker --speakers --engine sortformer audio.wav
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
  --speakers                   Enable speaker diarization
  --engine <name>              Diarization engine: campplus, offlineVbx, sortformer
  -l, --language <code>        Language code (e.g. en-US, de-DE)
  -q, --quiet                  Suppress headers and chrome
  --no-color                   Disable ANSI colors

SERVER OPTIONS:
  --serve                      Start HTTP server
  --port <n>                   Server port (default: 11434, env: OHR_PORT)
  --host <addr>                Bind address (default: 127.0.0.1, env: OHR_HOST)
  --cors                       Enable CORS headers
  --allowed-origins <list>     Comma-separated allowed origins
  --no-origin-check            Disable origin validation
  --token <secret>             Require Bearer token (env: OHR_TOKEN)
  --token-auto                 Generate random token on startup
  --public-health              /health without auth on non-loopback
  --footgun                    Disable all protections (DANGEROUS)
  --max-concurrent <n>         Max concurrent requests (default: 5)
  --debug                      Enable /v1/logs endpoints

INFO:
  -h, --help                   Show this help
  -v, --version                Show version
  --release                    Show detailed build info
  --model-info                 Show model capabilities
```

## Diarization Engine Comparison

| Engine | Model | Parameters | Size | Speakers | M4 Accel. | Language Bias |
|--------|-------|-----------|------|----------|-----------|---------------|
| **CAM++** ⭐ | 阿里达摩院 CAM++ | 7.2M | **~15 MB** | unlimited | GPU | **Chinese** ✅ |
| Offline VBx | WeSpeaker + PLDA | ~25M | ~700 MB | unlimited | **ANE** ✅ | Multi |
| Sortformer | FluidAudio Sortformer | — | ~200 MB | ≤4 | **ANE** ✅ | Multi |
| LS‑EEND ❌ | dihard3 EEND | — | ~44 MB | unlimited | CoreML | English only |

**Benchmark** (2-speaker Chinese podcast, 17 min):

| Engine | Segments | S1 | S2 | First-run download |
|--------|:--------:|:--:|:--:|:------------------:|
| CAM++ ⭐ | 22 | 11 | 11 | **~5 sec** |
| Offline VBx | 26 | 13 | 13 | ~2 min |
| Sortformer | 26 | 13 | 13 | ~1 min |

> **CAM++** is the recommended engine for Chinese audio — smallest model, fastest download, specifically trained on 200k Chinese speakers by Alibaba DAMO Academy.

## Performance

| Audio Duration | Transcription Only | Additional Diarization |
|---------------|-------------------|----------------------|
| 1 min | ~1s | ~1s |
| 10 min | ~3s | ~2s |
| 31 min | ~10s | ~5s |
| 1 hour | ~20s | ~10s |

## How It Works

1. **Transcription**: Uses Apple's `SpeechAnalyzer` + `SpeechTranscriber` framework to convert audio into timestamped text segments
2. **Diarization**: One of three engines:
   - **CAM++**: FluidAudio segmentation → independent CAM++ embedding extractor (192-d) → cosine agglomerative clustering
   - **Offline VBx**: FluidAudio's full pipeline (Seg-3 + WeSpeaker + PLDA + VBx)
   - **Sortformer**: FluidAudio's end-to-end Sortformer (≤4 speakers, CoreML ANE)
3. **Alignment**: Uses a time-overlap-maximization algorithm to align transcription segments with speaker segments

## Environment Variables

| Variable | Description |
|----------|-------------|
| `OHR_PORT` | Server port (default: 11434) |
| `OHR_HOST` | Server bind address (default: 127.0.0.1) |
| `OHR_TOKEN` | Bearer token for server auth |
| `OHR_LANGUAGE` | Default language code |
| `REGISTRY_URL` | Model download mirror (e.g. `https://hf-mirror.com`) |
| `NO_COLOR` | Disable ANSI colors |

## Differences from Upstream ohr

| Feature | ohr | ohr-speaker |
|---------|-----|-------------|
| Speaker Diarization | ❌ | ✅ `--speakers` |
| Transcription Engine | Apple SpeechAnalyzer | Apple SpeechAnalyzer |
| Diarization Engine | — | **CAM++** (default) / Offline VBx / Sortformer |
| Model Download | 0 MB | **~15 MB** (CAM++) or ~700 MB (VBx) |
| Engine Selection | — | `--engine` flag |
| Output Formats | plain/json/srt/vtt | plain/json/srt/vtt + speaker labels |
| Server Mode | ✅ | ✅ (supports `diarize` parameter) |

## Model Cache Locations

| Engine | Cache Path | Size |
|--------|-----------|------|
| CAM++ | `~/Library/Application Support/ohr-campplus/` | ~15 MB |
| FluidAudio | `~/Library/Application Support/FluidAudio/Models/` | ~700 MB |

## Credits

- [Arthur-Ficial/ohr](https://github.com/Arthur-Ficial/ohr) — The original ohr project
- [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio) — FluidAudio diarization engine
- [3D-Speaker / FunASR](https://github.com/modelscope/FunASR) — CAM++ speaker embedding by Alibaba DAMO Academy
- Apple Speech Framework — macOS built-in speech recognition capabilities

## License

[MIT](LICENSE)
