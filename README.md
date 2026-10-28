# Reolink Camera Overlay for LG webOS

A floating overlay for compatible rooted LG webOS TVs. A Reolink camera sends a webhook directly to the TV; the overlay displays its RTSP substream, an optional message and sound, and a countdown. The project is released under the MIT License.

## Requirements

- A rooted, compatible LG webOS TV with Homebrew installed.
- Node.js, Python 3, GStreamer, and the GStreamer RTSP/H.264 components on the TV.
- `@webos-tools/cli` (including `ares-package`), PowerShell, and OpenSSH on the installer PC.
- A standalone Reolink camera with webhook firmware and RTSP enabled. NVR-based setups are outside this project’s documented configuration.
- A Homebrew Input Hook setup that maps the remote’s Blue button to `/var/lib/webosbrew/camera-overlay/control hide`.

## Build and install

From the repository root, build the app package:

```powershell
./scripts/Install-CameraOverlay.ps1
```

To install it on a TV, supply the TV host, your root SSH private key, and a pinned known-hosts file containing that TV’s verified SSH host key:

```powershell
./scripts/Install-CameraOverlay.ps1 -Deploy `
  -TvHost 'tv.example.lan' `
  -SshKeyPath 'path\to\webos-root-key' `
  -KnownHostsPath 'path\to\webos-known-hosts'
```

The installer packages the QML app, copies the controller, video producer, API service, safe configuration templates, and startup hook, installs the app, and checks the installed app version. It does not create or transmit camera credentials or webhook tokens. The API remains stopped until provisioned below.

## Configure RTSP video

As root on the TV, create `/var/lib/webosbrew/camera-overlay/stream.json` using the safe template in [`apps/doorbell-overlay/stream.example.json`](apps/doorbell-overlay/stream.example.json). Set the camera host, username, and password locally. Protect it:

```sh
chown root:root /var/lib/webosbrew/camera-overlay/stream.json
chmod 600 /var/lib/webosbrew/camera-overlay/stream.json
```

The producer reads the Reolink RTSP substream at `rtsp://<camera-host>:554/h264Preview_01_sub`. Keep credentials only on the TV; never commit the populated file.

## Enable the webhook receiver

Generate a unique 32-byte token on a trusted machine and keep its lowercase hexadecimal value (64 characters):

```powershell
$token = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
$token
```

On the TV, save that value to `/var/lib/webosbrew/camera-overlay/api.key`. Copy `api-config.example.json` to `api-config.json`, set `enabled` to `true`, set `bindAddress` to the TV’s LAN IPv4 address, and replace `allowedClients` with the camera’s exact LAN IPv4 address. The service rejects requests from other source addresses. Protect both files:

```sh
chown root:root /var/lib/webosbrew/camera-overlay/api.key /var/lib/webosbrew/camera-overlay/api-config.json
chmod 600 /var/lib/webosbrew/camera-overlay/api.key /var/lib/webosbrew/camera-overlay/api-config.json
```

Start and check the service:

```sh
/var/lib/webosbrew/camera-overlay/api-control start
/var/lib/webosbrew/camera-overlay/api-control status
```

The installed Homebrew startup hook tries to start `api-control` at boot. It stays dormant when the private files are absent. Use `restart` after changing configuration.

## Configure Reolink

In the camera web UI, open **Settings → Surveillance → Push → Webhook → Add**. Select **Content: Default** and use this URL, replacing both placeholders:

```text
http://<TV_LAN_IP>:8765/api/v1/reolink/webhook?token=<TOKEN>
```

Use the same LAN address as `bindAddress` and the token stored in `api.key`. Select **Test**, then **Save**. A test without an `alarm` object receives HTTP 200 and does not open the overlay. Reolink’s official [Webhook overview and setup](https://support.reolink.com/articles/46238508855193-Overview-of-Webhook-in-Reolink-Cameras/) describes the camera-side controls.

## Event display settings

Edit `notifications` in the root-owned `api-config.json`. Supported alarm types are `people`, `vehicle`, `visitor`, `motion`, and `pet`. Each can be disabled with `null`, or mapped to an overlay event (`motion-person`, `motion-car`, or `doorbell`), a message, a sound, and `durationSeconds` (1–86400). The example enables people and vehicle and disables visitor, motion, and pet. Sound can be `motion-person`, `motion-car`, `doorbell`, or `none`.

The duration controls how long the overlay remains open; Blue closes it through the configured Input Hook. The notification message is configurable up to 240 characters. Duplicate events with the same alarm start, channel, and type are suppressed briefly.

## Security and removal

The endpoint uses plain HTTP on the LAN. The token is a bearer secret visible to devices that can observe the camera-to-TV traffic; it is not a substitute for TLS. Restrict the TV and camera to a trusted LAN, use an exact camera IP allowlist, keep the token private, and do not forward port 8765 from the internet. The service also checks the source IP and accepts only small JSON POST bodies.

To stop the receiver, run `api-control stop`; to disable boot startup, remove `/var/lib/webosbrew/init.d/10-camera-overlay-api`. To remove the app, use the webOS app manager or Homebrew tooling, then remove `/var/lib/webosbrew/camera-overlay` and `/var/lib/webosbrew/init.d/10-camera-overlay-api` as root. This also deletes local credentials and configuration, so back up only what you intend to retain.

See the [TV API guide](apps/tv-api/README.md) and [overlay guide](apps/doorbell-overlay/README.md) for component-specific details. This project is available under the [MIT License](LICENSE).
