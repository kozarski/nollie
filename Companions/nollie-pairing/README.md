# Nollie iPhone pairing

This companion lets an already signed-in Mac create a QR code for an iPhone.
It requires an existing phone-reachable **HTTPS** Hermes dashboard with its normal
authentication gate enabled. It does not change network listeners, install a tunnel,
use iCloud, or contact a relay. A loopback-only managed installation cannot use it yet.

The Mac must use an original bearer sign-in. A shared dashboard session token or an
already paired device cannot create more pairing codes. An additional proxy login
that the phone cannot satisfy is also outside this first version.

## Flow

1. The authenticated Mac creates an invitation under `/api/plugins/nollie-pairing`.
2. The QR contains a versioned HTTPS address, display name, invitation ID, random
   256-bit grant and expiry. It never contains the Mac's credential.
3. The phone shows the address for confirmation. It uses the grant as a one-time
   password for the `nollie-pairing` auth provider through Hermes's existing native
   PKCE routes. Redirects are refused by the phone exchange client.
4. The provider consumes the grant and issues independent device access and refresh
   tokens. The phone verifies the gateway before storing them in Keychain.

Invitations expire after two minutes, are single-use, and can be cancelled. Five bad
attempts cancel an invitation. A global limit allows 60 redemption attempts per minute,
eight pending invitations and 20 new invitations per hour. Grants exist only in memory
as hashes; restarting the dashboard invalidates pending invitations.

Device access tokens last 15 minutes. Refresh tokens rotate and last 180 days from
their last refresh. Only SHA-256 credential hashes and bounded device metadata persist
in `<launch-home>/nollie-pairing/devices.json`, with directory mode 0700 and file mode 0600.
Writes are locked and atomic. At most 32 devices are retained. Names and files do not
contain chat text, profile contents, source credentials or raw device credentials.

Pairing grants the same dashboard account access available through ordinary Hermes
sign-in. It does not introduce per-profile permissions. Treat the QR as a temporary
sign-in secret and show it only when someone is pairing. Disabling the companion blocks
new HTTP authentication and refresh. An already open WebSocket follows Hermes's existing
connection lifetime, and an already minted WebSocket ticket can remain usable for up to
30 seconds. Revocation does not immediately disconnect an active chat socket. Restart the
dashboard to terminate those open sessions if needed.

## Authenticated routes

All routes use `/api/plugins/nollie-pairing` and return `Cache-Control: no-store`.
Create, status, cancel, list and revoke require the original signed-in owner. Ownership
uses the verified provider, organization and user identity. Cookies alone cannot create
an invitation. A paired phone cannot create or administer invitations/devices.

| Method | Path | Result |
| --- | --- | --- |
| GET | `/capabilities` | `supported` and an optional fixed `reason` |
| POST | `/invitations` | Body `device_name`; result `id`, `grant`, `expires_at` |
| GET | `/invitations/{id}` | `state`: pending, paired, expired or cancelled |
| DELETE | `/invitations/{id}` | Cancels a pending invitation |
| GET | `/devices` | This owner's device IDs, names and creation times |
| DELETE | `/devices/{id}` | Revokes this owner's device access and refresh tokens |
| DELETE | `/device` | A paired device can revoke only itself, including cancelled setup |

`paired` means a device credential was issued. The phone still verifies its actual
connection before reporting success. Closing the Mac sheet after this state does not
revoke a successfully issued credential. Revocation is a separate device action. A phone
that cancels after receiving credentials attempts self-revocation. If a network failure
prevents cleanup, the original Mac owner can list and revoke the unused device through
the authenticated device routes. Device-management UI is not part of this first pairing view.

Phone redemption uses the existing public `/auth/native/authorize`,
`/auth/password-login` and `/auth/native/token` routes. Refresh and WebSocket tickets
use the existing `/auth/native/refresh` and `/api/auth/ws-ticket` routes. There is no
new public API bypass or change to Hermes's middleware. The provider implements the
supported `DashboardAuthProvider` interface and registers with
`ctx.register_dashboard_auth_provider` in the dashboard launch profile.

## Installation and activation

Nothing in this source package changes a running gateway automatically.

The app ships the six runtime files inside `Apps/Nollie/Resources/nollie-pairing.bundle`.
`PairingCompanionPackage.load()` verifies the exact file list, sizes and SHA-256 hashes
before returning an install plan. The native setup UI can use that plan with the
existing scoped companion backup/upload API, then offer explicit enable and reload.
Loading a plan performs no upload, configuration change or service action. The managed
loopback runtime remains ineligible for pairing even when these resources are present.

Refresh and verify the resource copy after changing companion sources:

```sh
python3 Companions/nollie-pairing/package.py
python3 Companions/nollie-pairing/package.py --check
```

After reviewing and backing up an existing companion, place these files in
`<Hermes launch home>/plugins/nollie-pairing/`:

```text
__init__.py
provider.py
plugin.yaml
dashboard/manifest.json
dashboard/plugin_api.py
dashboard/index.js
```

Keep any old companion backup outside the discoverable `plugins` directory. Keep
device state in `nollie-pairing/` outside the replaceable plugin directory. Then use
Hermes's normal plugin controls to enable `nollie-pairing` in its launch profile.
For a default-profile installation, the command is:

```sh
hermes --profile default plugins enable nollie-pairing
```

Coordinate a dashboard restart while no task is active so its auth provider and
dashboard routes load together. Check the authenticated capability response and
perform a real phone pairing before claiming network readiness. Do not widen the
server bind or bypass authentication to make the capability check pass.

To stop offering pairing, disable the plugin using the same profile. Restore the saved
plugin files for a code rollback. Do not restore old device state after revoking a
device, because that would restore its access. Existing code and config backups should
retain user-only permissions.

## Verification

The Python suite uses a temporary Hermes home and the actual auth router from the
specified source checkout. It never contacts a gateway or reads personal profiles.
Use an existing Hermes Python environment with FastAPI and HTTPX:

```sh
HERMES_SOURCE=/path/to/hermes /path/to/hermes/python Companions/nollie-pairing/tests/test_pairing.py
python3 Companions/nollie-pairing/tests/run-swift-tests.py
```

The Swift runner builds NollieCore and its pairing fixtures in `build/nollie-pairing`,
using intercepted HTTP responses. It does not launch an app or install a service.
Physical camera scanning, phone reachability, reverse proxy behavior and a real paired
chat remain separate acceptance checks.
