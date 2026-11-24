# Japanese Live Captions for Mac

A small macOS app that turns Japanese speech from the default microphone into live subtitles in a language you choose. It shows text only and never plays back audio.

## Get started

1. Download `Japanese-Live-Captions-v1.1.0-arm64.zip` from [Releases](https://github.com/SvenKunkka/japanese-live-captions/releases/latest) and extract it.
2. Open **日语实时字幕**. The release uses an ad hoc code signature and is not notarized, so macOS may block the downloaded copy. If it does, you can build from source on your Mac using the instructions below.
3. Leave **AI 转译** (AI translation) on and choose **输出语言** (Output language), or switch AI translation off to show only the original Japanese transcription. The app remembers both settings. Available target languages come from the device's supported Apple translation pairs.
4. Click **测试样例** (Test sample) to try the selected mode without microphone access. macOS may download language models on first use.
5. Click **开始收听** (Start listening) and grant microphone access. Click **停止** (Stop) or close the window to stop listening.

Requires **macOS 26 or later** on an **Apple Silicon Mac**. The interface is in Simplified Chinese. You can toggle the Japanese transcript, keep the window on top, and change subtitle size. If you change the mode or output language during a session, the app stops listening and clears earlier subtitles. Click **开始收听** again to resume.

## Privacy and verification

Japanese recognition and translation use Apple's on-device models. An internet connection may be needed to download those models on first use. The app does not save recordings, upload conversation audio, or require an API key. Subtitle history is kept in memory while the app is open.

The bundled Japanese text sample was verified on a real Mac both with Simplified Chinese translation and with translation off (Japanese only), without enabling the microphone. Live microphone capture was not tested in this release.

## Build from source

With the macOS 26 SDK and Swift 6.2 or newer:

```sh
mkdir -p '日语实时字幕.app/Contents/MacOS'
cp Sources/Info.plist '日语实时字幕.app/Contents/Info.plist'
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 \
  Sources/Caption.swift -o '日语实时字幕.app/Contents/MacOS/LiveCaption'
codesign --force --sign - '日语实时字幕.app'
codesign --verify --strict '日语实时字幕.app'
```

## 中文速用

macOS 26 或以上、Apple 芯片。打开「日语实时字幕」后，可选择输出语言。关闭「AI 转译」则仅显示日语原文。先点「测试样例」，再点「开始收听」并允许麦克风权限。字幕只显示文字，不外放；首次可能需要联网下载苹果语言模型。

No license has been granted for this repository.
