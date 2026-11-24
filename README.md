# Japanese Live Captions for Mac

A small macOS app that turns Japanese speech from the default microphone into live Simplified Chinese subtitles. It shows text only and never plays back audio.

## Get started

1. Download `Japanese-Live-Captions-v1.0.0-arm64.zip` from [Releases](https://github.com/SvenKunkka/japanese-live-captions/releases/latest) and extract it.
2. Open **日语实时字幕**. The release uses an ad hoc code signature and is not notarized, so macOS may block the downloaded copy. If it does, you can build from source on your Mac using the instructions below.
3. Click **测试样例** (Test sample) to test Japanese-to-Chinese translation without microphone access. macOS may download language models on first use.
4. Click **开始收听** (Start listening) and grant microphone access. Click **停止** (Stop) or close the window to stop listening.

Requires **macOS 26 or later** on an **Apple Silicon Mac**. The interface is in Simplified Chinese. You can toggle the Japanese transcript, keep the window on top, and change subtitle size.

## Privacy and verification

Japanese recognition and translation use Apple's on-device models. An internet connection may be needed to download those models on first use. The app does not save recordings, upload conversation audio, or require an API key. Subtitle history is kept in memory while the app is open.

The bundled Japanese text sample was verified on a real Mac to produce a Simplified Chinese subtitle without enabling the microphone. Live microphone capture was not tested in the original development session.

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

macOS 26 或以上、Apple 芯片。打开「日语实时字幕」后，先点「测试样例」确认翻译，再点「开始收听」并允许麦克风权限。字幕只显示文字，不外放；首次可能需要联网下载苹果语言模型。

No license has been granted for this repository.
