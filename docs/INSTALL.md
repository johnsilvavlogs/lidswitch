# Install

LidSwitch is distributed as a free manual DMG for technical Apple Silicon Mac
users. It is not distributed through the Mac App Store and is not notarized.

## Requirements

- Apple Silicon Mac
- macOS 14 or newer
- Administrator access for first helper install, restore, and uninstall actions
- Comfort approving an app manually in macOS Security settings

## Install From A DMG

1. Download the latest `LidSwitch.dmg` from GitHub Releases.
2. Open the DMG and drag `LidSwitch.app` to Applications.
3. Launch LidSwitch.
4. If macOS blocks the first launch, open System Settings, go to Privacy &
   Security, and choose **Open Anyway** for LidSwitch.
5. Turn on **Keep awake when plugged in** from the menu bar panel.
6. Approve the macOS administrator prompt when LidSwitch installs its local helper.

After the helper is installed, normal on/off changes write only to the user-owned
desired-state file and do not need administrator permission.

## Build A DMG Locally

```bash
./script/build_dmg.sh
```

The script writes:

```text
dist/LidSwitch.dmg
dist/LidSwitch.dmg.sha256
```

The DMG is intentionally unsigned beyond local ad-hoc signing of the app bundle.
Recipients should expect manual approval on first launch.

## Uninstall

Use **Uninstall** from the LidSwitch menu bar panel. It disables LidSwitch,
restores saved sleep values when available, unloads the LaunchDaemon, and removes
the root-owned helper files.

See [Operations](OPERATIONS.md) for manual verification commands and recovery
details.
