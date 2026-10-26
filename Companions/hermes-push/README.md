# hermes-push: background alerts for the Nollie apps

While Nollie is open, approvals, questions and turn events reach it live over `/api/ws`. Getting an
alert to a phone that is closed or asleep takes a server that talks to Apple's push service (APNs).
This companion is that server. It runs on your own machine beside your Hermes install, signs with
your own Apple Developer APNs key, and talks only to your gateway and to Apple.

## What it does

1. The app writes a registration file through the gateway's managed-files API, at
   `<profile HERMES_HOME>/push/devices/<install-id>.json`. It holds the device token, the APNs
   environment, the Live Activity token and the gateway URL.
2. `hermes_push.py` opens `/api/ws` like any other client, joins every live session
   (`session.active_list`, then `session.activate`) and listens to the events.
3. If an approval, a question or a secret request is waiting, a turn ends, an error is raised or a
   scheduled run finishes, it sends an APNs alert to every registered device. Tapping the alert
   opens that session in the app. Approval alerts also carry **Allow once** and **Deny**
   buttons, which answer through `approval.respond`.
4. When a turn is over it also closes the app's Live Activity with a `liveactivity` push.

## Setting it up from the app (recommended)

**Nollie > Settings > Notifications > Set up the push companion...** handles everything except one
command on the gateway machine:

1. Choose your `AuthKey_....p8` file (Files, iCloud Drive or AirDrop). The key ID is taken from the
   file name and the team ID from the build's provisioning profile.
2. The app picks how the relay signs in. A gateway without an auth gate reuses the session token.
   A gated one gets a separate sign-in for the relay (browser or password), so its bearer and
   refresh tokens never clash with the phone's, and the relay renews them itself.
3. The app uploads `hermes_push.py`, `install.sh`, `hermes-push.conf` and the `.p8` into
   `<profile home>/push/` through the dashboard's managed-files API.
4. It then shows `bash <home>/push/install.sh`, or can **ask Hermes to run it**, which shows up as an
   ordinary approval card. `install.sh` registers a systemd user service (Linux) or a launchd agent
   (macOS), starts it, and sends a test push to the phone.

The relay reads its settings from `hermes-push.conf`, found through `HERMES_PUSH_CONFIG` and
defaulting to `<HERMES_HOME>/push/hermes-push.conf`. Environment variables take precedence over the
file. When a bearer token rotates, the new value is saved back into that file.

## Setting it up by hand

```bash
# On the machine that runs `hermes serve` (these are placeholders):
export HERMES_PUSH_GATEWAY_URL=http://127.0.0.1:9119          # or https://hermes.example.com
export HERMES_PUSH_GATEWAY_TOKEN=<HERMES_DASHBOARD_SESSION_TOKEN> # loopback or ungated gateway
# For a gated gateway use this instead: export HERMES_PUSH_GATEWAY_BEARER=<access token from /auth/native/token>
# Optional, only when the URL sits behind Cloudflare Access:
# export HERMES_PUSH_CF_ACCESS_CLIENT_ID=... HERMES_PUSH_CF_ACCESS_CLIENT_SECRET=...

export HERMES_PUSH_APNS_KEY_FILE=$HOME/AuthKey_XXXXXXXXXX.p8
export HERMES_PUSH_APNS_KEY_ID=XXXXXXXXXX
export HERMES_PUSH_APNS_TEAM_ID=YYYYYYYYYY
export HERMES_PUSH_APNS_TOPIC=com.coreykozarski.nollie        # the bundle id the app was built with

$HERMES_HOME/hermes-agent/venv/bin/python hermes_push.py
```

The Hermes virtualenv already contains `websockets`, `PyJWT` and `cryptography`; elsewhere install
them with `pip install websockets pyjwt cryptography`. `curl` with HTTP/2 support has to be on
the PATH.

Run it under systemd or launchd so it comes back after a reboot. If the connection drops it
reconnects with backoff.

### Trying it out

```bash
python hermes_push.py --list            # shows registered devices, each with bundle id and APNs environment
python hermes_push.py --test            # sends one real "hermes-push is working" alert to every device
python hermes_push.py --dry-run         # runs the relay but prints payloads instead of calling APNs
```

When `--test` reaches the phone, the key, team ID and topic are correct and the rest is only
gateway events. A `403 InvalidProviderToken` means the key ID and team ID do not belong together.
A `400 BadDeviceToken` most often means the device registered from a Debug build (sandbox) while you
are pushing to production, or the other way around; `--list` prints each device's environment.

### Staying up

- Linux (systemd user session): `hermes-push.service` and `hermes-push.env.example` in this folder.
- macOS (launchd): `com.coreykozarski.nollie.push.plist`.

Either one restarts the relay after a failure and at boot.

### Other Apple devices

The Mac and Apple Watch apps register in the same way, with `platform` set to `macos` or `watchos`
and a `bundle_id` of their own. The relay sends to each device on its own topic, and watch
complications receive `complication` pushes on `<watch bundle id>.complication`.

## The APNs key

In your Apple Developer account, create a key with the *Apple Push Notifications service*
capability, download the `.p8`, and write down the Key ID and Team ID. The app's `aps-environment`
entitlement is `development` for Debug builds and should be `production` for TestFlight and App
Store builds. Each device's registration file records which environment it uses.

## Settings

| Setting | What it does |
|---|---|
| `HERMES_PUSH_GATEWAY_URL` | Base URL of the dashboard, including the path prefix behind a reverse proxy |
| `HERMES_PUSH_GATEWAY_TOKEN` | `X-Hermes-Session-Token` for ungated gateways (sent as `?token=` on the socket) |
| `HERMES_PUSH_GATEWAY_BEARER` | Bearer access token for gated gateways (a `?ticket=` is minted via `/api/auth/ws-ticket`) |
| `HERMES_PUSH_GATEWAY_REFRESH_TOKEN` | Refresh token. On a 401 the relay renews the bearer through `/auth/native/refresh` and stores both in the config file |
| `HERMES_PUSH_CONFIG` | KEY=VALUE file read before the environment (the app writes `<HERMES_HOME>/push/hermes-push.conf`) |
| `HERMES_PUSH_CF_ACCESS_CLIENT_ID/SECRET` | Optional Cloudflare Access service token |
| `HERMES_PUSH_APNS_KEY_FILE` / `KEY_ID` / `TEAM_ID` / `TOPIC` | Your APNs credentials and bundle id |
| `HERMES_PUSH_APNS_SANDBOX` | Forces the sandbox host (default is decided per device) |
| `HERMES_PUSH_DEVICES_DIR` | Replaces `<HERMES_HOME>/push/devices` |
| `HERMES_PUSH_POLL_SECONDS` | How often sessions are looked for (default 10) |
