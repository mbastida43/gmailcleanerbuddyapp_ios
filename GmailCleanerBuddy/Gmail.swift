// ============================================================
// Camada Gmail: porta de src/gmail.ts do app Android, com a mesma regra:
// CONTAGEM EXATA, mensagem por mensagem. Nenhum número na tela é amostra,
// estimativa ou extrapolação.
// - varre os ids da caixa inteira (sem metadado, barato)
// - lê o remetente de TODAS as mensagens, uma a uma, e guarda o que aprendeu
//   (remetente e tamanho de uma mensagem nunca mudam): só id inédito custa
//   leitura
// - limpeza via batchModify (até 1000 ids, TRASH + tira INBOX), com
//   messages.trash individual de plano B
// Os porquês de cada número e de cada consulta estão comentados em
// src/gmail.ts; aqui ficam só os que mudaram no iOS.
// ============================================================

import CryptoKit
import Foundation
import UIKit

// Mesmos números do Android — vêm da cota do Gmail (250 unidades/s por
// usuário, messages.get custa 5), não da plataforma.
private let MAX_PAGES = 2000
private let READ_CONCURRENCY = 20
private let READ_PER_SEC = 45.0
private let MAX_RETRIES = 5
private let RETRY_STATUS: Set<Int> = [429, 500, 502, 503, 504]
private let AUTH_REASONS: Set<String> = ["authError", "unauthorized", "invalidCredentials"]

/// O que se sabe de uma mensagem. `sender` vazio = lida e sem remetente
/// utilizável (rascunho, chat, cabeçalho corrompido).
struct MsgFacts: Equatable {
    var sender: String
    var size: Int
}

struct Offender: Identifiable, Equatable {
    var id: String { sender }
    let sender: String
    let domain: String
    let count: Int
    let size: Int
    let category: String
    let isProtected: Bool
}

enum ProgressPhase { case scanning, reading, waiting }

struct AnalyzeData {
    var totalMessages: Int
    var analyzedMessages: Int
    var failedMessages: Int
    var unattributedMessages: Int
    var uniqueSenders: Int
    var mailboxMessages: Int
    var mailboxCapped: Bool
    var offenders: [Offender]
    var top10: [Offender]
}

struct CleanResult {
    var removed: Int
    var failed: Int
}

struct UnauthorizedError: Error {}

/// Falha da API do Gmail que NÃO se resolve refazendo o login.
struct GmailAPIError: LocalizedError {
    let status: Int
    let reason: String
    let message: String
    var errorDescription: String? {
        !message.isEmpty ? message : !reason.isEmpty ? reason : "gmail_api_\(status)"
    }
}

enum CleanError: String, LocalizedError {
    case invalidSender = "invalid_sender"
    case ownAddress = "own_address"
    case ownAddressUnknown = "own_address_unknown"
    var errorDescription: String? { rawValue }
}

// MARK: - Funções puras (testadas em GmailCleanerBuddyTests)

/// Codifica para query string / corpo de formulário. Mais rígido que o
/// URLComponents de propósito: ele deixa o "+" passar, e o Google lê "+" como
/// espaço — `from:"a+b@x.com"` viraria outro remetente.
func formEncode(_ items: [(String, String)]) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return items
        .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
        .joined(separator: "&")
}

func validateSender(_ sender: String) -> Bool {
    sender.range(of: "^[a-zA-Z0-9@._%+-]{3,254}$", options: .regularExpression) != nil
}

/// Endereço do cabeçalho From, em minúsculas; "" se não houver um válido.
func parseSender(_ from: String?) -> String {
    guard let from else { return "" }
    let raw = firstGroup("<(.+?)>", in: from) ?? firstGroup("([^\\s]+@[^\\s]+)", in: from) ?? from
    let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return validateSender(email) ? email : ""
}

private func firstGroup(_ pattern: String, in text: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let r = Range(m.range(at: 1), in: text)
    else { return nil }
    return String(text[r])
}

