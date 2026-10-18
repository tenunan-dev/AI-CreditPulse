import AICreditPulseCore
import SwiftUI

/// The main program window: brand header with the live combined balance,
/// per-provider rows each with a private settings expansion (gear icon),
/// custom-provider management, and General options. Closing the window leaves
/// the app — and its menu bar agent — running; Quit terminates the program.
struct MainWindowView: View {
    @ObservedObject private var app = AppState.shared

    // Per-provider editor state
    @State private var keys: [String: String] = [:]      // builtin provider fields
    @State private var expandedID: String? = nil         // gear open on this row
    @State private var configuredCount = 0
    @State private var saveError: String?

    // Custom providers
    @State private var customs: [CustomProviderConfig] = []
    @State private var addingCustom = false

    private var builtinAdapters: [any ProviderAdapter] {
        ProviderRegistry.adapters.filter { $0 as? CustomProviderAdapter == nil }
    }
    private var customAdapters: [CustomProviderAdapter] {
        ProviderRegistry.adapters.compactMap { $0 as? CustomProviderAdapter }
    }

    /// Footer status: the configured count reflects the file, not the fields.
    private var statusText: String {
        if let saveError { return saveError }
        return "(\(configuredCount) of \(totalEnvKeys) keys set)"
    }

    private var totalEnvKeys: Int {
        let builtin = builtinAdapters.compactMap(\.credentialHints.first).count
        return builtin + customs.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                providersSection
                customProvidersSection
                generalSection
            }
            .formStyle(.grouped)
            HStack {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(saveError != nil ? Color.red : Color.secondary)
                    .frame(width: 170, alignment: .leading)
                Spacer()
                Text("Keys are stored locally — nothing leaves this machine.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Refresh statuses") {
                    Task { await app.refresh(force: true) }
                }
            }
            .padding([.horizontal, .bottom])
        }
        .frame(minWidth: 640, minHeight: 700)
        .onAppear(perform: loadAll)
        .task { await app.refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            PulseBadge(side: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI CreditPulse")
                    .font(.title2.weight(.semibold))
                Text(headline)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if app.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await app.refresh(force: true) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .padding(14)
    }

    /// Combined headline from the visible rows — mirrors the dropdown.
    private var headline: String {
        var parts: [String] = []
        let usd = app.combinedUSD
        let credits = app.combinedCredits
        if usd != 0 || credits == 0 { parts.append(String(format: "$%.2f", usd)) }
        if credits != 0 { parts.append(String(format: "%.2f credits", credits)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    // MARK: Providers (builtin) — one row per provider with its own gear editor

    private var providersSection: some View {
        Section("Providers — the gear on each row opens its settings") {
            ForEach(builtinAdapters, id: \.id) { adapter in
                providerRow(adapterID: adapter.id, label: adapter.label) {
                    providerKeyEditor(adapter)
                }
            }
        }
    }

    /// Shared row layout: visibility tick, live data row, trailing gear.
    /// The expansion (settings) appears below the row inline.
    private func providerRow<Settings: View>(
        adapterID: String, label: String,
        @ViewBuilder settings: @escaping () -> Settings
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Toggle("Show \(label)", isOn: visibilityBinding(adapterID))
                    .labelsHidden()
                    .controlSize(.small)
                    .padding(.top, 12)
                if let row = app.snapshot?.providers.first(where: { $0.id == adapterID }) {
                    ProviderRow(provider: row)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(label).font(.callout.weight(.medium))
                        Text("waiting for first refresh…")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Spacer(minLength: 8)
                // THE gear: every row carries its settings entry point.
                Button {
                    expandedID = expandedID == adapterID ? nil : adapterID
                } label: {
                    Image(systemName: expandedID == adapterID ? "xmark.circle.fill" : "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(expandedID == adapterID ? Color.secondary : Color.accentColor)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Settings for \(label)")
                .padding(.top, 8)
            }
            if expandedID == adapterID {
                settings()
                    .padding(.leading, 34)
                    .padding([.top, .bottom], 4)
                    .transition(.opacity)
            }
        }
    }

    /// Inline editor for a builtin provider's credential(s).
    @ViewBuilder
    private func providerKeyEditor(_ adapter: any ProviderAdapter) -> some View {
        let hints = adapter.credentialHints
        if let envKey = hints.first {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(envKey)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    configuredDot(envKey)
                    Spacer()
                    if adapter.id == "ilmu" {
                        // needs its special explanation right in the editor
                        Text("ILMU wants the ilmu_session cookie, not the sk- key.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    SecureField("Credential", text: binding(for: envKey))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .onSubmit { saveBuiltinKey(envKey) }
                    Button("Save") { saveBuiltinKey(envKey) }
                    if !hints.dropFirst().isEmpty {
                        Text("aliases:\(hints.dropFirst().joined(separator: " / "))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if let link = envLink(adapter.id) {
                        Spacer()
                        Link("Get key", destination: URL(string: link)!)
                    }
                }
            }
        } else {
            Text("Auth is discovered automatically from the local CLI (nothing to paste).")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func configuredDot(_ envKey: String) -> some View {
        if configured(envKey) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .help("\(envKey) has a value")
        } else {
            Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
                .help("\(envKey) is empty")
        }
    }

    private func configured(_ envKey: String) -> Bool {
        !(EnvStore.shared.key(envKey) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Custom providers — user-defined URL/key providers

    private var customProvidersSection: some View {
        Section("Custom providers — any OpenAI/Anthropic-style endpoint with a balance") {
            if customAdapters.isEmpty, !addingCustom {
                Text("None yet — add a relay, gateway, or self-hosted provider by pointing us at its balance URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(customAdapters, id: \.id) { adapter in
                customRow(adapter)
            }
            if addingCustom {
                CustomProviderEditor(
                    config: CustomProviderConfig(
                        id: "", name: "", authStyle: "openai", url: "",
                        remainingPath: "", limitPath: nil,
                        reportsPercentLeft: false, unit: "USD"),
                    isNew: true,
                    onSave: { config in
                        var all = CustomProviderStore.load()
                        if let idx = all.firstIndex(where: { $0.id == config.id }) {
                            all[idx] = config // same-name re-create updates instead
                        } else {
                            all.append(config)
                        }
                        try? CustomProviderStore.save(all)
                        addingCustom = false
                        expandedID = nil
                        loadAll()
                        Task { await app.refresh(force: true) }
                    },
                    onCancel: { addingCustom = false },
                    onDelete: nil,
                    onKeySave: { envKey, key in
                        try? EnvStore.shared.update([envKey: key])
                        Task { await app.refresh(force: true) }
                    })
            } else {
                Button {
                    addingCustom = true
                    expandedID = nil
                } label: {
                    Label("Add custom provider", systemImage: "plus")
                }
                .controlSize(.small)
            }
        }
    }

    private func customRow(_ adapter: CustomProviderAdapter) -> some View {
        let config = adapter.config
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Toggle("Show \(config.name)", isOn: visibilityBinding(adapter.id))
                    .labelsHidden()
                    .controlSize(.small)
                    .padding(.top, 12)
                if let row = app.snapshot?.providers.first(where: { $0.id == adapter.id }) {
                    ProviderRow(provider: row)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(config.name).font(.callout.weight(.medium))
                        Text("waiting for first refresh…")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Button {
                        expandedID = expandedID == adapter.id ? nil : adapter.id
                    } label: {
                        Image(systemName: expandedID == adapter.id ? "xmark.circle.fill" : "gearshape")
                            .font(.system(size: 14))
                            .foregroundStyle(expandedID == adapter.id ? Color.secondary : Color.accentColor)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Settings for \(config.name)")
                }
                .padding(.top, 8)
            }
            if expandedID == adapter.id {
                CustomProviderEditor(
                    config: config,
                    isNew: false,
                    onSave: { updated in
                        var all = CustomProviderStore.load()
                        if let idx = all.firstIndex(where: { $0.id == config.id }) {
                            all[idx] = updated
                        }
                        try? CustomProviderStore.save(all)
                        loadAll()
                        Task { await app.refresh(force: true) }
                    },
                    onCancel: { expandedID = nil },
                    onDelete: {
                        var all = CustomProviderStore.load()
                        all.removeAll { $0.id == config.id }
                        try? CustomProviderStore.save(all)
                        // deactivate credential and clear the key
                        try? EnvStore.shared.update([config.envKey: ""])
                        loadAll()
                        Task { await app.refresh(force: true) }
                    },
                    onKeySave: { envKey, key in
                        try? EnvStore.shared.update([envKey: key])
                        Task { await app.refresh(force: true) }
                    })
                    .padding(.leading, 34)
                    .padding([.top, .bottom], 4)
            }
        }
    }

    private var generalSection: some View {
        Section("General") {
            Picker("Refresh every", selection: Binding(
                get: { app.refreshMinutes },
                set: { app.refreshMinutes = $0 ?? 2 })) {
                ForEach(AppState.refreshChoices, id: \.self) { Text("\(Int($0)) min").tag($0) }
            }
            Toggle("Launch at login", isOn: launchBinding)
            Toggle("Pop up this window at launch", isOn: showWindowOnLaunchBinding)
            Toggle("Stay hidden when macOS auto-launches at restart", isOn: hideWindowAtLoginBinding)
        }
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { app.launchAtLogin },
            set: { app.launchAtLogin = $0; ServiceManagement.apply($0) })
    }

    private var showWindowOnLaunchBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.object(forKey: "showWindowOnLaunch") == nil
                ? true
                : UserDefaults.standard.bool(forKey: "showWindowOnLaunch") },
            set: { UserDefaults.standard.set($0, forKey: "showWindowOnLaunch") })
    }

    private var hideWindowAtLoginBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "hideWindowAtLoginLaunch") },
            set: { UserDefaults.standard.set($0, forKey: "hideWindowAtLoginLaunch") })
    }

    private func visibilityBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { app.isProviderVisible(id) },
            set: { app.setProviderVisible(id, $0) })
    }

    private func binding(for envKey: String) -> Binding<String> {
        Binding(
            get: { keys[envKey, default: EnvStore.shared.key(envKey) ?? ""] },
            set: { keys[envKey] = $0 })
    }

    private func saveBuiltinKey(_ envKey: String) {
        do {
            try EnvStore.shared.update([envKey: keys[envKey] ?? ""])
            saveError = nil
            updateCount()
            Task { await app.refresh(force: true) }
        } catch {
            saveError = "Couldn't write .env"
        }
    }

    private func envLink(_ id: String) -> String? {
        switch id {
        case "deepseek": "https://platform.deepseek.com/api_keys"
        case "openrouter": "https://openrouter.ai/keys"
        case "zai": "https://z.ai/manage-apikey/apikey-list"
        case "opencode": "https://opencode.ai/auth"
        case "ilmu": nil
        default: nil
        }
    }

    private func updateCount() {
        let envKeys = builtinAdapters.compactMap(\.credentialHints.first) + customs.map(\.envKey)
        configuredCount = envKeys.filter { configured($0) }.count
    }

    private func loadAll() {
        for adapter in builtinAdapters {
            if let envKey = adapter.credentialHints.first {
                keys[envKey] = EnvStore.shared.key(envKey) ?? ""
            }
        }
        customs = CustomProviderStore.load()
        updateCount()
    }
}

