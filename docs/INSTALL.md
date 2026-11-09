# Install

## Requirements

- Apple Silicon Mac
- macOS `27.2` build `26B123` for activation in this recovery release
- Administrator access to install or remove the helper and to run explicit recovery

## Install the manual build

1. Download `LidSwitch.dmg` from GitHub Releases.
2. Run `shasum -a 256 LidSwitch.dmg` and compare it with the checksum published beside that release.
3. Open the DMG and copy `LidSwitch.app` to `/Applications`.
4. This build is ad-hoc signed and not notarized. If Gatekeeper blocks it, use **Open Anyway** in System Settings > Privacy & Security.
5. Open LidSwitch. Protection is off.
6. Choose **Install Helper**, **Update Helper**, or **Repair Helper** when offered, then approve the administrator prompt.
7. Choose **Plugged in**, **On battery**, or both. Turn on **Keep Mac awake** and wait for **Awake** before closing the lid.
8. Turn the switch off, or choose **Quit**, to restore sleep. Ordinary switching and quitting require no administrator prompt.

There is no login launch. Opening the app leaves protection off and preserves the source choices. Reconnecting power resumes protection only while the app remains open with Keep Mac awake on and that source selected.

## Remove

Choose **Remove Helper** and confirm. LidSwitch revokes the session, verifies restoration, disables and unloads the daemon, and removes current and legacy helper files. Delete `/Applications/LidSwitch.app` afterward if desired.

If authorization ends before the root transaction publishes its running
receipt, the UI reports that authorization did not start and nothing was
enabled. If the wait times out after a running receipt exists, the UI reports
completion as indeterminate and asks for a status refresh; it never claims that
the still-running root transaction was cancelled.
