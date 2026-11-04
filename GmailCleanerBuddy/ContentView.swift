// A tela única do app — a porta de www/index.html + style.css, com as
// mesmas cores do Google e os mesmos cartões.

import SwiftUI

private extension Color {
    static let gBlue = Color(red: 0x42 / 255, green: 0x85 / 255, blue: 0xF4 / 255)
    static let gGreen = Color(red: 0x34 / 255, green: 0xA8 / 255, blue: 0x53 / 255)
    static let gRed = Color(red: 0xEA / 255, green: 0x43 / 255, blue: 0x35 / 255)
    static let gYellow = Color(red: 0xFB / 255, green: 0xBC / 255, blue: 0x05 / 255)
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    TopBar()
                    if model.signedIn { ResultsCard() } else { AuthCard() }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 24)
            }
            .refreshable {
                if model.signedIn && !model.loading { await model.refreshAnalysis() }
            }

            if model.loading { LoadingOverlay() }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 18)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.toast)
        .alert(
            model.confirm?.message ?? "",
            isPresented: Binding(get: { model.confirm != nil }, set: { if !$0 { model.confirm = nil } }),
            presenting: model.confirm
        ) { pending in
            Button(model.t("btn.clean"), role: .destructive) {
                Task { await pending.action() }
            }
            Button(model.t("btn.cancel"), role: .cancel) {}
        }
        .environment(\.locale, model.lang.locale)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color(.separator).opacity(0.4)))
            .shadow(color: .black.opacity(0.06), radius: 20, y: 10)
    }
}

private struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Text("G")
                .font(.system(size: 26, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(
                    LinearGradient(colors: [.gBlue, .gGreen, .gYellow, .gRed],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Gmail Cleaner Buddy").font(.title3.weight(.black))
                Text(model.t("subtitle")).font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Menu {
                ForEach(Lang.allCases) { lang in
                    Button {
                        model.lang = lang
                    } label: {
                        Text("\(lang.flag)  \(lang.name)")
                        if lang == model.lang { Image(systemName: "checkmark") }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(model.lang.flag)
                    Text(model.lang.label).font(.subheadline.weight(.bold))
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator).opacity(0.4)))
            }
            .foregroundStyle(.primary)
            .accessibilityLabel(model.lang.name)
        }
    }
}

private struct AuthCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            VStack(spacing: 16) {
                Text(model.t("auth.title")).font(.title2.weight(.bold))
                Text(model.t("auth.desc"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await model.login() }
                } label: {
                    HStack(spacing: 12) {
                        Text("G")
                            .font(.title3.weight(.black))
                            .foregroundStyle(Color.gBlue)
                            .accessibilityHidden(true)
                        Text(model.t("auth.loginBtn")).font(.subheadline.weight(.black))
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 15)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(.separator), lineWidth: 2))
                }
                .foregroundStyle(.primary)
                Text(model.t("auth.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(30)
        }
    }
}

private struct ResultsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let data = model.data
        Card {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.t("results.title")).font(.title2.weight(.bold))
                    if !model.email.isEmpty {
                        Text("📧 \(model.email)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button(model.t("btn.cleanAll")) { model.askCleanAll() }
                        .buttonStyle(Pill(background: .gRed, foreground: .white))
                        .disabled(data?.top10.contains(where: { !$0.isProtected }) != true)
                    Button(model.t("btn.logout")) { model.logout() }
                        .buttonStyle(Pill(background: Color(.systemBackground), foreground: .primary))
                }

                if let data { Stats(data: data) }

                VStack(alignment: .leading, spacing: 0) {
                    Text(model.t("list.title"))
                        .font(.headline)
                        .padding(.bottom, 8)
                    if let data {
                        ForEach(data.top10) { item in
                            OffenderRow(item: item, rank: (data.offenders.firstIndex(of: item) ?? 0) + 1)
                            Divider()
                        }
                    }
                    Text(model.t("list.note"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                        .textSelection(.enabled)
                }
            }
            .padding(22)
        }
    }
}

private struct Pill: ButtonStyle {
    let background: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.black))
            .foregroundStyle(foreground)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(background, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(.separator).opacity(0.4)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct Stats: View {
    @Environment(AppModel.self) private var model
    let data: AnalyzeData

    var body: some View {
        // O "+" só quando a varredura bateu na trava de 1 milhão: ali é piso.
        let plus = data.mailboxCapped ? "+" : ""
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            stat(model.formatNumber(data.mailboxMessages) + plus, "stat.analyzed")
            stat(formatSize(data.offenders.reduce(0) { $0 + $1.size }), "stat.space")
            stat(model.formatNumber(data.uniqueSenders) + plus, "stat.senders")
            stat(model.formatNumber(data.offenders.prefix(10).reduce(0) { $0 + $1.count }), "stat.top10")
        }
    }

    private func stat(_ value: String, _ key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.weight(.black)).minimumScaleFactor(0.6).lineLimit(1)
            Text(model.t(key).uppercased()).font(.caption2.weight(.heavy)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}

private struct OffenderRow: View {
    @Environment(AppModel.self) private var model
    let item: Offender
    let rank: Int

    private var rankColors: [Color] {
        switch rank {
        case 1: return [.gRed, Color(red: 1, green: 0.42, blue: 0.42)]
        case 2: return [.gYellow, Color(red: 1, green: 0.88, blue: 0.44)]
        case 3: return [.gBlue, Color(red: 0.43, green: 0.66, blue: 1)]
        default: return [Color(.systemGray5), Color(.systemGray5)]
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.subheadline.weight(.black))
                .foregroundStyle(rank == 1 || rank == 3 ? Color.white : Color.primary)
                .frame(width: 36, height: 36)
                .background(LinearGradient(colors: rankColors, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.sender).font(.subheadline.weight(.bold)).lineLimit(1).truncationMode(.middle)
                    if item.isProtected {
                        Text("🔒").accessibilityLabel(model.t("protected.tooltip"))
                    }
                }
                Text("\(item.domain) · \(model.t(item.category))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(model.formatNumber(item.count)).font(.subheadline.weight(.black))
                    Text(formatSize(item.size)).font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button(model.t("btn.clean")) { model.askClean(item.sender) }
                .font(.caption.weight(.black))
                .buttonStyle(.borderedProminent)
                .tint(.gRed)
                .disabled(item.isProtected)
                .accessibilityHint(item.isProtected ? model.t("protected.tooltip") : "")
        }
        .padding(.vertical, 10)
    }
}

private struct LoadingOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(.white)
                // Mudos para o VoiceOver: mudam a cada e-mail lido. Quem fala é
                // o anúncio de fase em AppModel.reportProgress.
                Text(model.status)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .accessibilityHidden(true)
                if !model.hint.isEmpty {
                    Text(model.hint)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .accessibilityHidden(true)
                }
            }
            .padding(30)
        }
        // Bloqueia toques na tela por baixo enquanto trabalha.
        .contentShape(Rectangle())
    }
}
