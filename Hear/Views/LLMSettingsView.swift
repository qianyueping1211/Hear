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
            } footer: {
                Text("点一下设为当前使用的 API；左滑可以编辑或删除。用于对话总结，翻译仍在本机离线完成。")
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
    @State private var apiKey = ""
    @State private var loading = false
    @State private var message = ""
    @State private var manualModel = ""
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
                        LLMSettings.shared.upsert(provider, key: apiKey)
                        if isNew { LLMSettings.shared.activeID = provider.id }
                        hearLog("大模型 API 已保存：\(provider.name) / \(provider.selectedModel)")
                        dismiss()
                    }
                    .disabled(provider.name.isEmpty || provider.baseURL.isEmpty)
                }
            }
            .onAppear {
                if !isNew { apiKey = LLMSettings.shared.key(for: provider) ?? "" }
            }
        }
    }

    private func fetchModels() async {
        loading = true
        message = ""
        defer { loading = false }
        do {
            let list = try await LLMClient.listModels(provider, key: apiKey)
            provider.models = list
            if !list.contains(provider.selectedModel) { provider.selectedModel = list.first ?? "" }
            message = "获取到 \(list.count) 个模型"
            hearLog("获取模型列表成功：\(provider.name)，\(list.count) 个")
        } catch {
            message = "获取失败：\(error.localizedDescription)"
            hearLog("获取模型列表失败：\(provider.name) \(error)", .error)
        }
    }
}
