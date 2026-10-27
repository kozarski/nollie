# Where Nollie's data goes

The source for the privacy policy, kept with the code so each release can check it. One line per flow:
what leaves, where it goes, who runs that place, and why. Update it in the same change that adds or
removes a flow. Status: as of the v1 plan (19 Oct 2026); flows marked "planned" are not built yet.

| What | From | To | Run by | Why |
|---|---|---|---|---|
| Your messages, replies, files you attach, approvals | Nollie on your Mac, iPhone or iPad | Your own Hermes on your Mac (directly, through Nollie Link, or an address you entered) | You | The assistant does the work there |
| Messages to the model | Your Hermes | The model you chose: on your Mac (local), or ChatGPT or Claude with your own plan, or a provider you set up in the Hermes dashboard | You, or that provider under your account with them | Getting replies |
| Web searches and pages | Your Hermes | Search services with free tiers (Exa, Parallel, Firecrawl, Keenable), then the sites themselves, over your own internet connection | Those services and sites | Research you ask for |
| Short alert previews (bot name, up to 240 characters) | Nollie's helper on your Mac | Your private iCloud database (CloudKit), then your other devices | Apple, under your iCloud account | Notifications when the app is closed; kept up to 7 days |
| Push wake-ups | Apple | Your devices | Apple | Delivering those alerts |
| The Private list, bot looks, pins | Nollie | Your Hermes on your Mac (Private list, and each bot's character and colour, never a private bot's) and the device's own storage (pins, photos) | You | Settings; every device draws a bot the same way |
| Sign-in to your Hermes (tokens) | Nollie | The device's Keychain (never iCloud Keychain in v1) | You, on your device | Staying signed in |
| Downloads during setup (Python, Hermes, a local model) | Nollie Runtime | Pinned release files from GitHub and model hosts, each checked against its hash | Those hosts | Installing the engine |
| Crash and performance reports | Nollie | Apple, only through TestFlight or the App Store, and only if you share analytics with developers | Apple | Fixing bugs |
| Diagnostics you choose to share (Settings › About) | Nollie | A file you share | You | Asking for help; private details and keys are left out |

Never: Nollie has no servers or accounts of its own, no analytics, no advertising, no tracking, and
does not sell or share data. Nollie's developer never receives your chats.
