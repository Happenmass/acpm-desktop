import AcpmClient
import AcpmRuntimeCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VoicesTabView: View {
    @Bindable var viewModel: RuntimeViewModel

    @State private var showAddVoiceSheet = false
    @State private var deleteTargetVoice: VoiceProfile?
    @State private var hoveredVoiceId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AcpmTheme.Spacing.l) {
            if viewModel.voices.isEmpty {
                EmptyStateCard(
                    systemImage: "waveform.and.mic",
                    title: "暂无参考音色",
                    subtitle: "上传一段 3–15 秒清晰人声（WAV / M4A / MP3），注册后即可在「演练台」和「批量合成」中复用 voice_id。",
                    actionTitle: viewModel.connected ? "注册参考音色" : nil,
                    action: viewModel.connected ? { showAddVoiceSheet = true } : nil
                )
            } else {
                ForEach(viewModel.voices) { voice in
                    let isPlaying = viewModel.audioPreviewer.playingVoiceId == voice.voiceId
                    let isHovered = hoveredVoiceId == voice.voiceId

                    GlassCard(padding: AcpmTheme.Spacing.m) {
                        HStack(spacing: AcpmTheme.Spacing.m) {
                            Image(systemName: isPlaying ? "waveform.circle.fill" : "person.wave.2.fill")
                                .font(.title2)
                                .foregroundStyle(isPlaying ? .purple : AcpmTheme.brandIndigo)
                                .symbolEffect(.variableColor.iterative, isActive: isPlaying)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: AcpmTheme.Spacing.s) {
                                    Text(voice.name)
                                        .font(.headline)
                                    Text(verbatim: voice.voiceId)
                                        .font(.caption2.monospaced())
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.07), in: Capsule())
                                    if let lang = voice.language {
                                        Text(lang.uppercased())
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("\(voice.durationMs) ms")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }

                                if let refText = voice.referenceText, !refText.isEmpty {
                                    Text("参考文本：\(refText)")
                                        .font(.caption)
                                        .lineLimit(1)
                                }

                                if let notes = voice.notes, !notes.isEmpty {
                                    Text("备注：\(notes)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            HStack(spacing: AcpmTheme.Spacing.s) {
                                Button(isPlaying ? "停止" : "试听") {
                                    Task { await viewModel.togglePlayVoiceSample(voice.voiceId) }
                                }
                                .buttonStyle(.bordered)

                                Button("用于演练台") {
                                    viewModel.playgroundSelectedVoiceId = voice.voiceId
                                    viewModel.selectedTab = .playground
                                }
                                .buttonStyle(.bordered)

                                Menu {
                                    Button("复制 voice_id") {
                                        viewModel.copyToPasteboard(voice.voiceId, notice: "已复制 voice_id")
                                    }
                                    Divider()
                                    Button("删除音色…", role: .destructive) {
                                        deleteTargetVoice = voice
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .foregroundStyle(isHovered ? .primary : .secondary)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                            .controlSize(.small)
                        }
                    }
                    .onHover { hoveredVoiceId = $0 ? voice.voiceId : nil }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showAddVoiceSheet = true
                } label: {
                    Label("注册音色", systemImage: "plus")
                }
                .disabled(!viewModel.connected)
                .help("上传参考音频注册音色克隆档案")
            }
        }
        .sheet(isPresented: $showAddVoiceSheet) {
            AddVoiceSheet(viewModel: viewModel)
        }
        .confirmationDialog(
            "删除参考音色？",
            isPresented: Binding(
                get: { deleteTargetVoice != nil },
                set: { if !$0 { deleteTargetVoice = nil } }
            ),
            presenting: deleteTargetVoice
        ) { target in
            Button("删除音色", role: .destructive) {
                Task { await viewModel.deleteVoice(target.voiceId) }
            }
            Button("取消", role: .cancel) {}
        } message: { target in
            Text("将删除「\(target.name)」(\(target.voiceId)) 及其本地音频样本，此操作不可撤销。")
        }
    }
}

private struct AddVoiceSheet: View {
    @Bindable var viewModel: RuntimeViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var audioPath = ""
    @State private var referenceText = ""
    @State private var language = "zh"
    @State private var notes = ""
    @State private var submitting = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: AcpmTheme.Spacing.m) {
            Text("注册参考音色")
                .font(.title3.bold())

            TextField("音色名称（必填，如「沉稳男声」）", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("拖拽或选择人声样本 (.wav / .m4a / .mp3)", text: $audioPath)
                    .textFieldStyle(.roundedBorder)
                Button("选择文件…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.allowedContentTypes = [.audio, .wav, .mp3, .mpeg4Audio]
                    if panel.runModal() == .OK, let url = panel.url {
                        audioPath = url.path
                        if name.isEmpty {
                            name = url.deletingPathExtension().lastPathComponent
                        }
                    }
                }
            }
            .padding(AcpmTheme.Spacing.s)
            .background(
                dropTargeted ? AcpmTheme.brandCyan.opacity(0.14) : Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: AcpmTheme.innerCornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AcpmTheme.innerCornerRadius)
                    .strokeBorder(
                        dropTargeted ? AcpmTheme.brandCyan : Color.primary.opacity(0.10),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
            .dropDestination(for: URL.self) { items, _ in
                if let first = items.first, first.isFileURL {
                    audioPath = first.path
                    if name.isEmpty {
                        name = first.deletingPathExtension().lastPathComponent
                    }
                    return true
                }
                return false
            } isTargeted: { dropTargeted = $0 }

            TextField("参考文本（建议填写样本对应台词，显著提升相似度）", text: $referenceText)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("语言 (如 zh / en)", text: $language)
                    .textFieldStyle(.roundedBorder)
                TextField("备注（可选）", text: $notes)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button(submitting ? "正在注册…" : "保存注册") {
                    submitting = true
                    Task {
                        let ok = await viewModel.registerVoice(
                            name: name,
                            referenceAudio: audioPath,
                            referenceText: referenceText,
                            language: language,
                            notes: notes
                        )
                        submitting = false
                        if ok {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(submitting || name.trimmingCharacters(in: .whitespaces).isEmpty || audioPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(AcpmTheme.Spacing.xl)
        .frame(width: 500)
    }
}
