# 📱 Gmail Cleaner Buddy — iOS

Port nativo (Swift + SwiftUI) do app Android em `../gmailcleanerbuddyapp`.
A lógica é a mesma, linha por linha: contagem exata remetente por remetente,
cache por id, trava da própria conta, limpeza via `batchModify`, os 7 idiomas
e os mesmos textos.

Não usa nenhuma dependência. O login é OAuth2 + PKCE pela folha de login do
próprio sistema (`ASWebAuthenticationSession`). Nenhuma credencial fica
salva: os tokens ficam só na memória e somem quando o app fecha.

## O que é cada arquivo

| Arquivo | Equivale no Android |
|---|---|
| `GmailCleanerBuddy/Config.swift` | `src/config.ts` |
| `GmailCleanerBuddy/Auth.swift` | `src/auth.ts` + `GmailTokenPlugin.java` |
| `GmailCleanerBuddy/Gmail.swift` | `src/gmail.ts` |
| `GmailCleanerBuddy/AppModel.swift` | `src/app.ts` (lógica da tela) |
| `GmailCleanerBuddy/ContentView.swift` | `www/index.html` + `www/style.css` |
| `GmailCleanerBuddy/Translations.swift` | `TRANSLATIONS` de `src/app.ts` (gerado) |
| `GmailCleanerBuddyTests/GmailTests.swift` | `test/*.test.ts` |
| `project.yml` | `android/` (gera o projeto do Xcode) |

Roda do **iOS 15** em diante, o que inclui o iPhone 6s, o iPhone 7 e os
modelos mais novos.

## Instalar no iPhone sem Mac (pelo Windows)

O GitHub compila o app num Mac dele a cada push (`.github/workflows/ipa.yml`)
e entrega um `.ipa` sem assinatura. O Sideloadly, no Windows, assina esse
`.ipa` com o seu Apple ID e instala no iPhone pelo cabo.

1. No Windows, instale o **iTunes** (o instalador do site da Apple, não a
   versão da Microsoft Store) e o **Sideloadly** (sideloadly.io).
2. No GitHub, abra **Actions → ipa → a última execução verde** e baixe o
   artefato `GmailCleanerBuddy-ipa`. Descompacte o zip e use o
   `GmailCleanerBuddy.ipa` que vem dentro.
3. Ligue o iPhone no cabo, desbloqueie a tela e toque em **Confiar** no
   aviso do iPhone.
4. No Sideloadly, arraste o `.ipa`, digite o seu Apple ID e clique em
   **Start**.
5. No iPhone, abra **Ajustes → Geral → VPN e Gerenciamento de Dispositivo**,
   toque no seu Apple ID e depois em **Confiar**.

Com um Apple ID grátis, o app **para de abrir depois de 7 dias**. Para
renovar, é só repetir o passo 4. Com o Apple Developer Program, a
assinatura dura 1 ano.

## Como compilar num Mac

Com um Mac, o caminho é o Xcode:

1. **Mac com Xcode 16 ou mais novo** (App Store, grátis).
2. **Gere o projeto:**
   ```sh
   brew install xcodegen
   cd gmailcleanerbuddyapp_ios
   xcodegen
   open GmailCleanerBuddy.xcodeproj
   ```
3. **Crie o client OAuth do iOS** no MESMO projeto do Google Cloud do Android:
   Credenciais → Criar credenciais → ID do cliente OAuth → tipo **iOS** →
   Bundle ID `com.mbastida.gmailcleanerbuddy`. Cole o ID gerado em
   `GmailCleanerBuddy/Config.swift` (`iosClientID`).
   O escopo `gmail.modify` e os *Test users* da tela de consentimento são os
   mesmos do Android: quem já é testador lá também entra no iOS.
4. **Assinatura:** no Xcode, alvo GmailCleanerBuddy → Signing & Capabilities →
   escolha o seu Team. Para rodar no seu iPhone basta um Apple ID grátis; para
   publicar é preciso o Apple Developer Program (US$ 99/ano).
5. **Rodar:** escolha o iPhone (ou um simulador) e aperte ⌘R. Os testes
   rodam com ⌘U.

## Publicar na App Store

- **Conta:** Apple Developer Program. Para conta de **organização** a Apple
  pede o mesmo **D-U-N-S** que você já está tirando para o Play Console.
- **Ícone:** `Assets.xcassets/AppIcon.appiconset/icon-1024.png` foi
  ampliado do `store/icon-512.png`. Troque por um 1024×1024 nativo se tiver
  um, porque a ampliação perde nitidez.
- **Privacidade:** `PrivacyInfo.xcprivacy` já declara que o app não rastreia
  nem coleta dados. No App Store Connect, responda "Dados não coletados" e use
  a mesma política: https://mbastida43.github.io/gmailcleanerbuddy/privacy.html
- **Gmail:** a verificação OAuth + CASA do Google vale para o projeto inteiro.
  Quando o Android for aprovado, o iOS sai junto, sem refazer nada.
- **Criptografia:** `ITSAppUsesNonExemptEncryption = false` (só HTTPS),
  então não há formulário de exportação.

## Diferenças em relação ao Android

- **Login:** o iOS não tem o Credential Manager do Android. O login abre a
  folha do Google por cima do app, e a renovação de hora em hora usa o
  refresh token, que também fica só na memória.
- **Segundo plano:** o iOS suspende o app quando ele sai da tela. Assim como
  no Android, a análise segura a tela acesa e, se o app for para o fundo,
  espera ele voltar e continua de onde parou.
- **Idioma:** é escolhido pelas bandeiras no app, como no Android. A primeira
  vez segue o idioma do iPhone.
- **Atualizar:** puxar a lista para baixo refaz a análise.

## Atualizar os textos

Os textos vêm do app Android. Se mudar algum lá, gere de novo:

```sh
node scripts/gen-l10n.mjs ../gmailcleanerbuddyapp/src/app.ts GmailCleanerBuddy/Translations.swift
```
