# Languages

[← Nollie](../README.md) · [Contributing](contributing.md) · [Development](development.md)

Nollie is written in British English. Its words are kept in String Catalogs, with German, French, Spanish and
Japanese translations waiting in them. **Only English ships** until Corey switches a language on, and every
translation is marked *Needs Review* until a native speaker has checked it.

## Switching a language on

One build setting decides which languages go into the apps: `XCSTRINGS_LANGUAGES_TO_COMPILE`, set once on the
project (all four configurations: Debug, Release, DirectDebug, DirectRelease). Today it is `en`.

| To ship | Set it to |
| :--- | :--- |
| English only (today) | `en` |
| English and German | `en de` |
| English and French | `en fr` |
| English and Spanish | `en es` |
| English and Japanese | `en ja` |
| All five | `en de fr es ja` |

In Xcode: the Nollie project (not a target) › Build Settings › All › search "XCSTRINGS_LANGUAGES_TO_COMPILE", select
the row and type the new value once for all configurations. In the file it is four lines of
`Nollie.xcodeproj/project.pbxproj`; `grep -n XCSTRINGS_LANGUAGES_TO_COMPILE Nollie.xcodeproj/project.pbxproj` finds them.

What it does: the catalogs are compiled only for the listed languages, so an `en`-only build has no `de.lproj`,
`fr.lproj`, `es.lproj` or `ja.lproj` in any app, extension or helper, and the system never offers Nollie in those
languages (the App Store reads the same folders). A language's App Shortcuts phrases (Siri) come from the same
catalogs and follow the same switch.

Before switching a language on:
1. A native speaker reviews that language's strings (below) and marks them *Reviewed* in Xcode's catalog editor.
2. Screenshots in that language look right (`Docs/development.md` design pictures, with
   `-AppleLanguages "(de)" -AppleLocale de_DE` as launch arguments).
3. The App Store text in `Docs/store/<language>.md` is checked and entered in App Store Connect.

To try a language without switching it on, override the setting for one build only:
`xcodebuild ... XCSTRINGS_LANGUAGES_TO_COMPILE="en de fr es ja" build`.
A build folder that once held more languages keeps their old `.lproj` folders, so after trying one, clean the
build (or use a fresh `-derivedDataPath`) before checking what an English-only build ships. Archives are clean.

## Where the words live

| Catalog | Used by |
| :--- | :--- |
| `Apps/Nollie/Resources/Localizable.xcstrings` | iPhone, iPad and Mac apps (the Mac app shares the folder) |
| `Shared/Core.xcstrings` (table `Core`) | NollieCore's words, in the apps and the notification extensions |
| `Apps/Nollie/Resources/AppShortcuts.xcstrings` | Siri and Shortcuts phrases |
| `Apps/Nollie/Resources/InfoPlist.xcstrings`, `Apps/Mac/InfoPlist.xcstrings` | Permission prompts |
| `Services/Runtime`, `Services/NetworkFilter`, `Services/Notifications` `InfoPlist.xcstrings` | The Mac helpers' prompts |
| `Apps/Watch/App/Localizable.xcstrings`, `Apps/Watch/Widgets/Localizable.xcstrings` | Watch app, Smart Stack and Stop control |
| `Extensions/Controls/Localizable.xcstrings` | Control Center controls (iPhone and Mac) |
| `Extensions/NotificationService`, `Extensions/NotificationContent` `Localizable.xcstrings` | Notifications |

How code makes words localizable: SwiftUI literals (`Text("…")`, `Button("…")`, `.alert("…")`) already are.
Words built in code use `String(localized: "…")`, and in NollieCore `String(localized: "…", table: "Core")`.
Counts are one string with the number in it (`String(localized: "\(n) schedules")`); English and each language
get their plural forms in the catalog. Sentences are never glued from pieces. Our own views take
`LocalizedStringResource` for literals and keep a `String` init for words already worked out.

