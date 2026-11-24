# Live Speech Captions for Mac

A quiet macOS app for live captions. Choose an input language or let local Whisper detect the language. Optionally translate into another language using Apple's on-device translation models. The app shows text only; it never plays back or saves audio.

## Get started

1. Download `Live-Speech-Captions-v1.2.0-arm64.zip` from [Releases](https://github.com/SvenKunkka/japanese-live-captions/releases/latest) and extract it. The app is listed as **日语实时字幕** for compatibility with existing installations; the window is titled **实时语音字幕**.
2. Choose **输入语言** (Input language). Manual mode lists the speech locales supported by Apple on this Mac. To use automatic detection, choose **自动识别（Whisper）** after completing the one-time setup below.
3. Leave **AI 转译** (AI translation) on and choose **输出语言** (Output language), or switch it off to show only the original transcription. These settings are remembered.
4. Click **开始收听** (Start listening) and grant microphone access. Click **停止** (Stop) or close the window to stop listening. In supported manual modes, **测试样例** (Test sample) checks text output without using the microphone.

Requires **macOS 26 or later** and an **Apple Silicon Mac**. The interface is in Simplified Chinese. The release is ad hoc signed and not Apple-notarized; if macOS blocks the downloaded app, build it from source instead.

## Optional automatic detection

Manual mode does not need Whisper. Automatic mode uses the Homebrew `openai-whisper` package and the official multilingual Tiny model. Install it from Homebrew, then fetch and verify the model once:

```sh
brew install openai-whisper
cache="$HOME/.cache/whisper"
mkdir -p "$cache"
model_tmp="$(mktemp "$cache/.tiny.XXXXXX")"
curl -fL -o "$model_tmp" https://openaipublic.azureedge.net/main/whisper/models/65147644a518d12f04e32d6f3b26facc3f8dd46e5390956a9424a650c0ce22b9/tiny.pt &&
printf '%s  %s\n' 65147644a518d12f04e32d6f3b26facc3f8dd46e5390956a9424a650c0ce22b9 "$model_tmp" | shasum -a 256 -c - &&
mv "$model_tmp" "$cache/tiny.pt"
```

Automatic mode processes speech in roughly five-second windows. Accuracy varies by language, dialect, speech length and background noise. It does not promise coverage for every language or reliable word-by-word language switching. If Apple cannot translate the detected language into the chosen target, the app shows the original text. In a noisy room or when you know which language is being spoken, try manual mode.

## Privacy

Manual recognition and optional translation use Apple models. Automatic recognition uses the local Whisper process. Audio passes to Whisper in memory and is not sent to a cloud service. Short-lived subtitle history exists only while the app is open. You may need Internet access to download the relevant models; no API key is required.

Changing source, target, or AI translation mode stops the current session and clears earlier subtitles. Click **开始收听** to resume.

## Build from source

With the macOS 26 SDK and Swift 6.2 or newer:

```sh
app='日语实时字幕.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Sources/Info.plist "$app/Contents/"
cp Sources/whisper_bridge.py "$app/Contents/Resources/"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 \
  Sources/Caption.swift -o "$app/Contents/MacOS/LiveCaption"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
```

Automatic detection uses [OpenAI Whisper](https://github.com/openai/whisper) as a separately installed dependency. Neither Whisper software nor its model weights are bundled in this release. No license has been granted for this repository.

## 中文速用

在「输入语言」选择需要识别的语种，或者完成上面的本机 Whisper 安装后选择「自动识别（Whisper）」。关闭「AI 转译」会只显示识别到的原文；打开则可选择输出语言。自动识别约每五秒刷新，语言覆盖以模型为准，不支持的转译组合会显示原文。
