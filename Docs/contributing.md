# Contributing

[← Nollie](../README.md) · [Source map](architecture.md#source-map) · [Development](development.md)

Make the smallest complete change that solves the problem.
Read [AGENTS.md](../AGENTS.md) for repository rules and the current handoff location before starting.

## Put code where it belongs

| Change | Home |
| :--- | :--- |
| Shared app screen or interaction | `Apps/Nollie/`, beside the feature it serves |
| Mac-only window or platform behavior | `Apps/Mac/` |
| Protocol, state machine or reusable policy without UI | `Packages/NollieCore/` |
| Drawing or lightweight types used by app and extensions | `Shared/` |
| Extension, background service or gateway integration | Its existing folder in `Extensions/`, `Services/` or `Companions/` |
| Regression coverage | `Tests/Unit/`, `Tests/UI/` or the existing companion/tool test folder |

Keep files focused. Extract a view or policy when it has a clear responsibility.
Do not add a generic framework for one call site, duplicate a source file to share it, or move code merely to shorten a file.
Update project membership, resource paths and scripts together when moving files.

## Design and copy

Start with the conversation. Prefer an understandable action over a configuration form.
Keep everyday controls simple; put technical identifiers and transport details in Developer Mode.
Use native controls and the existing ink, spacing and glass helpers.
Respect Dynamic Type, VoiceOver, Reduce Motion, reduced transparency and solid appearance.

Write short, concrete sentences. Use familiar words and describe the actual effect.
No em dashes. Do not imply a background task stopped when only its preview paused,
or that a model works because it was selected.
Names, icons, bot artwork and license notices must respect their ownership.
Bot characters come from Corey's art package: refresh them with `Tools/dev/sync-characters.py`,
never by editing the character asset catalogs or JSON by hand, and draw them with `CharacterView`.

## State and permissions

Preserve existing connections, drafts and user choices.
Match the connection, profile and session explicitly; do not guess across scopes.
Cancel stale work after navigation, lock or account changes.
Treat a lost response as uncertain, not permission to repeat a mutation.

Keep new runtime files inside an owned installation.
Import and backup must describe their exact scope, preserve originals and verify the result.
Never use personal or private-profile content as a fixture.

## Verification and review

Test meaningful behavior and regressions, not a copy of the implementation.
Use deterministic mock data for ordinary development.
For a visible change, build, run the relevant tests and inspect screenshots on the affected platforms.
Check error and accessibility states when they matter.

Report source checks, fixtures, simulator proof and real-device proof separately.
Live services, credentials, external messages and releases require their own authorized scope.
Follow adjacent code style and [.editorconfig](../.editorconfig); do not reformat unrelated files.
Preserve other work in the checkout. No push, PR or remote change without Corey's approval.