import ServiceManagement

/// Login-item via SMAppService (macOS 13+), persisted independently of the
/// UserDefaults flag so the system record is the source of truth.
enum ServiceManagement {
    @MainActor
    static func apply(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            // Registration failures (e.g. Xcode previews) are non-fatal; the
            // checkbox already reflects user intent and stays as stored.
        }
    }
}

// MARK: - Custom provider editor (add/edit + delete + key management)

/// A complete, self-contained editor for one custom provider: metadata, the
/// endpoint contract (URL + JSON paths), auth style, and the API key field.
struct CustomProviderEditor: View {
    @State var config: CustomProviderConfig
    let isNew: Bool
    let onSave: (CustomProviderConfig) -> Void
    let onCancel: () -> Void
    let onDelete: (() -> Void)?
    /// Writes (envKey, key) through the verified .env path.
    let onKeySave: (String, String) -> Void

    @State private var keyValue = ""
    @State private var keyConfigured = false
    @State private var formError: String?
    @State private var saveFlash = false

    /// The env slot this editor's key lives under: `config.envKey` once the id
    /// exists, otherwise derived from the typed name so "Save key" works in the
    /// add flow before "Create provider" is pressed.
    private var activeEnvKey: String {
        let slug = config.id.nonEmpty ? config.id : CustomProviderConfig.slug(config.name)
        return "CUSTOM_\(slug.uppercased().replacingOccurrences(of: "-", with: "_"))_API_KEY"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isNew {
                Text("New custom provider").font(.callout.weight(.medium))
            } else {
                HStack(spacing: 6) {
                    Text(config.envKey).font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Image(systemName: keyConfigured ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(keyConfigured ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                        .help(config.envKey)
                    Spacer()
                    Button("Delete provider", role: .destructive, action: onDelete ?? {})
                        .controlSize(.small)
                }
            }

            Form {
                TextField("Display name", text: $config.name)
                TextField("Balance URL", text: $config.url)
                    .textFieldStyle(.roundedBorder)
                Picker("Auth style", selection: $config.authStyle) {
                    Text("OpenAI-style (Bearer key)").tag("openai")
                    Text("Anthropic-style (x-api-key)").tag("anthropic")
                }
                .pickerStyle(.segmented)
                TextField("JSON path to REMAINING credit (e.g. data.total_credits)",
                          text: $config.remainingPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                TextField("Optional JSON path to LIMIT", text: limitBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Toggle("The path reports a % REMAINING (not an amount)",
                       isOn: $config.reportsPercentLeft)
                TextField("Unit (USD, EUR, credits…)", text: $config.unit)
                    .disabled(config.reportsPercentLeft)
            }
            .formStyle(.grouped)

            Text("Dot paths walk the JSON response; `[0]` indexes arrays — e.g. "
                 + "rate_limit.primary_window.remaining_percent.")
                .font(.caption2).foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                SecureField("API key for this provider", text: $keyValue)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onKeySave(activeEnvKey, keyValue) }
                Button("Save key") { onKeySave(activeEnvKey, keyValue) }
                    .disabled(keyValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                if let formError {
                    Text(formError).font(.caption).foregroundStyle(.red)
                } else if saveFlash {
                    Text("Saved ✓").font(.caption).foregroundStyle(.green)
                }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(isNew ? "Create provider" : "Save changes") {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(config.name.isEmpty || config.url.isEmpty
                          || config.remainingPath.isEmpty)
            }
        }
        .padding(.vertical, 2)
        .onAppear {
            keyConfigured = !(EnvStore.shared.key(activeEnvKey) ?? "").isEmpty
            keyValue = EnvStore.shared.key(activeEnvKey) ?? ""
        }
        .onChange(of: saveFlash) { _, fresh in
            guard fresh else { return }
            Task { try? await Task.sleep(for: .seconds(2)); await MainActor.run { saveFlash = false } }
        }
    }

    private var limitBinding: Binding<String> {
        Binding(
            get: { config.limitPath ?? "" },
            set: { config.limitPath = $0.isEmpty ? nil : $0 })
    }

    private func commit() {
        if config.id.isEmpty { config.id = CustomProviderConfig.slug(config.name) }
        guard let parsed = URL(string: config.url),
              parsed.scheme == "https" || parsed.scheme == "http" else {
            formError = "URL must be http(s)://…"
            return
        }
        guard CustomProviderConfig.slug(config.name).nonEmpty else {
            formError = "Name must contain letters or digits"
            return
        }
        formError = nil
        // The parent persists the config; the key then lands under the id-
        // derived env name, so creating + pasting a key is one flow.
        onSave(config)
        if keyValue.nonEmpty {
            onKeySave(activeEnvKey, keyValue)
        }
        saveFlash = true
    }
}

private extension String {
    var nonEmpty: Bool { !trimmingCharacters(in: .whitespaces).isEmpty }
}
