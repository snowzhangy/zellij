# Zelmux Support

_Last updated: 2026-05-10_

Zelmux is a mobile client for [Zellij](https://github.com/zellij-org/zellij), the Rust terminal multiplexer. Use this page to get help, report bugs, or request features.

## Contact

- **Email**: zhangyang680@gmail.com
- **GitHub Issues**: https://github.com/snowzhangy/zellij/issues

When reporting a bug, include:
- iOS version + iPhone/iPad model
- Zelmux version (Settings → About → Version)
- Zellij server version (`zellij --version` on Mac/Linux)
- Steps to reproduce
- Screenshot or paste from **Connection Doctor** (Settings → Connection Doctor → Copy)

---

## Quick setup (5 minutes)

### Step 1 — Install Zellij on your Mac or Linux box

```bash
# macOS
brew install zellij

# Linux (cargo)
cargo install --locked zellij
```

Verify: `zellij --version` — needs **0.43 or later**.

### Step 2 — Generate a TLS certificate

Zelmux requires HTTPS. Generate a self-signed cert:

```bash
mkdir -p ~/.config/zellij/web
cd ~/.config/zellij/web

openssl req -x509 -newkey rsa:4096 \
  -keyout key.pem -out cert.pem \
  -days 365 -nodes \
  -subj "/CN=$(hostname)"
```

### Step 3 — Compute the SPKI pin

```bash
openssl x509 -in ~/.config/zellij/web/cert.pem -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary \
  | base64
```

Output looks like `kPoFDS+76ksk9...=`. **Copy this string** — Zelmux needs it.

### Step 4 — Start Zellij with web sharing

```bash
zellij web \
  --cert ~/.config/zellij/web/cert.pem \
  --key  ~/.config/zellij/web/key.pem \
  --bind 0.0.0.0:8443
```

Bind `0.0.0.0` so iPhone on the same network can reach it.

### Step 5 — Add server in Zelmux

1. Open Zelmux → tap **+** in Profiles
2. Fill in:
   - **Name**: e.g. "Home Mac"
   - **Host**: your Mac's LAN IP (e.g. `192.168.1.50`) or hostname
   - **Port**: `8443`
   - **SPKI Pin**: paste the base64 hash from Step 3
   - **Auth Token**: leave blank unless you set one in Zellij config
3. Tap **Save** → tap the profile → **Attach**

### Step 6 — Pick a session

Session picker shows live Zellij sessions. Tap one to attach. Empty? Create one on the Mac:

```bash
zellij --session work
```

Refresh in Zelmux — `work` shows up.

---

## Common issues

### Cannot connect / "Connection refused"
- iPhone and Mac on same Wi-Fi? Cellular won't see LAN IPs.
- macOS firewall blocking port? System Settings → Network → Firewall → allow `zellij`.
- Bound to `127.0.0.1` instead of `0.0.0.0`? Re-run with `--bind 0.0.0.0:8443`.

### "Certificate pin mismatch"
SPKI hash in profile doesn't match server cert. Causes:
- Regenerated `cert.pem` → recompute pin (Step 3) and update profile
- Pointed at wrong server (different cert)

### "Web Clients are not allowed to attach to this session"
That Zellij session has web sharing disabled. Either:
- Start session with `zellij --session foo` while running `zellij web ...` server, **and** confirm session has `web_sharing on` in layout/config
- In Zellij config (`~/.config/zellij/config.kdl`): `web_sharing "on"`

### "Session not found" (4404)
Session was killed or never existed. Pull-to-refresh the session picker.

### Session list hangs / "Loading…" forever
Wedged Zellij server process. On the Mac:
```bash
pkill -9 zellij
zellij kill-all-sessions
zellij web --cert ... --key ... --bind 0.0.0.0:8443
```

### Connection drops on screen lock
WebSocket dies in background — expected. Zelmux preserves your terminal scrollback locally and auto-reconnects when you reopen the app.

### Keyboard hides important output
- Tap **Focus Mode** (Settings → Focus Terminal) to hide top bar
- Or switch **Touch Mode** in the top bar to scroll-only

### Can't paste long prompt
Use the **Composer** (compose button → paste → Send / Paste / Stage). Bracketed-paste handles long input safely. Stage mode lets you edit before sending.

### Tailscale / VPN
Works fine. Use the Tailscale IP (100.x.x.x) as Host. SPKI pin is the same.

### Diagnostics
**Settings → Connection Doctor** shows live cert info, recent events, byte counters, last close code. Copy to email if reporting a bug.

---

## Privacy

https://gist.github.com/snowzhangy/558da79fa7d574ef928e0141b55dffce

## Acknowledgements

Zelmux is independent and not affiliated with the Zellij project. Zellij © Aram Drevekenin and contributors, MIT. SwiftTerm © Miguel de Icaza, Apache 2.0.
