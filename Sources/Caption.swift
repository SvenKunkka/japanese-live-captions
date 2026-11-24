import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import Speech
import Translation
import CoreMedia

private let source = Locale.Language(identifier: "ja")
private let defaultTarget = "zh-Hans"
private let labels = Locale(identifier: "zh-Hans")
private func languageName(_ id: String) -> String {
    if id == "zh-Hans" { return "简体中文" }
    if id == "zh-Hant" { return "繁体中文" }
    return labels.localizedString(forIdentifier: id) ?? id
}
private let sample = "来週の会議は火曜日の午後三時に始まります。"
private struct Fault: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
private struct Piece: Identifiable {
    let id = UUID()
    let ja: String
    let zh: String
}
private struct Pending {
    var text: String
    var final: Bool
    var end: Double
}

@MainActor private final class CaptionModel: ObservableObject {
    enum Mode { case mic, sample }
    @Published var config: TranslationSession.Configuration?
    @Published var running = false
    @Published var status = "待开始"
    @Published var transcript = ""
    @Published var caption = ""
    @Published var history = [Piece]()
    @Published var preparing = false
    @Published private(set) var mode = Mode.mic
    @Published private(set) var aiTranslation = UserDefaults.standard.object(forKey: "aiTranslation") as? Bool ?? true
    @Published private(set) var targetID = UserDefaults.standard.string(forKey: "targetLanguage") ?? defaultTarget
    @Published private(set) var targetOptions = [defaultTarget]
    private(set) var generation = UUID()
    private var originalTask: Task<Void, Never>?

    init() { targetOptions = [targetID] }
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var stream: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var finals = [Pending]()
    private var draft: Pending?
    private var lastFinalEnd = -1.0
    private var lastPreview = ""

    func loadLanguages() async {
        let service = LanguageAvailability()
        let languages = await service.supportedLanguages
        var ids = Set<String>()
        for language in languages where language.languageCode?.identifier != "ja" {
            let extended = language.maximalIdentifier
            let id = extended.hasPrefix("zh-Hans") ? "zh-Hans" : extended.hasPrefix("zh-Hant") ? "zh-Hant" : language.minimalIdentifier
            if await service.status(from: source, to: .init(identifier: id)) != .unsupported { ids.insert(id) }
        }
        guard !ids.isEmpty else { return }
        targetOptions = ids.sorted { languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending }
        if !ids.contains(targetID), let fallback = ids.contains(defaultTarget) ? defaultTarget : targetOptions.first {
            chooseTarget(fallback)
        }
    }

    func chooseAI(_ enabled: Bool) {
        guard enabled != aiTranslation else { return }
        resetForSettings()
        aiTranslation = enabled
        UserDefaults.standard.set(enabled, forKey: "aiTranslation")
    }

    func chooseTarget(_ id: String) {
        guard id != targetID else { return }
        resetForSettings()
        targetID = id
        UserDefaults.standard.set(id, forKey: "targetLanguage")
    }

    private func resetForSettings() {
        stop(running ? "设置已更新 · 请重新开始收听或测试样例" : "设置已更新")
        history.removeAll()
        transcript = ""
        caption = ""
    }

    func begin(_ newMode: Mode) {
        stop()
        mode = newMode
        running = true
        preparing = true
        caption = ""
        transcript = ""
        let token = generation
        if aiTranslation {
            status = "正在准备本机翻译模型…"
            config = .init(source: source, target: .init(identifier: targetID))
        } else {
            status = "正在准备日语原文…"
            originalTask = Task { await self.run(nil, token: token) }
        }
    }

    func stop(_ message: String = "已停止 · 麦克风关闭") {
        generation = UUID()
        config = nil
        originalTask?.cancel()
        originalTask = nil
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        engine = nil
        stream?.finish()
        stream = nil
        results?.cancel()
        results = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        finals.removeAll()
        draft = nil
        lastFinalEnd = -1
        lastPreview = ""
        running = false
        preparing = false
        status = message
    }

    private func publish(_ zh: String, for p: Pending) {
        if p.final {
            if history.count >= 160 { history.removeFirst(history.count - 159) }
            history.append(Piece(ja: p.text, zh: zh))
        }
        // Don't paint an older result over a more recent displayed interim.
        if !p.final || draft == nil || draft!.end <= p.end {
            transcript = p.text
            caption = zh
        }
    }