/// Host do endereço — só para exibição, nunca para agrupar.
func domainOf(_ email: String) -> String {
    guard let at = email.lastIndex(of: "@"), at != email.startIndex else { return email }
    return String(email[email.index(after: at)...])
}

/// O Gmail ignora pontos e o +sufixo, e googlemail.com é o mesmo domínio.
func accountKey(_ email: String) -> String {
    let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let at = e.lastIndex(of: "@") else { return e }
    var local = String(e[..<at])
    var domain = String(e[e.index(after: at)...])
    if domain == "googlemail.com" { domain = "gmail.com" }
    if domain == "gmail.com" {
        local = String(local.split(separator: "+", omittingEmptySubsequences: false).first ?? "")
            .replacingOccurrences(of: ".", with: "")
    }
    return "\(local)@\(domain)"
}

func isOwnAddress(_ sender: String, _ ownEmail: String) -> Bool {
    !ownEmail.isEmpty && accountKey(sender) == accountKey(ownEmail)
}

/// Os 10 maiores e, SEMPRE, a própria conta — mesmo fora do top 10.
func top10Of(_ offenders: [Offender], own: [Offender]) -> [Offender] {
    let top = Array(offenders.prefix(10))
    return top + own.filter { !top.contains($0) }
}

/// Devolve uma CHAVE de tradução, não texto pronto.
func categorizeSender(_ email: String) -> String {
    let d = email.lowercased()
    func has(_ words: String...) -> Bool { words.contains { d.contains($0) } }
    if has("linkedin", "facebook", "instagram") { return "cat.social" }
    if has("google", "youtube") { return "cat.google" }
    if has("github", "gitlab") { return "cat.devops" }
    if has("ifood", "uber") { return "cat.delivery" }
    if has("amazon") { return "cat.shopping" }
    if has("canva", "figma") { return "cat.design" }
    if has("cloudflare", "aws") { return "cat.infra" }
    if has("slack", "teams") { return "cat.collab" }
    if has("news", "nytimes") { return "cat.news" }
    if has("medium", "substack") { return "cat.content" }
    return "cat.other"
}

/// Conta remetentes a partir do que se sabe de cada id. Derivar no fim, em vez
/// de incrementar durante a leitura, é o que garante "cada mensagem conta uma
/// vez": o dicionário é chaveado por id.
func buildAnalysis(facts: [String: MsgFacts], ownEmail: String, failed: Int, capped: Bool) -> AnalyzeData {
    var counts: [String: Int] = [:]
    var sizes: [String: Int] = [:]
    var unattributed = 0
    for f in facts.values {
        if f.sender.isEmpty { unattributed += 1; continue }
        counts[f.sender, default: 0] += 1
        sizes[f.sender, default: 0] += f.size
    }
    let offenders = counts
        .map { email, count in
            Offender(sender: email, domain: domainOf(email), count: count, size: sizes[email] ?? 0,
                     category: categorizeSender(email), isProtected: isOwnAddress(email, ownEmail))
        }
        // Empate desempatado pelo endereço: a ordem não muda entre análises.
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.sender < $1.sender }
    let total = facts.count + failed
    return AnalyzeData(
        totalMessages: total, analyzedMessages: facts.count, failedMessages: failed,
        unattributedMessages: unattributed, uniqueSenders: offenders.count,
        mailboxMessages: total, mailboxCapped: capped,
        offenders: offenders, top10: top10Of(offenders, own: offenders.filter(\.isProtected))
    )
}

// MARK: - Cache por id

/// Remetente e tamanho por id, por conta. Fica em Caches: o iOS não faz
/// backup dessa pasta (o equivalente ao allowBackup=false do Android) e pode
/// apagá-la se faltar espaço — custa só uma próxima análise lenta.
enum FactsCache {
    private struct Stored: Codable {
        var senders: [String]
        var msgs: [String: [Int]]
    }