Xcode fills `Localizable.xcstrings` itself when it builds. NollieCore is a package, so its catalog is kept up to
date with `Tools/dev/strings.py sync`, which also checks every catalog (`Tools/dev/strings.py check`).
`LocalizationCatalogTests` fails if a string lacks a language, a placeholder differs from the English, or a
translation has an em-dash.

## What stays in English, and why

- Words that go to the model or to Hermes: prompts, helper instructions, goal-writing and summary instructions,
  tool rules, the answers Apple data tools give a helper, slash commands, config and JSON values. They are
  instructions to software, not words for people. A helper still answers in the language it is spoken to.
- Text the add-ons read or match: card labels ("Visa ending 4242") sent to the payments add-on, the main chat's
  "Bot Chat" session name, ready-made helper names and schedule titles once they become profile and job names
  (the gallery shows them translated; the bot it makes is named in English), Hermes' own status lines, which the app
  reads as states (it shows them translated).
- What Hermes, the model and the gateway write: replies, tool output, error text from the gateway and add-ons,
  notification text written on the Mac by the companion. They come in whatever language they were written in.
- The on-device summaries and chat goal lines are written by Apple's on-device model from English instructions,
  so they come back in English for now.
- Identifiers, log lines, the diagnostics file, Developer Mode's raw values, file names.
- Demo content (the demo copy's chats and the mock gateway).
- The extension and helper display names (Nollie Controls, Nollie Notifications, Nollie Runtime, Nollie
  Papertrail) are product names.
- Messages the helper-computer add-on (`own_computer.py`) sends back on the Remove Nollie page, and the
  reasons Nollie Computer gives a bot when it refuses or ends a task: they go to the bot, or come from it as they are.
- Dates on calendar approval cards are written in a fixed British form ("Tue 4 Nov, 10:00") because the same text
  goes to the helper; moving the card to the person's date format is a separate change.
- The words Siri uses come from the catalogs, but what a helper answers through Siri is the helper's own text.

## Voice

Plain, warm and short, like the English. Never claim more than the English does: a translation may be plainer,
never stronger. No em-dashes in any language. Keep safety text (anything commented `Safety:` in the catalog: Ask
first, approvals, payments, sending, posting, deleting, Face ID, Papertrail, Stop) to its exact meaning, even if
it reads a little longer.

- German: *du*, as Apple does. Sentence case. Quotes „…".
- French: *vous*, as Apple does. A no-break space before `?`, `!`, `:` and `;`. Quotes « … ».
- Spanish (Spain): *tú*, as Apple does. Opening `¿` and `¡`. Quotes « … » or "…".
- Japanese: polite です／ます in sentences, plain nouns on buttons and labels. No spaces between words. Quotes 「…」.

## Glossary

Product names stay as they are in every language: **Nollie**, **Papertrail**, **Night shift**, **Hermes**,
**Nollie Companion**, **Nollie Runtime**, **Nollie Link**, **Cua**, **Tailscale**. Feature names that are plain
words are translated the same way everywhere they appear.

### Nollie's words

| English | German | French | Spanish | Japanese |
| :--- | :--- | :--- | :--- | :--- |
| bot | Bot | bot | bot | ボット |
| helper | Helfer | assistant | ayudante | ヘルパー |
| crew | Team | équipe | equipo | チーム |
| chat | Chat | discussion | chat | チャット |
| main chat | Hauptchat | discussion principale | chat principal | メインチャット |
| Ask first | Erst fragen | Demander d'abord | Preguntar primero | 先に確認 |
| needs your OK | braucht dein OK | a besoin de votre accord | necesita tu OK | 承認が必要です |
| approval | Freigabe | autorisation | aprobación | 承認 |
| Allow once | Einmal erlauben | Autoriser une fois | Permitir una vez | 1回だけ許可 |
| Allow in this chat | In diesem Chat erlauben | Autoriser dans cette discussion | Permitir en este chat | このチャットで許可 |
| Always allow | Immer erlauben | Toujours autoriser | Permitir siempre | 常に許可 |
| Deny | Ablehnen | Refuser | Denegar | 拒否 |
| Stop | Stoppen | Arrêter | Detener | 停止 |
| your yes | dein Ja | votre accord | tu sí | あなたの許可 |
| Away from home | Unterwegs | En déplacement | Fuera de casa | 外出中 |
| Board | Board | Tableau | Tablero | ボード |
| task (Board) | Aufgabe | tâche | tarea | タスク |
| schedule (noun) | Zeitplan | planification | programación | スケジュール |
| run (of a schedule) | Ausführung | exécution | ejecución | 実行 |
| Your week / weekly note | Deine Woche / Wochennotiz | Votre semaine / note de la semaine | Tu semana / nota semanal | 今週のまとめ |
| Private | Privat | Privé | Privado | プライベート |
| gateway | Gateway | passerelle | pasarela | ゲートウェイ |
| sign-in | Anmeldung | connexion | inicio de sesión | サインイン |
| saved card | gespeicherte Karte | carte enregistrée | tarjeta guardada | 保存済みのカード |
| model | Modell | modèle | modelo | モデル |
| memory | Gedächtnis | mémoire | memoria | メモリ |
| Developer Mode | Entwicklermodus | Mode développeur | Modo de desarrollador | デベロッパモード |
| left your Mac / went online | hat deinen Mac verlassen / ging online | a quitté votre Mac / est allé en ligne | salió de tu Mac / se conectó | Macの外に送信 / オンラインに送信 |
| stayed on your Mac | blieb auf deinem Mac | est resté sur votre Mac | se quedó en tu Mac | Mac内にとどまりました |

### Apple's words (Apple's own translations)

| English | German | French | Spanish | Japanese |
| :--- | :--- | :--- | :--- | :--- |
| Settings (iPhone) | Einstellungen | Réglages | Ajustes | 設定 |
| System Settings (Mac) | Systemeinstellungen | Réglages Système | Ajustes del Sistema | システム設定 |
| Control Center | Kontrollzentrum | Centre de contrôle | Centro de control | コントロールセンター |
| Lock Screen | Sperrbildschirm | écran verrouillé | pantalla bloqueada | ロック画面 |
| Home Screen | Home-Bildschirm | écran d'accueil | pantalla de inicio | ホーム画面 |
| Shortcuts | Kurzbefehle | Raccourcis | Atajos | ショートカット |
| Siri, Spotlight, Safari, Finder, Dock | (same) | (same) | (same) | (same) |
| Face ID, Touch ID, Optic ID | (same) | (same) | (same) | (same) |
| passcode | Code | code | código | パスコード |
| Keychain | Schlüsselbund | trousseau | llavero | キーチェーン |
| iCloud Keychain | iCloud-Schlüsselbund | trousseau iCloud | llavero de iCloud | iCloudキーチェーン |
| notifications | Mitteilungen | notifications | notificaciones | 通知 |
| Notification Center | Mitteilungszentrale | Centre de notifications | Centro de notificaciones | 通知センター |
| Live Activity | Live-Aktivität | Activité en direct | Actividad en directo | ライブアクティビティ |
| Smart Stack | Intelligenter Stapel | Pile intelligente | Pila inteligente | スマートスタック |
| Action button | Aktionstaste | bouton Action | botón de acción | アクションボタン |
| Focus | Fokus | Concentration | Concentración | 集中モード |
| menu bar | Menüleiste | barre des menus | barra de menús | メニューバー |
| Wi-Fi | WLAN | Wi-Fi | Wi-Fi | Wi-Fi |
| Local Network | Lokales Netzwerk | Réseau local | Red local | ローカルネットワーク |
| Accessibility (privacy) | Bedienungshilfen | Accessibilité | Accesibilidad | アクセシビリティ |
| Screen & System Audio Recording | Bildschirm- & Systemaudioaufnahme | Enregistrement de l'écran et de l'audio du système | Grabación de pantalla y audio del sistema | 画面収録とシステムオーディオ録音 |
| Full Disk Access | Festplattenvollzugriff | Accès complet au disque | Acceso total al disco | フルディスクアクセス |
| Calendar, Reminders, Contacts | Kalender, Erinnerungen, Kontakte | Calendrier, Rappels, Contacts | Calendario, Recordatorios, Contactos | カレンダー、リマインダー、連絡先 |
| Photos, Messages, Mail | Fotos, Nachrichten, Mail | Photos, Messages, Mail | Fotos, Mensajes, Mail | 写真、メッセージ、メール |
| Terminal | Terminal | Terminal | Terminal | ターミナル |
| Apple Intelligence, Apple Watch, iPhone, iPad, Mac | (same) | (same) | (same) | (same) |
| Login Items | Anmeldeobjekte | Ouverture | Ítems de inicio | ログイン項目 |
| Trash | Papierkorb | Corbeille | Papelera | ゴミ箱 |
| Privacy & Security | Datenschutz & Sicherheit | Confidentialité et sécurité | Privacidad y seguridad | プライバシーとセキュリティ |

### Words the translators settled on

Not in the first glossary, used the same way throughout. Reviewers may change them, everywhere at once.

| English | German | French | Spanish | Japanese |
| :--- | :--- | :--- | :--- | :--- |
| Nollie Companion, the companion | Companion | Companion | Companion | コンパニオン |
| alert (iCloud alerts) | Hinweis | alerte | alerta | 通知 |
| turn (one reply of a bot) | Durchgang | tour | turno | ターン |
| rehearsal (Night shift) | Probelauf | répétition | ensayo | リハーサル |
| tool | Werkzeug | outil | herramienta | ツール |
| Keep awake | Wach halten | Rester éveillé | Mantener activo | スリープさせない |
| Bot settings | Bot-Einstellungen | Réglages du bot | Ajustes del bot | ボットの設定 |
| Sign-ins | Anmeldungen | Connexions | Inicios de sesión | サインイン |
| main helper | Haupthelfer | assistant principal | ayudante principal | メインのヘルパー |

## Review

Every translation is marked *Needs Review*. Xcode's catalog editor shows the state per string and per language;
`Tools/dev/strings.py check` prints how many are left per language. A reviewer works through, in this order:

1. **Safety text first**: strings whose comment starts with `Safety:` (approvals, Ask first, payments, Face ID,
   Papertrail, Stop, deleting). Check the meaning is exact, not only natural.
2. Permission prompts (`InfoPlist.xcstrings`) and Siri phrases (`AppShortcuts.xcstrings`): Siri phrases must be
   things people really say in that language, and the Siri page in Settings shows the same phrases.
3. Settings, the chat list, chats and cards, the weekly note, Night shift notes, the helper gallery.
4. Setup, pairing and Developer Mode words.

Then mark the language's strings *Reviewed* and switch it on (above).

Known rough edges for reviewers (each is a draft choice, not a known mistake):
- Device words filled into sentences ("this %@", "your %@", "the %@", with Mac, iPhone or iPad): German needs the
  case of the sentence around it ("deinen Mac"), French needs "ce Mac" but "cet iPhone". The drafts use one form,
  so a few sentences read stiffly. The lasting fix is whole sentences per device in the code (`DeviceWords`).
- Calendar and reminder cards (Core: "calendar %@", "%@?") and Night shift sleep notes are built from pieces;
  the drafts word them to fit, and Japanese joins them with 。.
- "Click" opens both an instruction ("Click Continue") and a screen action on an approval card; the drafts use the
  form that keeps the approval card exact (German "Klicken", French "Cliquer", Spanish "Pulsa").
- "Read file" and "Read page" are one key each for both the step's name and its past tense.
- Counts above 999 are shortened ("1.2k pages") and do not take plural forms.
- Ready-made helper names are translated in the gallery, but a helper once added keeps its English profile name.
- Example amounts in starter ideas were moved to local money (30 €, 5,000円).
