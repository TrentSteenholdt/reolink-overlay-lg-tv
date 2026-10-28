# Camera Overlay

The webOS QML app displays a floating video tile sourced from the TV-side RTSP producer and can show a message, sound, and countdown. The API controller launches it for configured Reolink alarms.

## Requirements and install

Use a rooted compatible LG webOS TV with Homebrew, Node.js, Python 3, GStreamer and RTSP/H.264 support. Build and deploy from a Windows installer PC with PowerShell, OpenSSH, and `@webos-tools/cli` installed. See the repository [setup guide](../../README.md) for the command requiring explicit TV host, SSH private key, and pinned known-hosts file.

The installer installs app ID `org.cameraoverlay.lgtv` and places the `control` script and producer under `/var/lib/webosbrew/camera-overlay`.

## RTSP stream configuration

Create `/var/lib/webosbrew/camera-overlay/stream.json` on the TV from the installed `stream.example.json`. Enter the camera host, username, and password on the TV. Keep the file root-owned with mode 600 and never commit credentials. The producer reads the camera’s H.264 substream and refreshes the overlay image while running.

## Controls and duration

Configure Homebrew Input Hook to run `/var/lib/webosbrew/camera-overlay/control hide` when Blue is pressed. The countdown is set per notification by the API rule’s `durationSeconds`; zero from manual control means no automatic close. Blue closes the overlay immediately.

Messages are limited to 240 printable characters. Available sounds are `motion-person`, `motion-car`, `doorbell`, and `none`. Choose `none` to display a message silently. Video and notification behavior are managed separately: the controller refreshes the RTSP producer and launches the app when the camera event arrives.

For receiver configuration, rules, and the LAN security model, see the [TV API guide](../tv-api/README.md).
