# Privacy Policy — Zelmux

_Last updated: 2026-05-10_

Zelmux ("the App") is a mobile client for the Zellij terminal multiplexer. This policy describes what the App does and does not do with your information.

## Summary

**Zelmux does not collect, transmit, sell, or share any personal data.** The App connects directly from your device to a Zellij server you operate. No data flows through any servers controlled by the App's developer.

## What the App stores on your device

- **Server connection profiles** — host, port, display name, and the SPKI certificate pin you configure. Stored in the App's sandboxed Application Support directory.
- **Authentication tokens** — stored in the iOS Keychain with accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Never written to plain files or backups in clear text.
- **User preferences** — font size, touch mode, saved prompt snippets. Stored locally in the App's sandbox.
- **Terminal scrollback (in memory)** — text received from your Zellij server is held in RAM while a session is active. It is not persisted to disk.

## What the App does NOT do

- No analytics. No telemetry. No crash reporting SDK.
- No advertising. No ad identifiers (IDFA) requested.
- No tracking across apps or websites.
- No account creation. No login to any service operated by the developer.
- No cloud sync. No iCloud usage by the App.
- No data sold or shared with third parties.
- No background data collection.

## Network connections

The App makes outbound network connections **only** to Zellij servers whose host, port, and certificate pin you configure manually. Connections use HTTPS and WebSocket over TLS. The server's TLS certificate is pinned via SHA-256 SPKI hash that you supply — the App rejects any other certificate.

## Local notifications

The App may schedule local notifications (e.g., "agent finished") using `UNUserNotificationCenter`. These notifications are generated and delivered entirely on your device. No push notification servers are involved.

## Third-party code

The App embeds the following open-source library:

- **SwiftTerm** (Apache 2.0) — terminal rendering. SwiftTerm does not make network connections.

No other third-party SDKs are linked.

## Children

The App is rated 4+. It does not knowingly collect any information from anyone, including children.

## Your rights

Because the App does not transmit data off your device, there is nothing for the developer to disclose, export, or delete on your behalf. To remove all App data, delete the App from your device — iOS will erase the sandbox and Keychain entries.

## Contact

Questions: zhangyang680@gmail.com

## Changes

Material changes to this policy will be published at this URL with an updated "Last updated" date.
