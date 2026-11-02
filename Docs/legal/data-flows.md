# Where Nollie's data goes

The source for the privacy policy, kept with the code so each release can check it. One line per flow:
what leaves, where it goes, who runs that place, and why. Update it in the same change that adds or
removes a flow. Status: as of the v1 plan (19 Oct 2026); flows marked "planned" are not built yet.

| What | From | To | Run by | Why |
|---|---|---|---|---|
| Your messages, replies, files you attach, approvals | Nollie on your Mac, iPhone or iPad | Your own Hermes on your Mac (directly, through Nollie Link, or an address you entered) | You | The assistant does the work there |
| Messages to the model: what you write, files and photos you add, what the helper reads for you (web pages, and calendar, reminders or contacts if allowed), its memory and instructions | Your Hermes | The model you chose: on your Mac (local), or an online model's company (OpenAI for ChatGPT, Anthropic for Claude, or another you set up), and a backup's company if the first can't answer | You, or that company under your account with them | Getting replies. Nollie names the company and asks before anything first goes to it (`OnlineModelConsent`); each yes is kept per device and Settings › Privacy › Online models takes it back |
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