    private func received(text: String, final: Bool, range: CMTimeRange, token: UUID) {
        guard generation == token, running else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return }
        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
        if end.isFinite && end <= lastFinalEnd { return }
        let p = Pending(text: clean, final: final, end: end)
        if !aiTranslation {
            if final && end.isFinite { lastFinalEnd = end }
            publish(clean, for: p)
            return
        }
        if final {
            finals.append(p)
            lastFinalEnd = end.isFinite ? end : lastFinalEnd
            if let d = draft, !d.end.isFinite || !end.isFinite || d.end <= end { draft = nil }
            lastPreview = ""
        } else {
            draft = p
        }
        transcript = clean
    }

    private func setup<M: SpeechModule>(_ transcriber: M, token: UUID, extract: @escaping (M.Result) -> String) async throws {
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            status = "正在下载苹果日语语音模型…"
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await install.downloadAndInstall()
            }
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                throw Fault("日语语音模型未安装，请联网后重试。")
            }
        }
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        let audio = AVAudioEngine()
        let node = audio.inputNode
        let incoming = node.outputFormat(forBus: 0)
        guard incoming.sampleRate > 0, incoming.channelCount > 0,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: incoming) else {
            throw Fault("找不到可用的麦克风或语音格式。")
        }
        let pipeline = SpeechAnalyzer(modules: [transcriber])
        try await pipeline.prepareToAnalyze(in: format)
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        let (sequence, sender) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(80))
        analyzer = pipeline
        stream = sender
        results = Task { [weak self] in
            do {
                for try await item in transcriber.results {
                    self?.received(text: extract(item), final: item.isFinal, range: item.range, token: token)
                }
            } catch {
                if let self, self.generation == token, !Task.isCancelled {
                    self.stop("识别中断：" + error.localizedDescription)
                }
            }
        }
        try await pipeline.start(inputSequence: sequence)
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        try installMicrophoneTap(on: node, input: incoming, output: format, sender: sender)
        engine = audio
        audio.prepare()
        try audio.start()
    }

    func run(_ session: TranslationSession?, token: UUID) async {
        guard running, generation == token, (session != nil) == aiTranslation else { return }
        if let session,
           session.targetLanguage?.maximalIdentifier != Locale.Language(identifier: targetID).maximalIdentifier { return }
        do {
            if let session { try await session.prepareTranslation() }
            guard generation == token, !Task.isCancelled else { return }
            if mode == .sample {
                let translated = try await session?.translate(sample).targetText ?? sample
                guard generation == token, !Task.isCancelled else { return }
                publish(translated, for: Pending(text: sample, final: true, end: 0))
                stop(session == nil ? "样例完成 · 仅显示日语原文，未使用麦克风" : "样例翻译完成 · 未使用麦克风")
                return
            }
            status = "等待麦克风权限…"
            let permission = await AVCaptureDevice.requestAccess(for: .audio)
            guard generation == token, !Task.isCancelled else { return }
            guard permission else {
                throw Fault("麦克风权限未开启。请到 系统设置 → 隐私与安全性 → 麦克风，允许本应用后重试。")
            }
            let japanese = Locale(identifier: "ja-JP")
            if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: japanese) {
                try await setup(SpeechTranscriber(locale: locale, preset: .progressiveTranscription), token: token) { String($0.text.characters) }
            } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: japanese) {
                try await setup(DictationTranscriber(locale: locale, preset: .progressiveLongDictation), token: token) { String($0.text.characters) }
            } else { throw Fault("这台 Mac 的本机语音模型不支持日语。") }
            guard generation == token, !Task.isCancelled else { return }
            preparing = false
            status = aiTranslation ? "正在收听日语 · 本机转译，不外放" : "正在收听日语 · 仅显示原文，不外放"
            guard let session else { return }
            while generation == token && !Task.isCancelled {
                let p = !finals.isEmpty ? finals.removeFirst() : draft.flatMap { $0.text == lastPreview ? nil : $0 }
                if let p {
                    let result = try await session.translate(p.text)
                    guard generation == token, !Task.isCancelled else { return }
                    if p.final || (draft?.text == p.text && (p.end > lastFinalEnd || !p.end.isFinite)) {
                        publish(result.targetText, for: p)
                    }
                    if !p.final { lastPreview = p.text }
                }
                try await Task.sleep(for: .milliseconds(p == nil ? 90 : 220))
            }
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            let detail = error.localizedDescription
            stop("未能继续：" + detail)
        }
    }
}

