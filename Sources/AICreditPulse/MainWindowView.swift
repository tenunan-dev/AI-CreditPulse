import AICreditPulseCore
import SwiftUI

/// The main program window: brand header with the live combined balance,
/// per-provider show/hide + live rows, API keys (persisted to .env), refresh and
/// quit. Closing the window leaves the app — and its menu bar agent — running;
/// Quit terminates the whole program.
struct MainWindowView: View {
    @ObservedObject private var app = AppState.shared
    @State private var keys: [String: String] = [:]
    @State private var savedFlash = false
    @State private var configuredCount = 0
    @State private var saveError: String?

    /// Footer status: permanent configured-count, a green confirmation for two
    /// seconds after each save, or the thrown error if the write failed.
    private var statusText: String {
        if let saveError { return saveError }
        if savedFlash { return "Saved ✓ — \(configuredCount) of \(keyFields.count) keys set" }
        return "(\(configuredCount) of \(keyFields.count) keys set)"
    }

    private func saveKeys() {
        var update: [String: String] = [:]
        for field in keyFields { update[field.envKey] = keys[field.envKey] ?? "" }
        do {
            try EnvStore.shared.update(update)
            // Verify by reading back — the count is the truth of the file,
            // not of the text fields.
            configuredCount = keyFields.filter {
                !(EnvStore.shared.key($0.envKey) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            }.count
            saveError = nil
            savedFlash = true
            // Make every row re-query immediately: failed samples are cached
            // by TTL, so a newly added key must force past them.
            Task { await app.refresh(force: true) }
            Task { try? await Task.sleep(for: .seconds(2)); await MainActor.run { savedFlash = false } }
        } catch {
            saveError = "Couldn't write .env"
        }
    }

    // The Settings UI presents the env key once per provider adapter.
    private var keyFields: [(adapterID: String, provider: String, envKey: String, hint: String, link: String?)] {
        var rows: [(String, String, String, String, String?)] = []
        for adapter in ProviderRegistry.adapters {
            let hints = adapter.credentialHints
            guard let first = hints.first else { continue }
            rows.append((adapter.id, adapter.label, first,
                         hints.dropFirst().joined(separator: " / "), envLink(adapter.id)))
        }
        return rows
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                providersSection
                keysSection
                generalSection
            }
            .formStyle(.grouped)
            HStack {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(savedFlash ? Color.green : Color.secondary)
                    .frame(width: 170, alignment: .leading)
                Spacer()
                Text("Keys are stored locally — nothing leaves this machine.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Save to .env", action: saveKeys)
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 620, height: 720)
        .onAppear(perform: loadKeys)
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

    /// One row per provider: show/hide checkbox + the same live row the
    /// dropdown renders, so the window is the full control surface, not a
    /// settings afterthought.
    private var providersSection: some View {
        Section("Providers — ticked rows appear in the dropdown and colour the badge") {
            ForEach(ProviderRegistry.adapters, id: \.id) { adapter in
                HStack(alignment: .top, spacing: 10) {
                    Toggle("Show \(adapter.label)", isOn: visibilityBinding(adapter.id))
                        .labelsHidden()
                        .controlSize(.small)
                        .padding(.top, 12)
                    if let row = app.snapshot?.providers.first(where: { $0.id == adapter.id }) {
                        ProviderRow(provider: row)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(adapter.label).font(.callout.weight(.medium))
                            Text("waiting for first refresh…")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var keysSection: some View {
        Section("API keys — stored in ~/Library/Application Support/AI CreditPulse/.env") {
            ForEach(keyFields, id: \.adapterID) { field in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(field.provider).font(.callout.weight(.medium))
                        HStack(spacing: 4) {
                            Text(field.envKey).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                            if !field.hint.isEmpty {
                                Text("(aliases: \(field.hint))").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Spacer()
                    if keys[field.envKey].map({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) == true {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help("\(field.envKey) has a value")
                    } else {
                        Image(systemName: "circle.dashed")
                            .foregroundStyle(.tertiary)
                            .help("\(field.envKey) is empty")
                    }
                    SecureField("API key", text: binding(for: field.envKey))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit(saveKeys)
                    if let link = field.link {
                        Link("Get key", destination: URL(string: link)!)
                    }
                }
            }
            // ILMU cookie explanation: the sk- key cannot read usage or balance.
            VStack(alignment: .leading, spacing: 2) {
                Text("ILMU uses the console session cookie (ilmu_session), not the sk- key.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("DevTools → Application → Cookies on console.ilmu.ai; paste the bare value.")
                    .font(.caption2).foregroundStyle(.secondary)
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

    private func loadKeys() {
        for field in keyFields {
            keys[field.envKey] = EnvStore.shared.key(field.envKey) ?? ""
        }
        configuredCount = keyFields.filter {
            !(EnvStore.shared.key($0.envKey) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }.count
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
