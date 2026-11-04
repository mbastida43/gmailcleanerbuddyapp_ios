// ============================================================
// Login do Google no iOS: OAuth2 com PKCE pela folha de login do sistema
// (ASWebAuthenticationSession). É o que o SDK do Google faz por baixo, sem a
// dependência — e sem o Keychain que o SDK usa para guardar a sessão.
//
// Mesma regra do Android: nada de credencial no aparelho. O access token
// (~1h) e o refresh token vivem só nesta classe, em memória. O refresh token
// existe para a mesma coisa que o GmailTokenPlugin.java do Android: a
// primeira análise de uma caixa grande passa de 1 hora, e o token novo tem
// de vir sem tela no meio. Fechou o app, acabou a sessão.
// ============================================================

import AuthenticationServices
import CryptoKit
import Security
import UIKit

enum AuthError: LocalizedError {
    case cancelled
    case badCallback
    case missingScope(String)
    case google(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "cancelled"
        case .badCallback: return "bad_callback"
        case .missingScope(let granted): return "missing_scope: \(Config.gmailScope) (concedidos: \(granted))"
        case .google(let message): return message
        }
    }
}

@MainActor
final class Auth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private struct Token {
        var access: String
        var refresh: String?
        var expiresAt: Date
    }

    private var token: Token?
    private var renewing: Task<Bool, Never>?
    private var session: ASWebAuthenticationSession?
    /// Janela onde a folha de login aparece. Guardada antes de abrir porque o
    /// sistema a pede fora do MainActor (presentationAnchor é nonisolated).
    nonisolated(unsafe) private var anchor: ASPresentationAnchor?

    /// Access token válido, ou nil se ausente/expirado.
    func accessToken() -> String? {
        guard let token, Date() < token.expiresAt else { return nil }
        return token.access
    }

    var isAuthenticated: Bool { accessToken() != nil }

    /// Abre a folha de login do Google (escolha de conta + consentimento do
    /// Gmail). Volta quando o access token estiver em mãos.
    func signIn() async throws {
        let verifier = Self.randomURLSafe(32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(16)

        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: Config.iosClientID),
            URLQueryItem(name: "redirect_uri", value: Config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "email \(Config.gmailScope)"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Sempre mostra as contas: quem tem duas escolhe qual limpar.
            URLQueryItem(name: "prompt", value: "select_account")
        ]

        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { throw AuthError.badCallback }
        anchor = window

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: Config.redirectScheme) { url, error in
                if let url {
                    cont.resume(returning: url)
                } else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                    cont.resume(throwing: AuthError.cancelled)
                } else {
                    cont.resume(throwing: error ?? AuthError.badCallback)
                }
            }
            s.presentationContextProvider = self
            session = s
            if !s.start() { cont.resume(throwing: AuthError.badCallback) }
        }
        session = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ name: String) -> String? { items.first { $0.name == name }?.value }

        // access_denied = recusou OU a conta não está em "Test users". Vai cru
        // para a tela, como no Android: um "cancelado" esconderia o segundo caso.
        if let error = param("error") { throw AuthError.google(error) }
        guard param("state") == state, let code = param("code") else { throw AuthError.badCallback }

        let resp = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": Config.redirectURI
        ])

        // A tela de consentimento do Google deixa desmarcar o Gmail e aceitar
        // o resto. Sem esta checagem, o problema só aparecia como 403 na
        // primeira chamada — e um "entre de novo" que nunca resolveria.
        let granted = resp["scope"] as? String ?? ""
        if !granted.isEmpty && !granted.split(separator: " ").contains(Substring(Config.gmailScope)) {
            throw AuthError.missingScope(granted)
        }

        token = Token(
            access: resp["access_token"] as! String, // tokenRequest garante
            refresh: resp["refresh_token"] as? String,
            expiresAt: Self.expiry(resp)
        )
    }

    /// Token novo SEM tela. Uma renovação por vez: as 20 leituras paralelas
    /// batem no vencimento juntas e todas esperam a mesma. false = não deu
    /// (saiu da conta, concessão revogada, sem rede) — aí a sessão cai.
    func renew() async -> Bool {
        if let renewing { return await renewing.value }
        let task = Task { await doRenew() }
        renewing = task
        let ok = await task.value
        renewing = nil
        return ok
    }

    private func doRenew() async -> Bool {
        guard let refresh = token?.refresh,
              let resp = try? await tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh])
        else { return false }
        // Clicou em Sair (ou entrou de novo) durante a renovação: não ressuscita.
        guard token?.refresh == refresh else { return false }
        token = Token(access: resp["access_token"] as! String, refresh: refresh, expiresAt: Self.expiry(resp))
        return true
    }

    /// Encerra a sessão: o token sai da memória. NÃO revoga no Google, de
    /// propósito (mesmo motivo do Android): revogar apaga a concessão, e em
    /// modo Testing só "Test users" conseguem conceder de novo.
    func signOut() {
        token = nil
    }

    // MARK: - Detalhes

    private func tokenRequest(_ params: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = params
        all["client_id"] = Config.iosClientID
        req.httpBody = Data(formEncode(all.map { ($0.key, $0.value) }).utf8)

        let (data, res) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (res as? HTTPURLResponse)?.statusCode == 200, json["access_token"] is String else {
            throw AuthError.google(json["error_description"] as? String ?? json["error"] as? String ?? "no_access_token")
        }
        return json
    }

    /// Validade dita pelo Google, com 1 minuto de folga para o relógio daqui.
    private static func expiry(_ resp: [String: Any]) -> Date {
        let seconds = (resp["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return Date().addingTimeInterval(seconds - 60)
    }

    private static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor! // signIn() define antes de abrir a folha
    }
}