private func installMicrophoneTap(on node: AVAudioInputNode, input: AVAudioFormat, output: AVAudioFormat, sender: AsyncStream<AnalyzerInput>.Continuation) throws {
    guard let converter = AVAudioConverter(from: input, to: output) else { throw Fault("无法转换麦克风音频。") }
    let ratio = output.sampleRate / input.sampleRate
    node.installTap(onBus: 0, bufferSize: 2048, format: input) { buffer, _ in
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 128
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        var provided = false
        var error: NSError?
        let result = converter.convert(to: converted, error: &error) { _, flag in
            if provided { flag.pointee = .noDataNow; return nil }
            provided = true
            flag.pointee = .haveData
            return buffer
        }
        if result != .error && error == nil && converted.frameLength > 0 { sender.yield(AnalyzerInput(buffer: converted)) }
    }
}

private struct WindowProxy: NSViewRepresentable {
    var floating: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.level = floating ? .floating : .normal }
    }
}

@MainActor private struct CaptionView: View {
    @StateObject private var model = CaptionModel()
    @State private var showJapanese = true
    @State private var floating = false
    @State private var fontSize: Double = 38
    var body: some View {
        let token = model.generation
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("实时字幕").font(.system(size: 28, weight: .bold))
                    Text(model.aiTranslation ? "日本語  →  " + languageName(model.targetID) : "日本語  ·  仅原文").foregroundStyle(.secondary)
                }
                Spacer()
                Button("测试样例") { model.begin(.sample) }.disabled(model.running)
                Button(model.running ? "停止" : "开始收听") {
                    if model.running { model.stop() } else { model.begin(.mic) }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            HStack(spacing: 18) {
                Toggle("AI 转译", isOn: Binding(get: { model.aiTranslation }, set: { model.chooseAI($0) }))
                    .toggleStyle(.switch)
                Picker("输出语言", selection: Binding(get: { model.targetID }, set: { model.chooseTarget($0) })) {
                    ForEach(model.targetOptions, id: \.self) { id in Text(languageName(id)).tag(id) }
                }.frame(maxWidth: 270).disabled(!model.aiTranslation)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(model.caption.isEmpty ? (model.aiTranslation ? languageName(model.targetID) + "字幕将在这里显示" : "日语原文将在这里显示") : model.caption)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(model.caption.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                if model.aiTranslation && showJapanese && !model.transcript.isEmpty {
                    Text(model.transcript).font(.title3).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, minHeight: 125, alignment: .leading)
                .padding(20).background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 15))
            HStack(spacing: 8) {
                if model.preparing { ProgressView().controlSize(.small) }
                else { Circle().fill(model.running ? Color.green : Color.secondary).frame(width: 8, height: 8) }
                Text(model.status).font(.callout)
                Spacer()
            }.accessibilityElement(children: .combine)
            Divider()
            HStack {
                Text("最近字幕").font(.headline)
                Spacer()
                Button("清空") { model.history.removeAll(); model.caption = ""; model.transcript = "" }.disabled(model.history.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.history.isEmpty { Text("字幕仅在本次打开期间保留。").foregroundStyle(.secondary) }
                        ForEach(model.history) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.zh).textSelection(.enabled)
                                if model.aiTranslation && showJapanese { Text(row.ja).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            }.frame(maxWidth: .infinity, alignment: .leading).id(row.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.onChange(of: model.history.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            }.frame(minHeight: 75)
            HStack {
                Toggle("显示日语", isOn: $showJapanese).disabled(!model.aiTranslation)
                Toggle("窗口置顶", isOn: $floating)
                Spacer()
                Text("字号")
                Slider(value: $fontSize, in: 24...58).frame(width: 95).accessibilityLabel("字幕字号")
            }
            Text("本机处理 · 不保存录音 · 首次使用可能需要下载苹果语言模型").font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).frame(minWidth: 620, minHeight: 440)
        .background(WindowProxy(floating: floating))
        .translationTask(model.config) { session in await model.run(session, token: token) }
        .task { await model.loadLanguages() }
        .onDisappear { model.stop() }

    }
}

@main struct LiveCaptionApp: App {
    var body: some Scene {
        Window("日语实时字幕", id: "captions") { CaptionView() }
            .defaultSize(width: 790, height: 525)
    }
}
