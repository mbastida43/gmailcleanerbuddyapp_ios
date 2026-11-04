// Estado e ações da tela — a porta de src/app.ts. Os porquês de cada
// mensagem, do percentual único e da limpeza em ondas estão comentados lá.

import Observation
import SwiftUI
import UIKit

struct PendingConfirm {
    let message: String
    let action: () async -> Void
}

@Observable
@MainActor
final class AppModel {
    var lang: Lang = .initial {
        didSet { UserDefaults.standard.set(lang.rawValue, forKey: "lang") }
    }
    var signedIn = false
    var email = ""
    var data: AnalyzeData?
    var loading = false
    var status = ""
    var hint = ""
    var toast: String?
    var confirm: PendingConfirm?

    @ObservationIgnored let auth: Auth
    @ObservationIgnored let gmail: Gmail
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var announcedPhase: ProgressPhase?
    @ObservationIgnored private var lastPct = 0.0

    init() {
        auth = Auth()
        gmail = Gmail(auth: auth)
    }

    func t(_ key: String, _ params: [String: String] = [:]) -> String { lang.t(key, params) }

    func formatNumber(_ n: Int) -> String { n.formatted(.number.locale(lang.locale)) }

    // MARK: - Login

    func login() async {
        do {
            try await auth.signIn()
            showToast(t("toast.authSuccess"))
            await loadUserData()
        } catch AuthError.cancelled {
            // Fechar a folha de login não é falha: aviso neutro.
            showToast(t("toast.authCancelled"))
        } catch {
            let detail = describe(error)
            showToast(detail.isEmpty ? t("toast.authError") : t("toast.authErrorDetail", ["detail": detail]))
        }
    }

    func logout() {
        // Antes de tudo: os dados saem do aparelho mesmo que o resto falhe.
        FactsCache.clear()
        auth.signOut()
        showAuthScreen()
    }

    private func showAuthScreen() {
        data = nil
        email = ""
        signedIn = false
    }

    private func handleUnauthorized() {
        showToast(t("toast.sessionExpired"))
        showAuthScreen()
    }

    private func loadUserData() async {
        showLoading()
        defer { hideLoading() }
        do {
            email = try await gmail.profileEmail()
            signedIn = true
            await refreshAnalysis()
        } catch is UnauthorizedError {
            handleUnauthorized()
        } catch {
            let detail = describe(error)
            showToast(detail.isEmpty ? t("toast.loadError") : t("toast.loadErrorDetail", ["detail": detail]))
        }
    }

    // MARK: - Análise

    func refreshAnalysis() async {
        showLoading()
        defer { hideLoading() }
        showToast(t("toast.analyzing"))
        do {
            let result = try await gmail.analyze { [weak self] phase, done, total, firstRead in
                self?.reportProgress(phase, done, total, firstRead)
            }
            data = result
            if result.failedMessages > 0 {
                showToast(t("toast.analyzePartial", ["ok": formatNumber(result.analyzedMessages),
                                                     "failed": formatNumber(result.failedMessages)]))
            } else {
                showToast(t("toast.analyzeDone"))
            }
        } catch is UnauthorizedError {
            handleUnauthorized()
        } catch {
            let detail = describe(error)
            showToast(detail.isEmpty ? t("toast.analyzeError") : t("toast.analyzeErrorDetail", ["detail": detail]))
        }
    }

    // Um percentual só, de 0 a 100: a varredura fica com 5%, a leitura com o resto.
    private static let scanEnd = 5.0
    private static let scanCeiling = 20000.0

    private func reportProgress(_ phase: ProgressPhase, _ done: Int, _ total: Int, _ firstRead: Bool) {
        if phase == .scanning && done == 0 { lastPct = 0 }
        let pct: Double
        switch phase {
        case .scanning: pct = min(Self.scanEnd, Double(done) / Self.scanCeiling * Self.scanEnd)
        case .reading: pct = Self.scanEnd + (total > 0 ? Double(done) / Double(total) : 1) * (100 - Self.scanEnd)
        case .waiting: pct = lastPct
        }
        lastPct = max(lastPct, pct)
        let text = t(phase == .waiting ? "loading.waiting" : "loading.progress", ["pct": String(Int(lastPct))])
        status = text
        hint = firstRead && phase != .scanning ? t("loading.firstRead") : ""
        // VoiceOver: só a entrada na fase. O texto muda a cada e-mail.
        if phase != announcedPhase {
            announcedPhase = phase
            let spoken = phase == .waiting ? text : "\(t("loading.readingStart")) \(hint)".trimmingCharacters(in: .whitespaces)
            UIAccessibility.post(notification: .announcement, argument: spoken)
        }
    }