    private static var dir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("msgfacts-v1", isDirectory: true)
    }

    /// Nome do arquivo é o hash do endereço: o endereço não fica à vista.
    private static func file(_ email: String) -> URL {
        let hash = SHA256.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(hash + ".json")
    }

    static func load(_ email: String) -> [String: MsgFacts] {
        // Cache corrompido é cache ausente: a análise relê e reescreve.
        guard let data = try? Data(contentsOf: file(email)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return [:] }
        var facts: [String: MsgFacts] = [:]
        for (id, entry) in stored.msgs where entry.count == 2 {
            let i = entry[0]
            facts[id] = MsgFacts(sender: stored.senders.indices.contains(i) ? stored.senders[i] : "", size: entry[1])
        }
        return facts
    }

    /// Remetentes numa lista e cada mensagem aponta o índice: um endereço como
    /// groups-noreply@linkedin.com se repete milhares de vezes.
    static func save(_ email: String, _ facts: [String: MsgFacts]) {
        var index: [String: Int] = [:]
        var senders: [String] = []
        var msgs: [String: [Int]] = [:]
        for (id, f) in facts {
            let i: Int
            if let known = index[f.sender] {
                i = known
            } else {
                i = senders.count
                senders.append(f.sender)
                index[f.sender] = i
            }
            msgs[id] = [i, f.size]
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(Stored(senders: senders, msgs: msgs)).write(to: file(email), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: file(email))
        }
    }

    /// Apaga o cache de TODAS as contas. Chamado no Sair.
    static func clear() {
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - API

@MainActor
final class Gmail {
    private static let base = "https://gmail.googleapis.com/gmail/v1/users/me"

    private let auth: Auth
    /// Endereço próprio, chaveado pelo token: trocou de conta, trocou o token.
    private var ownEmailCache: (token: String, email: String)?

    init(auth: Auth) { self.auth = auth }

    // Fundo = o iOS suspende o app e a rede cai. Em vez de falhar, a leitura
    // espera o app voltar para a tela e continua de onde parou — o mesmo que o
    // Android faz com a tela apagada.
    private var isBackground: Bool { UIApplication.shared.applicationState == .background }

    private func waitForeground() async {
        while isBackground { try? await Task.sleep(for: .seconds(1)) }
    }

    /// Renova só com o app na tela; 3 falhas com o app na tela = desiste.
    private func renewWhenForeground() async -> Bool {
        var failures = 0
        while true {
            await waitForeground()
            if await auth.renew() { return true }
            if isBackground { continue }
            failures += 1
            if failures >= 3 { return false }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func liveToken() async throws -> String {
        if let t = auth.accessToken() { return t }
        if await renewWhenForeground(), let t = auth.accessToken() { return t }
        throw UnauthorizedError()
    }

    @discardableResult
    private func gfetch(_ path: String, method: String = "GET", json: [String: Any]? = nil) async throws -> [String: Any] {
        var renewals = 0
        var netFailures = 0
        var attempt = 0
        while true {
            let token = try await liveToken()
            var req = URLRequest(url: URL(string: Self.base + path)!)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let json {
                req.httpBody = try JSONSerialization.data(withJSONObject: json)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let data: Data
            let status: Int
            do {
                let (d, r) = try await URLSession.shared.data(for: req)
                data = d
                status = (r as? HTTPURLResponse)?.statusCode ?? 0
            } catch {
                // Sem rede: repete o MESMO pedido. No fundo, espera voltar; na
                // tela, ~20 s de paciência.
                if isBackground { await waitForeground(); continue }
                netFailures += 1
                if netFailures > 10 { throw error }
                try? await Task.sleep(for: .seconds(2))
                continue
            }

            if (200..<300).contains(status) {
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            }

            let (reason, message) = Self.apiError(data)
            if status == 401 || (status == 403 && AUTH_REASONS.contains(reason)) {
                if renewals < 3 {
                    renewals += 1
                    if await renewWhenForeground() { continue }
                }
                throw UnauthorizedError()
            }
            let retriable = RETRY_STATUS.contains(status)
                || (status == 403 && reason.range(of: "rateLimitExceeded", options: .caseInsensitive) != nil)
            if !retriable || attempt >= MAX_RETRIES {
                throw GmailAPIError(status: status, reason: reason, message: message)
            }
            // 300ms, 600, 1200, 2400, 4800
            try? await Task.sleep(for: .milliseconds(300 * (1 << attempt)))
            attempt += 1
        }
    }

    private static func apiError(_ data: Data) -> (reason: String, message: String) {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let err = body?["error"] as? [String: Any]
        let first = (err?["errors"] as? [[String: Any]])?.first
        let reason = first?["reason"] as? String ?? err?["status"] as? String ?? ""
        return (reason, err?["message"] as? String ?? "")
    }

    func profileEmail() async throws -> String {
        try await gfetch("/profile")["emailAddress"] as? String ?? ""
    }

    /// `required`: na análise, falha vira "" (só some o cadeado); na limpeza,
    /// lança — trava que não sabe o que proteger recusa, nunca libera.
    private func ownEmail(required: Bool) async throws -> String {
        let token = try await liveToken()
        if let c = ownEmailCache, c.token == token { return c.email }
        do {
            let email = try await profileEmail().trimmingCharacters(in: .whitespaces).lowercased()
            if email.isEmpty { throw GmailAPIError(status: 0, reason: "empty_profile_email", message: "") }
            ownEmailCache = (token, email)
            return email
        } catch is UnauthorizedError {
            throw UnauthorizedError()
        } catch {
            if required { throw CleanError.ownAddressUnknown }
            return ""
        }
    }

    /// `firstRead`: o cache desta conta estava vazio — a leitura demorada.
    func analyze(progress: @escaping @MainActor (ProgressPhase, Int, Int, Bool) -> Void) async throws -> AnalyzeData {
        let ownEmail = try await ownEmail(required: false)

        // 1) Varredura: ids da caixa INTEIRA. Mesmo escopo da limpeza — com
        // Spam, sem Lixeira. Set: a paginação repete ids na virada de página.
        progress(.scanning, 0, 0, false)
        var seen = Set<String>()
        var pageToken: String?
        var pages = 0
        repeat {
            var q = [("q", "in:anywhere -in:trash"), ("maxResults", "500"),
                     ("includeSpamTrash", "true"), ("fields", "messages/id,nextPageToken")]
            if let pageToken { q.append(("pageToken", pageToken)) }
            let resp = try await gfetch("/messages?" + formEncode(q))
            for m in resp["messages"] as? [[String: Any]] ?? [] {
                if let id = m["id"] as? String { seen.insert(id) }
            }
            pageToken = resp["nextPageToken"] as? String
            pages += 1
            progress(.scanning, seen.count, 0, false)
        } while pageToken != nil && pages < MAX_PAGES
        let capped = pageToken != nil

        // 2) O que já se sabe sai do cache; o resto é lido.
        let cached = ownEmail.isEmpty ? [:] : FactsCache.load(ownEmail)
        let firstRead = cached.isEmpty
        var facts: [String: MsgFacts] = [:]
        var toRead: [String] = []
        for id in seen {
            if let hit = cached[id] { facts[id] = hit } else { toRead.append(id) }
        }

        var failed = 0
        var read = 0
        progress(.reading, 0, toRead.count, firstRead)
        var i = 0
        while i < toRead.count {
            let batch = Array(toRead[i..<min(i + READ_CONCURRENCY, toRead.count)])
            let started = Date()
            var unauthorized = false
            await withTaskGroup(of: (String, MsgFacts?, Bool).self) { group in
                for id in batch {
                    group.addTask { await self.readFacts(id) }
                }
                for await (id, f, unauth) in group {
                    if let f { facts[id] = f } else if unauth { unauthorized = true } else { failed += 1 }
                    read += 1
                    progress(.reading, read, toRead.count, firstRead)
                }
            }
            if unauthorized { throw UnauthorizedError() }

            // Ritmo, não pausa fixa: segura o lote no tempo que a cota permite.
            i += READ_CONCURRENCY
            let owed = Double(batch.count) / READ_PER_SEC - Date().timeIntervalSince(started)
            if owed > 0 && i < toRead.count {
                progress(.waiting, read, toRead.count, firstRead)
                try? await Task.sleep(for: .seconds(owed))
            }
        }

        // Guarda só os ids desta varredura: o cache se poda sozinho.
        if !ownEmail.isEmpty { FactsCache.save(ownEmail, facts) }

        return buildAnalysis(facts: facts, ownEmail: ownEmail, failed: failed, capped: capped)
    }

    /// (id, fatos, sessão caiu). Fatos nil sem sessão caída = falhou de vez
    /// (gfetch já retentou): não entra no cache, a próxima análise tenta de novo.
    private func readFacts(_ id: String) async -> (String, MsgFacts?, Bool) {
        do {
            let d = try await gfetch("/messages/\(id)?format=metadata&metadataHeaders=From&fields=payload/headers,sizeEstimate")
            let headers = (d["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []
            let from = headers.first { $0["name"] as? String == "From" }?["value"] as? String
            let size = (d["sizeEstimate"] as? NSNumber)?.intValue ?? 0
            return (id, MsgFacts(sender: parseSender(from), size: size), false)
        } catch is UnauthorizedError {
            return (id, nil, true)
        } catch {
            return (id, nil, false)
        }
    }

    /// Ids do remetente, sem repetição, consultados na hora do clique. A MESMA
    /// consulta que a varredura usa, mais o `from:` — o número da tela é a
    /// promessa do que sai daqui. Aspas evitam injeção de operadores de busca.
    private func listSenderIds(_ sender: String) async throws -> [String] {
        var ids = Set<String>()
        var pageToken: String?
        var pages = 0
        repeat {
            var q = [("q", "from:\"\(sender)\" in:anywhere -in:trash"), ("maxResults", "500"),
                     ("includeSpamTrash", "true"), ("fields", "messages/id,nextPageToken")]
            if let pageToken { q.append(("pageToken", pageToken)) }
            let resp = try await gfetch("/messages?" + formEncode(q))
            for m in resp["messages"] as? [[String: Any]] ?? [] {
                if let id = m["id"] as? String { ids.insert(id) }
            }
            pageToken = resp["nextPageToken"] as? String
            pages += 1
        } while pageToken != nil && pages < MAX_PAGES
        return Array(ids)
    }

    func clean(_ sender: String) async throws -> CleanResult {
        guard validateSender(sender) else { throw CleanError.invalidSender }

        // Trava: limpar o próprio endereço esvaziaria a pasta de enviados.
        let own = try await ownEmail(required: true)
        if isOwnAddress(sender, own) { throw CleanError.ownAddress }

        let ids = try await listSenderIds(sender)
        var result = CleanResult(removed: 0, failed: 0)

        for start in stride(from: 0, to: ids.count, by: 1000) {
            let chunk = Array(ids[start..<min(start + 1000, ids.count)])
            do {
                try await gfetch("/messages/batchModify", method: "POST",
                                 json: ["ids": chunk, "addLabelIds": ["TRASH"], "removeLabelIds": ["INBOX"]])
                result.removed += chunk.count
            } catch is UnauthorizedError {
                throw UnauthorizedError()
            } catch {
                // Plano B: individual, 10 por vez, 120 ms entre os lotes.
                for j in stride(from: 0, to: chunk.count, by: 10) {
                    let batch = chunk[j..<min(j + 10, chunk.count)]
                    var unauthorized = false
                    await withTaskGroup(of: Int.self) { group in
                        for id in batch {
                            group.addTask {
                                do { try await self.gfetch("/messages/\(id)/trash", method: "POST"); return 0 }
                                catch is UnauthorizedError { return 2 }
                                catch { return 1 }
                            }
                        }
                        for await r in group {
                            switch r {
                            case 0: result.removed += 1
                            case 2: unauthorized = true
                            default: result.failed += 1
                            }
                        }
                    }
                    if unauthorized { throw UnauthorizedError() }
                    if j + 10 < chunk.count { try? await Task.sleep(for: .milliseconds(120)) }
                }
            }
        }
        return result
    }
}
