import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import Speech
import Translation
import CoreMedia
import Darwin

private let defaultSource = "ja-JP"
private let autoSource = "auto"
private let defaultTarget = "zh-Hans"
private let labels = Locale(identifier: "zh-Hans")
private func languageName(_ id: String) -> String {
    if id == autoSource { return "自动识别（Whisper）" }
    if id == "zh-Hans" { return "简体中文" }
    if id == "zh-Hant" { return "繁体中文" }
    return labels.localizedString(forIdentifier: id) ?? id
}
private let samples: [String: String] = [
    "ja": "来週の会議は火曜日の午後三時に始まります。",
    "en": "Next week’s meeting starts at three on Tuesday afternoon.",
    "zh": "下周的会议在周二下午三点开始。",
    "fr": "La réunion de la semaine prochaine commence mardi à quinze heures.",
    "de": "Das Treffen nächste Woche beginnt am Dienstag um fünfzehn Uhr.",
    "es": "La reunión de la próxima semana empieza el martes a las tres de la tarde.",
    "it": "La riunione della prossima settimana inizia martedì alle tre del pomeriggio.",
    "pt": "A reunião da próxima semana começa na terça-feira às três da tarde.",
    "ko": "다음 주 회의는 화요일 오후 세 시에 시작합니다。",
    "ru": "Встреча на следующей неделе начнётся во вторник в три часа дня。",
    "tr": "Gelecek haftaki toplantı salı günü öğleden sonra saat üçte başlayacak.",
    "vi": "Cuộc họp tuần sau bắt đầu lúc ba giờ chiều thứ Ba.",
    "id": "Rapat minggu depan dimulai pada hari Selasa pukul tiga sore.",
    "nl": "De vergadering van volgende week begint dinsdag om drie uur 's middags.",
    "uk": "Зустріч наступного тижня розпочнеться у вівторок о третій годині дня.",
    "th": "การประชุมสัปดาห์หน้าเริ่มวันอังคารตอนบ่ายสามโมง",
    "hi": "अगले सप्ताह की बैठक मंगलवार दोपहर तीन बजे शुरू होगी।",
    "ar": "يبدأ اجتماع الأسبوع المقبل يوم الثلاثاء الساعة الثالثة بعد الظهر.",
    "pl": "Spotkanie w przyszłym tygodniu zaczyna się we wtorek o piętnastej."
]
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
    @Published private(set) var sourceID = UserDefaults.standard.string(forKey: "sourceLanguage") ?? defaultSource
    @Published private(set) var sourceOptions = [defaultSource]
    @Published private(set) var loadingTargets = true
    @Published private(set) var autoLanguage: String?
    private var worker: Process?
    private var workerWriter: Task<Void, Never>?
    private var speechEnd = 0.0
    private(set) var autoEpoch = UUID()
    private var rejectedAutoLanguage: String?
    private var autoSessionLanguage: Locale.Language?
    private var source: Locale.Language { Locale.Language(identifier: sourceID) }
    var sampleAvailable: Bool { sourceID != autoSource && source.languageCode.flatMap { samples[$0.identifier] } != nil }
    private(set) var generation = UUID()
    private var originalTask: Task<Void, Never>?

    init() { targetOptions = [targetID]; sourceOptions = [sourceID] }
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var stream: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var finals = [Pending]()
    private var draft: Pending?
    private var lastFinalEnd = -1.0
    private var lastPreview = ""

    func loadSources() async {
        let speech = await SpeechTranscriber.supportedLocales
        let dictation = await DictationTranscriber.supportedLocales
        let ids = Set((speech + dictation).map { $0.identifier(.bcp47) })
        guard !Task.isCancelled, !ids.isEmpty else { return }
        sourceOptions = [autoSource] + ids.sorted { languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending }
        if sourceID != autoSource, !ids.contains(sourceID), let fallback = ids.contains(defaultSource) ? defaultSource : sourceOptions.first {
            chooseSource(fallback)
        }
    }

    func loadTargets(for input: String) async {
        let service = LanguageAvailability()
        let inputLanguage = Locale.Language(identifier: input)
        let languages = await service.supportedLanguages
        var ids = Set<String>()
        for language in languages where language.languageCode != inputLanguage.languageCode {
            let extended = language.maximalIdentifier
            let id = extended.hasPrefix("zh-Hans") ? "zh-Hans" : extended.hasPrefix("zh-Hant") ? "zh-Hant" : language.minimalIdentifier
            if input == autoSource { ids.insert(id) }
            else if await service.status(from: inputLanguage, to: .init(identifier: id)) != .unsupported { ids.insert(id) }
        }
        guard !Task.isCancelled, sourceID == input else { return }
        loadingTargets = false
        targetOptions = ids.sorted { languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending }
        if !ids.contains(targetID), let fallback = ids.contains(defaultTarget) ? defaultTarget : targetOptions.first {
            targetID = fallback
        }
    }

    func chooseSource(_ id: String) {
        guard id != sourceID else { return }
        resetForSettings()
        loadingTargets = true
        targetOptions = []
        sourceID = id
        UserDefaults.standard.set(id, forKey: "sourceLanguage")
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
        if sourceID == autoSource && newMode == .mic {
            originalTask = Task { await self.startAutomatic(token) }
            return
        }
        if aiTranslation {
            guard targetOptions.contains(targetID), !loadingTargets else {
                stop("所选输入语言没有可用的转译目标，或仍在查询。可关闭 AI 转译，仅显示原文。")
                return
            }
            status = "正在准备本机翻译模型…"
            config = .init(source: source, target: .init(identifier: targetID))
        } else {
            status = "正在准备识别原文…"
            originalTask = Task { await self.run(nil, token: token) }
        }
    }

    func stop(_ message: String = "已停止 · 麦克风关闭") {
        generation = UUID()
        config = nil
        originalTask?.cancel()
        originalTask = nil
        if let worker, worker.isRunning { worker.terminate() }
        worker = nil
        // The writer task owns its pipe handle and closes it after input ends.
        workerWriter?.cancel()
        workerWriter = nil
        autoLanguage = nil
        autoSessionLanguage = nil
        rejectedAutoLanguage = nil
        autoEpoch = UUID()
        speechEnd = 0
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
            status = "正在下载苹果语音模型…"
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await install.downloadAndInstall()
            }
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                throw Fault("所选语音模型未安装，请联网后重试。")
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

    private func startAutomatic(_ token: UUID) async {
        do {
            let python = "/opt/homebrew/opt/openai-whisper/libexec/bin/python"
            let model = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/whisper/tiny.pt")
            guard FileManager.default.isExecutableFile(atPath: python), FileManager.default.fileExists(atPath: model.path),
                  let bridge = Bundle.main.url(forResource: "whisper_bridge", withExtension: "py") else {
                throw Fault("自动识别需要本机 Whisper 和多语言 tiny 模型。请参照 GitHub 安装说明，或手动选择输入语言。")
            }
            status = "等待麦克风权限…"
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard generation == token, !Task.isCancelled else { return }
            guard allowed else { throw Fault("请在系统设置中允许本应用使用麦克风。") }
            let audio = AVAudioEngine()
            let node = audio.inputNode
            let incoming = node.outputFormat(forBus: 0)
            guard incoming.sampleRate > 0, incoming.channelCount > 0,
                  let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
            else { throw Fault("找不到可用的麦克风。") }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-u", bridge.path, model.path]
            let input = Pipe(), outputPipe = Pipe()
            process.standardInput = input
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.stop("自动识别已结束，可重试或手动选择输入语言。")
                }
            }
            let reader = outputPipe.fileHandleForReading
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var pending = Data()
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    if pending.count > 1_000_000 { break }
                    while let newline = pending.firstIndex(of: 10) {
                        let line = Data(pending[..<newline])
                        pending.removeSubrange(...newline)
                        guard let event = try? JSONDecoder().decode(WhisperEvent.self, from: line) else { continue }
                        Task { @MainActor in
                            await self?.handleAutomatic(event, token: token)
                        }
                    }
                }
            }
            try process.run()
            worker = process
            let writer = input.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            let (sequence, sender) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(150))
            stream = sender
            workerWriter = Task.detached(priority: .userInitiated) {
                defer { try? writer.close() }
                for await packet in sequence {
                    if Task.isCancelled { break }
                    guard let floats = packet.buffer.floatChannelData?[0] else { continue }
                    let bytes = Data(bytes: floats, count: Int(packet.buffer.frameLength) * MemoryLayout<Float>.size)
                    do { try writer.write(contentsOf: bytes) } catch { break }
                }
            }
            try installMicrophoneTap(on: node, input: incoming, output: output, sender: sender)
            engine = audio
            audio.prepare()
            try audio.start()
            status = "正在启动本机自动识别…"
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            stop("未能继续：" + error.localizedDescription)
        }
    }

    private func handleAutomatic(_ event: WhisperEvent, token: UUID) async {
        guard generation == token, running else { return }
        if let error = event.error { stop("自动识别失败：" + error); return }
        if event.ready == true {
            preparing = false
            status = "自动识别中 · 每约 5 秒更新，不外放"
            return
        }
        guard let language = event.language, let text = event.text, !text.isEmpty else { return }
        if language != autoLanguage {
            autoEpoch = UUID()
            autoLanguage = language
            rejectedAutoLanguage = nil
            autoSessionLanguage = nil
            finals.removeAll()
            config = nil
            caption = ""
        }
        speechEnd += 1
        let p = Pending(text: text, final: true, end: speechEnd)
        transcript = text
        guard aiTranslation else { publish(text, for: p); return }
        if let rejected = rejectedAutoLanguage, rejected == language { publish(text, for: p); return }
        finals.append(p)
        if finals.count > 20 { finals.removeFirst(finals.count - 20) }
        if autoSessionLanguage != nil { return }
        let epoch = autoEpoch
        let input = Locale.Language(identifier: language)
        let output = Locale.Language(identifier: targetID)
        let support = await LanguageAvailability().status(from: input, to: output)
        guard generation == token, autoEpoch == epoch, autoSessionLanguage == nil, rejectedAutoLanguage == nil else { return }
        if input.languageCode == output.languageCode || support == .unsupported {
            rejectedAutoLanguage = language
            status = "已识别为" + languageName(language) + " · 不支持该语言组合，显示原文"
            let queued = finals
            finals.removeAll()
            for item in queued { publish(item.text, for: item) }
            return
        }
        autoSessionLanguage = input
        status = "已识别为" + languageName(language) + " · 正在准备翻译模型"
        config = .init(source: input, target: output)
    }

    private func runAutomaticTranslation(_ session: TranslationSession, token: UUID, epoch: UUID) async {
        guard generation == token, autoEpoch == epoch, let language = autoLanguage, let expected = autoSessionLanguage,
              session.sourceLanguage?.languageCode == expected.languageCode else { return }
        do {
            try await session.prepareTranslation()
            guard generation == token, epoch == autoEpoch, !Task.isCancelled else { return }
            status = "自动识别 · " + languageName(language) + " → " + languageName(targetID) + " · 不外放"
            while generation == token && epoch == autoEpoch && !Task.isCancelled {
                if let p = finals.first {
                    finals.removeFirst()
                    do {
                        let response = try await session.translate(p.text)
                        guard generation == token, epoch == autoEpoch, !Task.isCancelled else { return }
                        publish(response.targetText, for: p)
                    } catch {
                        guard generation == token, epoch == autoEpoch, !Task.isCancelled else { return }
                        publish(p.text, for: p)
                        throw error
                    }
                }
                try await Task.sleep(for: .milliseconds(90))
            }
        } catch {
            guard generation == token, epoch == autoEpoch, !Task.isCancelled else { return }
            rejectedAutoLanguage = language
            status = "无法准备所选翻译模型 · 暂显示原文"
            let queued = finals
            finals.removeAll()
            for item in queued { publish(item.text, for: item) }
        }
    }

    func run(_ session: TranslationSession?, token: UUID, epoch: UUID? = nil) async {
        if sourceID == autoSource, let session, let epoch { await runAutomaticTranslation(session, token: token, epoch: epoch); return }
        guard running, generation == token, (session != nil) == aiTranslation else { return }
        if let session,
           (session.targetLanguage?.maximalIdentifier != Locale.Language(identifier: targetID).maximalIdentifier ||
            session.sourceLanguage?.languageCode != source.languageCode) { return }
        do {
            if let session { try await session.prepareTranslation() }
            guard generation == token, !Task.isCancelled else { return }
            if mode == .sample {
                guard let code = source.languageCode?.identifier, var sample = samples[code] else { throw Fault("此输入语言尚无内置样例。") }
                if source.maximalIdentifier.hasPrefix("zh-Hant") { sample = "下週的會議在週二下午三點開始。" }
                let translated = try await session?.translate(sample).targetText ?? sample
                guard generation == token, !Task.isCancelled else { return }
                publish(translated, for: Pending(text: sample, final: true, end: 0))
                stop(session == nil ? "样例完成 · 仅显示原文，未使用麦克风" : "样例翻译完成 · 未使用麦克风")
                return
            }
            status = "等待麦克风权限…"
            let permission = await AVCaptureDevice.requestAccess(for: .audio)
            guard generation == token, !Task.isCancelled else { return }
            guard permission else {
                throw Fault("麦克风权限未开启。请到 系统设置 → 隐私与安全性 → 麦克风，允许本应用后重试。")
            }
            let input = Locale(identifier: sourceID)
            if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: input) {
                try await setup(SpeechTranscriber(locale: locale, preset: .progressiveTranscription), token: token) { String($0.text.characters) }
            } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: input) {
                try await setup(DictationTranscriber(locale: locale, preset: .progressiveLongDictation), token: token) { String($0.text.characters) }
            } else { throw Fault("这台 Mac 的本机语音模型不支持所选输入语言。") }
            guard generation == token, !Task.isCancelled else { return }
            preparing = false
            status = aiTranslation ? "正在收听所选语言 · 本机转译，不外放" : "正在收听所选语言 · 仅显示原文，不外放"
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