    // MARK: - Limpeza

    func askClean(_ sender: String) {
        confirm = PendingConfirm(message: t("confirm.cleanSender", ["sender": sender])) { [weak self] in
            await self?.cleanSender(sender)
        }
    }

    private func cleanSender(_ sender: String) async {
        showLoading()
        defer { hideLoading() }
        do {
            let r = try await gmail.clean(sender)
            showToast(t("toast.cleaned", ["n": formatNumber(r.removed)]))
            removeSendersLocally([sender])
        } catch is UnauthorizedError {
            handleUnauthorized()
        } catch CleanError.ownAddress {
            showToast(t("error.ownAddress"))
        } catch CleanError.ownAddressUnknown {
            showToast(t("error.ownAddressUnknown"))
        } catch {
            showToast("❌ \(describe(error))")
        }
    }

    func askCleanAll() {
        // "Limpar Tudo" = os 10 da tela, menos a própria conta.
        guard let targets = data?.top10.filter({ !$0.isProtected }), !targets.isEmpty else { return }
        let message = t("confirm.cleanAll", ["senders": formatNumber(targets.count),
                                             "emails": formatNumber(targets.reduce(0) { $0 + $1.count })])
        confirm = PendingConfirm(message: message) { [weak self] in
            await self?.cleanAll(targets.map(\.sender))
        }
    }

    private func cleanAll(_ targets: [String]) async {
        showLoading()
        var removed = 0
        var failed = 0
        var done = 0
        var unauthorized = false
        var ownUnknown = false
        var cleaned: [String] = []
        let gmail = self.gmail

        // Ondas de 4 com 700 ms de pausa: ~185 unidades/s, abaixo da cota.
        var i = 0
        while i < targets.count && !unauthorized {
            reportCleanProgress(done, targets.count)
            let wave = targets[i..<min(i + 4, targets.count)]
            await withTaskGroup(of: (String, Result<CleanResult, Error>).self) { group in
                for sender in wave {
                    group.addTask {
                        do { return (sender, .success(try await gmail.clean(sender))) }
                        catch { return (sender, .failure(error)) }
                    }
                }
                for await (sender, r) in group {
                    done += 1
                    switch r {
                    case .success(let c):
                        removed += c.removed
                        failed += c.failed
                        cleaned.append(sender)
                    case .failure(let e):
                        if e is UnauthorizedError { unauthorized = true }
                        else if (e as? CleanError) == .ownAddressUnknown { ownUnknown = true }
                        else { failed += 1 }
                    }
                }
            }
            i += 4
            if !unauthorized && i < targets.count {
                reportCleanProgress(done, targets.count, paused: true)
                try? await Task.sleep(for: .milliseconds(700))
            }
        }

        removeSendersLocally(cleaned)
        hideLoading()

        if unauthorized { handleUnauthorized() }
        else if ownUnknown { showToast(t("error.ownAddressUnknown")) }
        else if failed > 0 { showToast(t("toast.cleanAllPartial", ["removed": formatNumber(removed), "failed": formatNumber(failed)])) }
        else { showToast(t("toast.cleaned", ["n": formatNumber(removed)])) }
    }

    private func reportCleanProgress(_ done: Int, _ total: Int, paused: Bool = false) {
        let pct = total > 0 ? done * 100 / total : 0
        status = t(paused ? "loading.waiting" : "loading.cleaning", ["pct": String(pct)])
    }

    /// Tira da lista local sem refazer a análise (que leva minutos).
    private func removeSendersLocally(_ senders: [String]) {
        guard var d = data, !senders.isEmpty else { return }
        let gone = Set(senders)
        d.offenders.removeAll { gone.contains($0.sender) }
        d.top10 = top10Of(d.offenders, own: d.top10.filter(\.isProtected))
        d.uniqueSenders = d.offenders.count
        data = d
    }

    // MARK: - Overlay e avisos

    private func showLoading() {
        loading = true
        // Tela acesa enquanto trabalha: com a tela bloqueada o iOS suspende o
        // app e a leitura para (ela continua quando o app volta).
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func hideLoading() {
        loading = false
        UIApplication.shared.isIdleTimerDisabled = false
        status = ""
        hint = ""
        announcedPhase = nil
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    private func describe(_ error: Error) -> String {
        ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func formatSize(_ bytes: Int) -> String {
    let b = Double(bytes)
    if bytes < 1024 { return "\(bytes) B" }
    if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
    if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", b / (1024 * 1024)) }
    return String(format: "%.2f GB", b / (1024 * 1024 * 1024))
}
