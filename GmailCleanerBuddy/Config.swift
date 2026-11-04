// ============================================================
// Configuração OAuth do app iOS.
//
// IOS_CLIENT_ID: o client do tipo "iOS" no MESMO projeto do Google Cloud do
// app Android (Credenciais → Criar credenciais → ID do cliente OAuth → iOS),
// com o Bundle ID com.mbastida.gmailcleanerbuddy. O client "Aplicativo da
// Web" do Android NÃO serve aqui: o iOS usa o client próprio, sem secret.
//
// Enquanto estiver com o valor de exemplo, o botão de login falha com
// "invalid_client".
// ============================================================

enum Config {
    static let iosClientID = "COLE_AQUI_O_CLIENT_ID_IOS.apps.googleusercontent.com"

    static let gmailScope = "https://www.googleapis.com/auth/gmail.modify"

    /// O Google aceita, para clients iOS, o ID ao contrário como esquema de
    /// retorno: com.googleusercontent.apps.123-abc:/oauth2redirect
    static var redirectScheme: String {
        iosClientID.split(separator: ".").reversed().joined(separator: ".")
    }

    static var redirectURI: String { redirectScheme + ":/oauth2redirect" }
}
