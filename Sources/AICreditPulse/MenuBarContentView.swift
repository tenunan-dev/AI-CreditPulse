import AICreditPulseCore
import SwiftUI

/// The menubar dropdown: shown rows with per-row show/hide ticks, combined
/// headline, footer actions. Row layout mirrors the Hermes card: headline
/// value, plan badge, window bars, safe error copy.
struct MenuBarContentView: View {
    @ObservedObject private var app = AppState.shared
    var openMain: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if app.visibleProviders.isEmpty {
                Text("No providers shown — tick rows in the main window")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(app.visibleProviders, id: \.id) { provider in
                    ProviderRow(provider: provider, showsVisibilityToggle: true,
                                isOn: visibilityBinding(provider.id))
                }
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 400)
        .task { await app.refresh() }
    }

    private func visibilityBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { app.isProviderVisible(id) },
            set: { app.setProviderVisible(id, $0) })
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            PulseBadge(side: 26).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Total balance")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(headline)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer()
            if app.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    /// Combined headline by unit over the visible rows — Σ USD rows first,
    /// credits grouped beneath (the /summary route's combined_balance rule).
    private var headline: String {
        let usd = app.combinedUSD
        let credits = app.combinedCredits
        var parts: [String] = []
        if usd != 0 || credits == 0 {
            parts.append(String(format: "$%.2f", usd))
        }
        if credits != 0 {
            parts.append(String(format: "%.2f credits", credits))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                Task { await app.refresh(force: true) }
            } label: {
                Label("Refresh now", systemImage: "arrow.clockwise")
            }
            Spacer()
            Button {
                // Not a settings sheet: the main program window.
                openMain?()
            } label: {
                Label("Open AI CreditPulse", systemImage: "macwindow")
            }
            .disabled(openMain == nil)
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .controlSize(.small)
    }
}

/// One provider row: show/hide tick (both surfaces), status dot, name,
/// headline, window bars, error copy.
struct ProviderRow: View {
    let provider: ProviderResult
    var showsVisibilityToggle = false
    var isOn: Binding<Bool>? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if showsVisibilityToggle, let isOn {
                Toggle("Show \(provider.label)", isOn: isOn)
                    .labelsHidden()
                    .controlSize(.mini)
                    .padding(.top, 2)
            }
            rows
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(provider.label).font(.callout.weight(.medium))
                if let plan = provider.plan {
                    Text(plan)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(headline).monospacedDigit().font(.callout)
            }
            if !provider.detail.isEmpty {
                Text(provider.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !provider.ok, let error = provider.error {
                Text(error).font(.caption2)
                    .foregroundStyle(provider.isUnconfigured ? Color.secondary : Color.red)
            }
            HStack(spacing: 4) {
                if let pct = provider.primaryUsagePercent {
                    UsageBar(label: "5h", percent: pct)
                }
                if let pct = provider.weeklyUsagePercent {
                    UsageBar(label: "wk", percent: pct)
                }
                if let pct = provider.monthlyUsagePercent {
                    UsageBar(label: "mo", percent: pct)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Green below 60%, amber from 60%, red from 90% or when limited/depleted
    /// (the card's exact thresholds). A zero balance on a paid account is red;
    /// with a free/trial plan it stays neutral grey. A row without a usable
    /// credential reads as idle grey — not configured yet, not a fault.
    private var dotColor: Color {
        if !provider.ok { return provider.isUnconfigured ? .gray : .red }
        if provider.limitReached { return .red }
        if provider.kind == .balance, let v = provider.value, v <= 0, !provider.unlimited {
            return ProviderRegistry.PlanFlags.isFreeOrTrial(provider.plan) ? .gray : .red
        }
        let windows = [provider.primaryUsagePercent, provider.weeklyUsagePercent, provider.monthlyUsagePercent].compactMap(\.self)
        if let maxUsed = windows.max() {
            if maxUsed >= 90 { return .red }
            if maxUsed >= 60 { return .orange }
        }
        return .green
    }

    private var headline: String {
        guard provider.ok else { return "—" }
        switch provider.kind {
        case .balance:
            guard provider.value != nil || provider.unlimited else { return "—" }
            if let v = provider.value {
                return String(format: "%@ %.2f", unitPrefix(provider.unit), v)
            }
            return "no cap"
        case .usage:
            guard let pct = provider.value else { return "—" }
            return String(format: "%.1f%%", pct)
        }
    }

    private func unitPrefix(_ unit: String) -> String {
        switch unit.uppercased() {
        case "USD": "$"
        case "MYR": "RM"
        case "CNY": "¥"
        default: ""
        }
    }
}

/// A single window bar with its tiny label; accent from 60%, red from 90%.
struct UsageBar: View {
    let label: String
    let percent: Double

    var body: some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(barColor).frame(width: max(2, geo.size.width * min(percent, 100) / 100))
                }
            }
            .frame(height: 5)
            .frame(maxWidth: 90)
        }
    }

    private var barColor: Color {
        if percent >= 90 { return .red }
        if percent >= 60 { return .orange }
        return .accentColor
    }
}