private struct WhisperEvent: Decodable, Sendable {
    let ready: Bool?
    let language: String?
    let text: String?
    let error: String?
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
        let epoch = model.autoEpoch
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("实时字幕").font(.system(size: 28, weight: .bold))
                    Text((model.autoLanguage.map(languageName) ?? languageName(model.sourceID)) + (model.aiTranslation ? "  →  " + (model.targetOptions.isEmpty ? "选择输出语言" : languageName(model.targetID)) : "  ·  仅原文")).foregroundStyle(.secondary)
                }
                Spacer()
                Button("测试样例") { model.begin(.sample) }.disabled(model.running || !model.sampleAvailable || (model.aiTranslation && model.loadingTargets))
                Button(model.running ? "停止" : "开始收听") {
                    if model.running { model.stop() } else { model.begin(.mic) }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            HStack(spacing: 14) {
                Picker("输入语言", selection: Binding(get: { model.sourceID }, set: { model.chooseSource($0) })) {
                    ForEach(model.sourceOptions, id: \.self) { id in Text(languageName(id)).tag(id) }
                }.frame(maxWidth: 265)
                Toggle("AI 转译", isOn: Binding(get: { model.aiTranslation }, set: { model.chooseAI($0) }))
                    .toggleStyle(.switch)
                Picker("输出语言", selection: Binding(get: { model.targetID }, set: { model.chooseTarget($0) })) {
                    if model.targetOptions.isEmpty { Text(model.loadingTargets ? "正在查询…" : "无支持目标").tag(model.targetID) }
                    ForEach(model.targetOptions, id: \.self) { id in Text(languageName(id)).tag(id) }
                }.frame(maxWidth: 265).disabled(!model.aiTranslation || model.targetOptions.isEmpty)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(model.caption.isEmpty ? (model.aiTranslation ? languageName(model.targetID) + "字幕将在这里显示" : "原文将在这里显示") : model.caption)
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
                Toggle("显示原文", isOn: $showJapanese).disabled(!model.aiTranslation)
                Toggle("窗口置顶", isOn: $floating)
                Spacer()
                Text("字号")
                Slider(value: $fontSize, in: 24...58).frame(width: 95).accessibilityLabel("字幕字号")
            }
            Text("本机处理 · 不保存录音 · 自动识别需 Whisper；手动模式使用苹果模型").font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).frame(minWidth: 620, minHeight: 440)
        .background(WindowProxy(floating: floating))
        .translationTask(model.config) { session in await model.run(session, token: token, epoch: epoch) }
        .task { await model.loadSources() }
        .task(id: model.sourceID) { await model.loadTargets(for: model.sourceID) }
        .onDisappear { model.stop() }

    }
}

@main struct LiveCaptionApp: App {
    var body: some Scene {
        Window("实时语音字幕", id: "captions") { CaptionView() }
            .defaultSize(width: 790, height: 525)
    }
}
