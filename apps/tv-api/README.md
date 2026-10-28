# TV Webhook API

The optional Node service receives Reolink Default JSON webhooks on the TV and invokes the overlay controller. It binds only to a configured LAN IPv4 address and checks both the camera source IP and a 32-byte hex bearer token.

## Provisioning

Install the repository using the root [setup guide](../../README.md). On the TV, copy the installed example configuration and edit it locally:

```sh
cd /var/lib/webosbrew/camera-overlay
cp api-config.example.json api-config.json
```

Set `enabled` to `true`, `bindAddress` to the TV LAN IPv4 address, and `allowedClients` to the camera’s exact IPv4 address. Configure notification rules as documented below. Generate a unique token as 32 random bytes encoded in lowercase hexadecimal, save the 64-character value in `api.key`, then set root ownership and mode 600 on both private files:

```sh
chown root:root api-config.json api.key
chmod 600 api-config.json api.key
```

Start or inspect the receiver:

```sh
./api-control start
./api-control status
```

The `10-camera-overlay-api` Homebrew startup hook runs `api-control start` during boot. Without both private files it leaves the listener stopped. After changing either file, run `api-control restart`.

## Endpoint and payload

Configure the Reolink Webhook URL as:

```text
http://<TV_LAN_IP>:8765/api/v1/reolink/webhook?token=<TOKEN>
```

Use **Default** JSON content. The receiver handles the `cmd`, `action`, and optional `alarm` object. An alarm contains `channel`, `type`, and `start`. A camera Test without an alarm returns HTTP 200 with an ignored status and does not show the overlay. Accepted, ignored, and duplicate alarms return HTTP 200. Duplicate suppression keys on `alarm.start`, channel, and type. The supported types are `people`, `vehicle`, `visitor`, `motion`, and `pet`.

Requests must be JSON POSTs from an allowlisted IP, and the query must contain only the matching token. Bodies are limited to 4096 bytes. There is no TLS: use this only on a trusted LAN and do not expose port 8765 to the internet.

## Notification rules

Each alarm type can be set to `null` or configured with these fields:

```json
"people": {
  "event": "motion-person",
  "message": "Camera: Person detected",
  "sound": "motion-person",
  "durationSeconds": 300
}
```

`event` can be `motion-person`, `motion-car`, or `doorbell`. `sound` can be any of those sound names or `none`. Duration is from 1 to 86400 seconds. The message must be 1–240 printable characters. Defaults enable people and vehicle and leave visitor, motion, and pet disabled.

The service records alarm identifiers in memory for a short deduplication window; restarting the service clears that temporary history. The controller writes the message, sound, event type, and duration to the overlay’s notification file and launches the app when needed.
