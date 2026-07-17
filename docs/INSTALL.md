# Install

## Requirements

- Apple Silicon Mac
- macOS `26.5.2` build `25F84` for activation in this recovery release
- Administrator access to install or remove the helper and to run explicit recovery

## Install the manual build

1. Download `LidSwitch.dmg` from GitHub Releases.
2. Run `shasum -a 256 LidSwitch.dmg` and verify that it equals the published
   `0c2d03cafc88ee8d947b4f3551e72e046ce50955fb2946eb56bc8b344669dc00`
   digest recorded in `docs/DISTRIBUTION.md`.
3. Open the DMG and copy `LidSwitch.app` to `/Applications`.
4. This build is ad-hoc signed and not notarized. If Gatekeeper blocks it, use **Open Anyway** in System Settings > Privacy & Security.
5. Open LidSwitch. Protection is off.
6. Choose **Prepare Safe Helper** and approve the administrator prompt. This installs the compiled helper and removes old startup behavior; it does not start a session.
7. While connected to AC, choose **Start Plugged-In Session** and confirm.
8. When the job finishes, choose **Stop and Restore**.

There is no login launch or battery mode. Reconnecting power never starts a session.

## Remove

Choose **Remove Helper** and confirm. LidSwitch revokes the session, verifies restoration, disables and unloads the daemon, and removes current and legacy helper files. Delete `/Applications/LidSwitch.app` afterward if desired.

If authorization ends before the root transaction publishes its running
receipt, the UI reports that authorization did not start and nothing was
enabled. If the wait times out after a running receipt exists, the UI reports
completion as indeterminate and asks for a status refresh; it never claims that
the still-running root transaction was cancelled.
