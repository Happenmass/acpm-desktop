import AcpmClient
import AcpmRuntimeCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PlaygroundTabView: View {
    @Bindable var viewModel: RuntimeViewModel

    private enum PlaygroundMode: String, CaseIterable, Identifiable {
        case llm = "4B 思维链纠错"
        case audio = "CPU VAD & ASR"
        case tts = "音色克隆试听"

        var id: String { rawValue }
    }

    @State private var mode: PlaygroundMode = .llm
    @State private var showReasoningTrace = true
    @State private var audioDropTargeted = false
    @State private var copiedAnswer = false
    @State private var copiedTranscript = false

    var body: some View {
        VStack(alignment: .leading, spacing: AcpmTheme.Spacing.l) {
            switch mode {
            case .llm:
                llmPlaygroundView
            case .audio:
                audioPlaygroundView
            case .tts:
                ttsPlaygroundView
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("演练模式", selection: $mode) {
                    ForEach(PlaygroundMode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 360)
            }
        }
    }

    // MARK: - LLM Streaming CoT Playground

    private var llmPlaygroundView: some View {
        let llmModels = viewModel.models.filter { $0.capability == "llm" && $0.installed }
        return VStack(alignment: .leading, spacing: AcpmTheme.Spacing.m) {
            GlassCard {
                VStack(alignment: .leading, spacing: AcpmTheme.Spacing.m) {
                    HStack(spacing: AcpmTheme.Spacing.m) {
                        if !llmModels.isEmpty {
                            Picker("推理模型", selection: $viewModel.playgroundSelectedLLMId) {
                                ForEach(llmModels) { m in
                                    Text(m.displayName).tag(m.id)
                                }
                            }
                            .frame(maxWidth: 280)
                        } else {
                            HStack(spacing: AcpmTheme.Spacing.s) {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                Text("尚未绑定纠错模型")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("前往模型 →") {
                                    viewModel.selectedTab = .models
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                        }

                        Spacer()

                        Toggle("分离 CoT 思维链", isOn: $viewModel.playgroundSeparateReasoning)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    VStack(alignment: .leading, spacing: AcpmTheme.Spacing.xs) {
                        Text("System Prompt")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("系统提示词（可选）", text: $viewModel.playgroundSystemPrompt)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: AcpmTheme.Spacing.xs) {
                        Text("口述待纠错文本 / Prompt")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $viewModel.playgroundPrompt)
                            .font(.body)
                            .frame(height: 84)
                            .padding(6)
                            .background(
                                Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: AcpmTheme.innerCornerRadius)
                            )
                    }

                    HStack(spacing: AcpmTheme.Spacing.s) {
                        if let ttft = viewModel.playgroundLLMTtftMs {
                            StatusPill(
                                label: String(format: "TTFT %.0f ms", ttft),
                                color: .teal,
                                systemImage: "bolt"
                            )
                        }
                        if let total = viewModel.playgroundLLMTotalMs {
                            StatusPill(
                                label: String(format: "总耗时 %.0f ms", total),
                                color: .indigo,
                                systemImage: "clock"
                            )
                        }
                        Spacer()
                        if viewModel.playgroundLLMLoading {
                            Button("停止生成 (Esc)", role: .destructive) {
                                viewModel.stopPlaygroundLLM()
                            }
                            .buttonStyle(.bordered)
                            .keyboardShortcut(.escape, modifiers: [])
                        } else {
                            Button {
                                viewModel.runPlaygroundLLMStream()
                            } label: {
                                Label("发送流式推理 (⌘↩)", systemImage: "paperplane.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!viewModel.connected || llmModels.isEmpty)
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: AcpmTheme.Spacing.m) {
                if viewModel.playgroundSeparateReasoning {
                    GlassCard {
                        VStack(alignment: .leading, spacing: AcpmTheme.Spacing.s) {
                            HStack {
                                Label("思维链推理 (<think>)", systemImage: "brain.head.profile")
                                    .font(.headline)
                                Spacer()
                                Button(showReasoningTrace ? "收起" : "展开") {
                                    showReasoningTrace.toggle()
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                            if showReasoningTrace {
                                ScrollView {
                                    Text(
                                        viewModel.playgroundReasoningText.isEmpty
                                            ? "模型思考过程将在此流式展开…"
                                            : viewModel.playgroundReasoningText
                                    )
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(minHeight: 165, maxHeight: 240)
                            }
                        }
                    }
                }

                GlassCard(tint: .teal) {
                    VStack(alignment: .leading, spacing: AcpmTheme.Spacing.s) {
                        HStack {
                            Label("最终输出文本", systemImage: "text.bubble.fill")
                                .font(.headline)
                            Spacer()
                            if !viewModel.playgroundAnswerText.isEmpty {
                                Button {
                                    viewModel.copyToPasteboard(viewModel.playgroundAnswerText)
                                    copiedAnswer = true
                                    Task {
                                        try? await Task.sleep(for: .seconds(1.5))
                                        copiedAnswer = false
                                    }
                                } label: {
                                    Label(copiedAnswer ? "已复制" : "复制", systemImage: copiedAnswer ? "checkmark" : "doc.on.doc")
                                        .font(.caption2)
                                }
                                .controlSize(.mini)
                                .buttonStyle(.bordered)
                            }
                        }
                        ScrollView {
                            Text(
                                viewModel.playgroundAnswerText.isEmpty
                                    ? "流式纠错结果将在此实时呈现…"
                                    : viewModel.playgroundAnswerText
                            )
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 165, maxHeight: 240)
                    }
                }
            }
        }
    }

    // MARK: - CPU VAD + ASR Playground

    private var audioPlaygroundView: some View {
        let asrModels = viewModel.models.filter { $0.capability == "asr" && $0.installed }
        let audioTrimmed = viewModel.playgroundAudioPath.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: AcpmTheme.Spacing.m) {
            GlassCard(tint: audioDropTargeted ? AcpmTheme.brandCyan : nil) {
                VStack(alignment: .leading, spacing: AcpmTheme.Spacing.m) {
                    HStack {
                        Label("拖入音频文件至此卡片，执行 CPU VAD 人声切分与 MLX ASR 转写", systemImage: "waveform.and.mic")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if !asrModels.isEmpty {
                            Picker("ASR 模型", selection: $viewModel.playgroundSelectedAsrId) {
                                ForEach(asrModels) { m in
                                    Text(m.displayName).tag(m.id)
                                }
                            }
                            .frame(maxWidth: 240)
                        } else {
                            Button("绑定 ASR 模型 →") {
                                viewModel.selectedTab = .models
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }

                    HStack(spacing: AcpmTheme.Spacing.s) {
                        if audioTrimmed.isEmpty {
                            Image(systemName: "arrow.down.doc")
                                .foregroundStyle(.secondary)
                            Text("支持 WAV / M4A / MP3 / FLAC（拖放到此处或点击右侧按钮选择）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            let fileURL = URL(fileURLWithPath: audioTrimmed)
                            HStack(spacing: 6) {
                                Image(systemName: "music.note")
                                    .foregroundStyle(.teal)
                                Text(fileURL.lastPathComponent)
                                    .font(.caption.weight(.medium))
                                Button {
                                    viewModel.playgroundAudioPath = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, AcpmTheme.Spacing.s)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .help(RuntimeViewModel.abbreviateHomePath(audioTrimmed))
                        }

                        Spacer()

                        Button("选择音频…") {
                            pickAudioFile { path in
                                viewModel.playgroundAudioPath = path
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(AcpmTheme.Spacing.m)
                    .background(
                        audioDropTargeted ? AcpmTheme.brandCyan.opacity(0.14) : Color.primary.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: AcpmTheme.innerCornerRadius)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AcpmTheme.innerCornerRadius)
                            .strokeBorder(
                                audioDropTargeted ? AcpmTheme.brandCyan : Color.primary.opacity(0.10),
                                style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                            )
                    )

                    HStack(spacing: AcpmTheme.Spacing.s) {
                        if let vadMs = viewModel.playgroundVadMs {
                            StatusPill(label: String(format: "VAD %.0f ms", vadMs), color: .cyan)
                        }
                        if let asrMs = viewModel.playgroundAsrMs {
                            StatusPill(label: String(format: "ASR %.0f ms", asrMs), color: .teal)
                        }
                        Spacer()

                        if viewModel.playgroundAudioLoading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在分析音频…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Menu {
                            Button("仅运行 CPU VAD") {
                                Task { await viewModel.runPlaygroundVad(filePath: audioTrimmed) }
                            }
                            .disabled(audioTrimmed.isEmpty)

                            Button("运行 VAD + ASR 转写") {
                                Task { await viewModel.runPlaygroundAsr(filePath: audioTrimmed, runVadFirst: true) }
                            }
                            .disabled(audioTrimmed.isEmpty || asrModels.isEmpty)
                        } label: {
                            Label(
                                asrModels.isEmpty ? "运行 CPU VAD" : "转写 (VAD + ASR)",
                                systemImage: "waveform"
                            )
                        } primaryAction: {
                            if asrModels.isEmpty {
                                Task { await viewModel.runPlaygroundVad(filePath: audioTrimmed) }
                            } else {
                                Task { await viewModel.runPlaygroundAsr(filePath: audioTrimmed, runVadFirst: true) }
                            }
                        }
                        .disabled(!viewModel.connected || viewModel.playgroundAudioLoading || audioTrimmed.isEmpty)
                    }
                }
            }
            .dropDestination(for: URL.self) { items, _ in
                if let first = items.first, first.isFileURL {
                    viewModel.playgroundAudioPath = first.path
                    return true
                }
                return false
            } isTargeted: { audioDropTargeted = $0 }

            if let vad = viewModel.playgroundVadResult {
                GlassCard {
                    VadTimelineView(vadResponse: vad)
                }
            }

            if let asr = viewModel.playgroundAsrResult {
                GlassCard(tint: .teal) {
                    VStack(alignment: .leading, spacing: AcpmTheme.Spacing.s) {
                        HStack {
                            Label("ASR 转写结果", systemImage: "text.alignleft")
                                .font(.headline)
                            if let lang = asr.language {
                                StatusPill(label: lang.uppercased(), color: .teal)
                            }
                            Text("\(asr.durationMs) ms")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                viewModel.copyToPasteboard(asr.text)
                                copiedTranscript = true
                                Task {
                                    try? await Task.sleep(for: .seconds(1.5))
                                    copiedTranscript = false
                                }
                            } label: {
                                Label(copiedTranscript ? "已复制" : "复制文本", systemImage: copiedTranscript ? "checkmark" : "doc.on.doc")
                                    .font(.caption2)
                            }
                            .controlSize(.mini)
                            .buttonStyle(.bordered)
                        }

                        Text(asr.text)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding(AcpmTheme.Spacing.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: AcpmTheme.innerCornerRadius))

                        if !asr.segments.isEmpty {
                            Divider()
                            ForEach(Array(asr.segments.enumerated()), id: \.offset) { _, seg in
                                HStack(alignment: .top, spacing: AcpmTheme.Spacing.m) {
                                    Text(verbatim: "\(seg.startMs)–\(seg.endMs)ms")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 96, alignment: .leading)
                                    Text(seg.text)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - TTS Voice Clone Playground

    private var ttsPlaygroundView: some View {
        let ttsModel = viewModel.preferredInstalledTtsModel
        let isPlayingPlayground = viewModel.audioPreviewer.playingVoiceId == "__playground__"

        return GlassCard {
            VStack(alignment: .leading, spacing: AcpmTheme.Spacing.m) {
                HStack(spacing: AcpmTheme.Spacing.m) {
                    if viewModel.voices.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "person.wave.2")
                                .foregroundStyle(.orange)
                            Text("暂无参考音色")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("前往音色库 →") {
                                viewModel.selectedTab = .voices
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    } else {
                        Picker("参考音色", selection: $viewModel.playgroundSelectedVoiceId) {
                            ForEach(viewModel.voices) { voice in
                                Text(voice.name).tag(voice.voiceId)
                            }
                        }
                        .frame(maxWidth: 280)
                    }

                    Spacer()

                    if let ttsModel {
                        StatusPill(label: "\(ttsModel.displayName) 就绪", color: .green)
                    } else {
                        Button("绑定 TTS 模型 →") {
                            viewModel.selectedTab = .models
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }

                VStack(alignment: .leading, spacing: AcpmTheme.Spacing.xs) {
                    Text("合成台词文本")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $viewModel.playgroundTTSText)
                        .font(.body)
                        .frame(height: 110)
                        .padding(6)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: AcpmTheme.innerCornerRadius))
                }

                HStack(spacing: AcpmTheme.Spacing.s) {
                    if let durMs = viewModel.playgroundTTSLastDurationMs {
                        StatusPill(label: String(format: "合成 %.0f ms", durMs), color: .purple)
                    }
                    if let bytes = viewModel.playgroundTTSLastBytes {
                        Text("WAV \(HardwareAdvisor.formatBytes(UInt64(bytes)))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    if isPlayingPlayground {
                        Button("停止播放") {
                            viewModel.stopAudioPlayback()
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        Task {
                            await viewModel.runPlaygroundTTS(
                                voiceId: viewModel.playgroundSelectedVoiceId,
                                text: viewModel.playgroundTTSText
                            )
                        }
                    } label: {
                        if viewModel.playgroundTTSLoading {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.small)
                                Text("正在合成…")
                            }
                        } else {
                            Label("合成并试听", systemImage: "play.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.connected || viewModel.playgroundTTSLoading || ttsModel == nil)
                }
            }
        }
    }

    private func pickAudioFile(onSelect: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .wav, .mp3, .mpeg4Audio]
        if panel.runModal() == .OK, let url = panel.url {
            onSelect(url.path)
        }
    }
}
