import SwiftUI
import PulseCore
import PulseUI

/// What a symbol actually is. Opened from the detail page's corner link, and it
/// is this page — not that link — that goes and asks: a summary nobody opened
/// is a request nobody needed.
struct ProfileView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.pulseHost) private var host
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let symbol: SymbolID
    @Binding var route: PopoverRoute

    /// What the last attempt came back with. Nothing found and nothing reached
    /// are different outcomes: only the second one is worth retrying.
    private enum Outcome: Equatable {
        case pending
        case described(SecurityProfile)
        case undescribed
        case failed
    }

    private struct Attempt: Hashable {
        var symbol: SymbolID
        var count: Int
    }

    @State private var outcome: Outcome = .pending
    @State private var isLoading = false
    @State private var retries = 0

    var body: some View {
        VStack(spacing: 0) {
            PositionPageHeader(
                symbol: symbol,
                title: nil,
                onBack: { route = .detail(symbol) }
            )
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Loading → described/undescribed/failed swaps the page's whole body;
        // the search terminal states crossfade the same way.
        .animation(
            reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.18),
            value: outcome
        )
        .task(id: Attempt(symbol: symbol, count: retries)) {
            await load()
        }
    }

    private func load() async {
        // Cached for the day, so coming back is instant; the loader waits that
        // case out rather than flashing through it.
        let loaderDelay = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            isLoading = true
        }
        defer {
            loaderDelay.cancel()
            isLoading = false
        }
        do {
            let loaded = try await appState.engine.loadProfile(for: symbol)
            guard !Task.isCancelled else { return }
            outcome = loaded.map(Outcome.described) ?? .undescribed
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            outcome = .failed
        }
    }

    @ViewBuilder
    private var content: some View {
        switch outcome {
        case .described(let profile):
            summary(profile)
                .transition(.opacity)
        case .undescribed:
            // The source carries this symbol's prices but has nothing written
            // about it — common outside the large caps.
            ContentUnavailableView {
                Label(
                    PulseLocalization.localizedString("profile.unavailable"),
                    systemImage: "text.page"
                )
            }
            .frame(maxHeight: .infinity)
            .transition(.opacity)
        case .failed:
            failure
                .transition(.opacity)
        case .pending:
            if isLoading {
                PulseLoadingIndicator()
                    .transition(.opacity)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private func summary(_ profile: SecurityProfile) -> some View {
        let density = DetailDensity(host: host)
        let classification = [profile.sector, profile.industry]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // The summary reads in whatever language its source publishes; when
        // that is not the language the page is written in, say so quietly.
        let summaryLanguage = Locale(identifier: profile.localeIdentifier)
            .language.languageCode?.identifier
        let pageLanguage = Locale.current.language.languageCode?.identifier
        return ScrollView {
            VStack(alignment: .leading, spacing: density.sectionSpacing + 2) {
                if !classification.isEmpty || summaryLanguage != pageLanguage {
                    HStack(spacing: 6) {
                        ForEach(classification, id: \.self) { chip($0, density: density) }
                        Spacer(minLength: 8)
                        if summaryLanguage != pageLanguage {
                            languageTag(summaryLanguage, density: density)
                        }
                    }
                }
                DetailSectionHeader(
                    title: PulseLocalization.localizedString("detail.section.about"),
                    density: density
                )
                Text(profile.summary)
                    .font(.system(size: density == .compact ? 11.5 : 13))
                    .foregroundStyle(.primary)
                    .lineSpacing(density == .compact ? 3.5 : 4.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, density.horizontalPadding)
            .padding(.top, density == .compact ? 10 : 14)
            .padding(.bottom, density.horizontalPadding)
        }
        .softScrollEdgeEffect(for: .all)
    }

    /// One market classification ("食品饮料", "白酒") in a quiet capsule.
    private func chip(_ text: String, density: DetailDensity) -> some View {
        Text(text)
            .font(.system(size: density == .compact ? 9.5 : 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, density == .compact ? 7 : 9)
            .padding(.vertical, density == .compact ? 2.5 : 3.5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
            .fixedSize()
    }

    /// "🌐 English" for a summary the reader would otherwise meet unannounced.
    private func languageTag(_ code: String?, density: DetailDensity) -> some View {
        let name = code.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        return HStack(spacing: 3) {
            Image(systemName: "globe")
                .font(.system(size: density == .compact ? 8 : 9))
            if let name {
                Text(name)
            }
        }
        .font(.system(size: density == .compact ? 9 : 10, weight: .medium))
        .foregroundStyle(.tertiary)
        .help(PulseLocalization.localizedString("profile.summaryLanguage"))
    }

    /// Nothing was reached, which is not the same as nothing being there — so
    /// this offers to ask again rather than reporting an absence.
    private var failure: some View {
        VStack(spacing: 10) {
            Text(PulseLocalization.localizedString("profile.loadFailed"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(PulseLocalization.localizedString("action.retry")) {
                outcome = .pending
                retries += 1
            }
            .buttonStyle(.pressable)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tint)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
