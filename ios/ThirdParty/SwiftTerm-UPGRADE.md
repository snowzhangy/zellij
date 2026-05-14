# SwiftTerm Upgrade Notes

Zelmux vendors a trimmed SwiftTerm snapshot in `ios/ThirdParty/SwiftTerm`.
It is not a git submodule, so upgrades should be explicit and reviewed.

## Current Patch Surface

Zelmux relies on a small local SwiftTerm patch:

- `TerminalView.canPerformAction` must be `open` so `ZelmuxTerminalView` can expose custom menu actions.
- `TerminalView.extraContextMenuItems` lets Zelmux add actions such as **Copy Last Reply**.
- iOS selection edge-scroll keeps the original selection anchor stable while the view scrolls.

The patch is stored in:

```text
ios/ThirdParty/SwiftTerm-Zelmux.patch
```

The patch was prepared against upstream SwiftTerm commit:

```text
73576f6 Couple of guards to avoid duplicate work, the one on MetalTerminalRenderer is just to not update things during an udpate
```

## Activity Check

As of 2026-05-12, upstream SwiftTerm has a recent commit dated 2026-05-10, but it is low-volume in recent history. Treat it as maintained, not high-churn.

## Upgrade Procedure

1. Fetch a clean upstream snapshot outside the repo.

   ```bash
   git clone https://github.com/migueldeicaza/SwiftTerm.git /private/tmp/SwiftTerm-upgrade
   git -C /private/tmp/SwiftTerm-upgrade rev-parse --short HEAD
   ```

2. Apply the Zelmux patch to the upstream snapshot.

   ```bash
   git -C /private/tmp/SwiftTerm-upgrade apply /path/to/zellij/ios/ThirdParty/SwiftTerm-Zelmux.patch
   ```

3. Replace the vendored copy.

   ```bash
   rsync -a --delete \
     --exclude .git \
     --exclude .github \
     --exclude Tests \
     --exclude TerminalApp \
     /private/tmp/SwiftTerm-upgrade/ \
     /path/to/zellij/ios/ThirdParty/SwiftTerm/
   ```

4. Build and test Zelmux.

   ```bash
   xcodebuild build \
     -project ios/Zelmux.xcodeproj \
     -scheme Zelmux \
     -configuration Release \
     -destination 'generic/platform=iOS'
   ```

5. Manually verify on iPhone and iPad:

   - terminal rendering and color palette
   - keyboard show/hide and accessory row
   - one-finger scroll mode
   - selection mode, including drag past top/bottom edge
   - long-press menu and **Copy Last Reply**
   - mouse mode and Zellij tab clicks
   - large agent output streaming

## Upgrade Risk

Risk is moderate. Most Zelmux code uses SwiftTerm through public APIs, but the local patch touches `Sources/SwiftTerm/iOS/iOSTerminalView.swift`, which is also where upstream handles keyboard, selection, mouse, context menu, and accessibility behavior.

If the patch does not apply cleanly, preserve the intent rather than forcing the old code:

- expose a supported hook for custom context-menu actions
- allow Zelmux's terminal subclass to opt into actions
- make selection auto-scroll extend from the fixed selection anchor

## License Note

The bundled SwiftTerm license in `ios/ThirdParty/SwiftTerm/LICENSE` is MIT-style. Keep the license file with all redistributed SwiftTerm source.

