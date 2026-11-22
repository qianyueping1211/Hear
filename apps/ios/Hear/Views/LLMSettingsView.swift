import SwiftUI

/// 设置 → 大模型 API
struct LLMSettingsView: View {
    @ObservedObject private var settings = LLMSettings.shared
    @State private var editing: LLMProvider?
    @State private var isNew = false

    var body: some View {
        List {
            Section {
                if settings.providers.isEmpty {
                    Text("还没有添加大模型 API").foregroundStyle(.secondary)
                }
                ForEach(settings.providers) { p in
                    Button {
                        settings.activeID = p.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).foregroundStyle(.primary)
                                Text(p.selectedModel.isEmpty ? "未选择模型" : p.selectedModel)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if p.id == settings.active?.id {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { settings.remove(p) } label: { Label("删除", systemImage: "trash") }
                        Button { isNew = false; editing = p } label: { Label("编辑", systemImage: "pencil") }.tint(.blue)
                    }
                    .contextMenu {
                        Button { isNew = false; editing = p } label: { Label("编辑", systemImage: "pencil") }
                        Button(role: .destructive) { settings.remove(p) } label: { Label("删除", systemImage: "trash") }
                    }
                }
            } header: {
                Text("已添加")
            }

            Section("添加") {
                Menu {
                    ForEach(LLMProvider.presets, id: \.name) { preset in
                        Button(preset.name) {
                            var p = preset
                            p.id = UUID()
                            isNew = true
                            editing = p
                        }
                    }
                } label: {
                    Label("添加大模型 API", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle("大模型 API")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { p in
            ProviderEditView(provider: p, isNew: isNew)
        }
    }
}

/// 编辑一个 API：名称、类型、地址、Key，获取模型列表并选择
struct ProviderEditView: View {
    @State var provider: LLMProvider
    let isNew: Bool
    @State private var plaintextKeyConfirmation = 0
    private var plaintextBodyIsApproved: Bool {
        _ = plaintextKeyConfirmation
        return LLMClient.isPlaintextBodyApproved(provider)
    }

    private var plaintextKeyIsApproved: Bool {
        _ = plaintextKeyConfirmation
        return LLMClient.isPlaintextKeyApproved(provider, key: apiKey)
    }
    @State private var apiKey = ""
    @State private var loading = false
    @State private var message = ""
    @State private var manualModel = ""
    @State private var keyLoaded = false     // Key 只在第一次打开时读一次，避免从选模型页返回时被覆盖
    @State private var savedOnce = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称", text: $provider.name)
                    Picker("接口类型", selection: $provider.kind) {
                        ForEach(LLMKind.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("接口地址", text: $provider.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    // 明文发送（http）的地址：把实际接收地址摆出来，让用户确认
                    if LLMClient.isPlaintextEndpoint(provider.baseURL) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("这个地址是明文发送（http）", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(.orange)
                            Text("实际接收地址：\(LLMClient.endpointDescription(provider.baseURL))。生成总结时，这段对话的原文和译文会明文发到这个地址（不加密）。")
                                .font(.caption).foregroundStyle(.secondary)
                            if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("你还填了 API Key：它也会用明文发出去，路上可能被别人看到。")
                                    .font(.caption).foregroundStyle(.red)
                                if plaintextKeyIsApproved {
                                    Text("已确认明文发送当前 API Key").font(.caption)
                                } else {
                                    Button("确认明文发送当前 API Key") {
                                        LLMClient.approvePlaintextKey(provider, key: apiKey)
                                        plaintextKeyConfirmation += 1
                                    }
                                    .font(.footnote)
                                }
                            }
                            if plaintextBodyIsApproved {
                                Text("已确认使用（明文发送）").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("我知道了，仍然使用（明文发送）") {
                                    LLMClient.approvePlaintextBody(provider)
                                    plaintextKeyConfirmation += 1
                                }
                                .font(.footnote)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        Task { await fetchModels() }
                    } label: {
                        HStack {
                            Label("获取模型列表", systemImage: "arrow.down.circle")
                            if loading { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(loading || provider.baseURL.isEmpty)

                    if !provider.models.isEmpty {
                        Picker("使用的模型", selection: $provider.selectedModel) {
                            Text("请选择").tag("")
                            ForEach(provider.models, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.navigationLink)
                    }
                    HStack {
                        TextField("或手动输入模型名", text: $manualModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("使用") {
                            let m = manualModel.trimmingCharacters(in: .whitespaces)
                            guard !m.isEmpty else { return }
                            if !provider.models.contains(m) { provider.models.append(m) }
                            provider.selectedModel = m
                            manualModel = ""
                        }
                    }
                } header: {
                    Text("模型")
                } footer: {
                    if !message.isEmpty { Text(message) }
                    else if !provider.selectedModel.isEmpty { Text("当前：\(provider.selectedModel)") }
                }
            }
            .navigationTitle(isNew ? "添加 API" : "编辑 API")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        saveNow()
                        dismiss()
                    }
                    .disabled(provider.name.isEmpty || provider.baseURL.isEmpty)
                }
            }
            .onAppear {
                guard !keyLoaded else { return }
                keyLoaded = true
                if !isNew { apiKey = LLMSettings.shared.key(for: provider) ?? "" }
            }
            // 选好模型后自动保存（获取过模型列表之后）
            .onChange(of: provider.selectedModel) { _, _ in
                if savedOnce { saveNow() }
            }
        }
    }

    /// 保存名称、地址、Key、模型列表和选中的模型。Key 输入框为空时保留原来保存的 Key
    private func saveNow() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalKey = key.isEmpty ? (LLMSettings.shared.key(for: provider) ?? "") : key
        LLMSettings.shared.upsert(provider, key: finalKey)
        if isNew && !savedOnce { LLMSettings.shared.activeID = provider.id }
        savedOnce = true
        let ok = !(LLMSettings.shared.key(for: provider) ?? "").isEmpty
        hearLog("大模型 API 已保存：\(provider.name) / \(provider.selectedModel)，Key \(ok ? "已保存" : "为空")",
                ok ? .info : .warning)
    }

    private func fetchModels() async {
        loading = true
        message = ""
        defer { loading = false }
        do {
            let list = try await LLMClient.listModels(provider, key: apiKey)
            provider.models = list
            if !list.contains(provider.selectedModel) { provider.selectedModel = list.first ?? "" }
            message = "获取到 \(list.count) 个模型，已连同 API Key 一起保存"
            hearLog("获取模型列表成功：\(provider.name)，\(list.count) 个")
            saveNow()      // 获取成功说明地址和 Key 都对，马上一起保存
        } catch {
            message = "获取失败：\(error.localizedDescription)"
            hearLog("获取模型列表失败：\(provider.name) \(error)", .error)
        }
    }
}
