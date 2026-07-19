# ohr-speaker 🔊

> 基于 Apple Intelligence 的本地语音转文字工具，支持 **说话人识别（声纹分割）**

English | [**中文版**](README_ZH.md)

ohr-speaker 是 [ohr](https://github.com/Arthur-Ficial/ohr) 的增强分支，在原有 Apple SpeechAnalyzer 转录引擎的基础上，集成了 [FluidAudio](https://github.com/FluidInference/FluidAudio) 的离线说话人分割（Speaker Diarization）功能。

**100% 本地运行，无需联网，无需 API 密钥，数据不出设备。**

---

## 特性

- 🎤 **Apple Intelligence 转录** — 使用 macOS SpeechAnalyzer，毫秒级响应
- 🗣️ **说话人识别** — 自动检测并区分不同说话人（`--speakers` 标志）
- 📝 **多种输出格式** — 纯文本、JSON、SRT 字幕、VTT 字幕
- 🎙️ **麦克风实时转录** — 支持 `--listen` 模式
- 🖥️ **OpenAI 兼容服务器** — 支持 `--serve` 模式，兼容 OpenAI Whisper API
- 📦 **多格式支持** — m4a, wav, mp3, mp4, caf, aiff, flac
- 🔒 **隐私优先** — 所有处理在本地完成，数据不上传云端

## 安装

### 前提条件

- macOS 26+（Apple Silicon）
- Xcode 26.6+ 或 Xcode-beta 27+
- 约 700 MB 磁盘空间（首次运行自动下载 FluidAudio 模型）

### 从源码编译

```bash
git clone https://github.com/yanhuicsdn/ohr-speaker.git
cd ohr-speaker

# 使用 Xcode-beta 工具链（macOS 27+）
DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer" swift build -c release

# 或者使用 Xcode 正式版（macOS 26+）
swift build -c release

# 将编译好的二进制复制到 PATH 中
cp .build/release/ohr /usr/local/bin/ohr-speaker
```

### 直接下载

从 [Releases](https://github.com/yanhuicsdn/ohr-speaker/releases) 页面下载预编译二进制文件。

## 使用

### 基础转录

```bash
ohr-speaker 音频文件.wav
```

### 带说话人识别

```bash
ohr-speaker --speakers 音频文件.wav
```

输出示例：

```
【S1】
都会有一个平台管理一般就有个用户中心...

【S2】
一个全的给个全的让用这样东西对他这个就比较清晰...

【S1】
对，就是他们省业务层面对这个权限的隔离是要求...
```

### 输出为 SRT 字幕

```bash
ohr-speaker --speakers -o srt 音频文件.wav > 字幕.srt
```

### 输出为 JSON

```bash
ohr-speaker --speakers -o json 音频文件.wav
```

### 麦克风实时转录

```bash
ohr-speaker --listen --speakers
```

### 启动 OpenAI 兼容服务器

```bash
ohr-speaker --serve --port 11434
```

然后可以用任何 OpenAI Whisper 客户端调用：

```bash
curl http://localhost:11434/v1/audio/transcriptions \
  -F "file=@audio.wav" \
  -F "model=whisper-1" \
  -F "diarize=true"
```

### 完整选项

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

## 与原始 ohr 的区别

| 特性 | ohr | ohr-speaker |
|------|-----|-------------|
| 说话人识别 | ❌ | ✅ `--speakers` |
| 转录引擎 | Apple SpeechAnalyzer | Apple SpeechAnalyzer |
| 声纹引擎 | — | FluidAudio OfflineDiarizer |
| 模型下载 | 0 MB | ~700 MB（一次性） |
| 输出格式 | plain/json/srt/vtt | plain/json/srt/vtt + 说话人标签 |
| 服务器模式 | ✅ | ✅（支持 `diarize` 参数） |

## 性能

| 音频时长 | 纯转录 | 说话人识别（额外） |
|---------|--------|-------------------|
| 1 分钟 | ~1s | ~1s |
| 10 分钟 | ~3s | ~2s |
| 31 分钟 | ~10s | ~5s |
| 1 小时 | ~20s | ~10s |

## 技术原理

1. **转录**：使用 Apple 的 `SpeechAnalyzer` + `SpeechTranscriber` 框架，将音频转为带时间戳的文本段
2. **声纹**：使用 FluidAudio 的 `OfflineDiarizerManager`，对音频进行说话人分割
3. **对齐**：通过时间重叠最大化算法，将转录段与说话人段对齐，为每个文本段分配说话人标签

## 致谢

- [Arthur-Ficial/ohr](https://github.com/Arthur-Ficial/ohr) — 原始 ohr 项目
- [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio) — FluidAudio 声纹引擎
- Apple Speech 框架 — macOS 内置语音识别能力

## 许可

[MIT](LICENSE)