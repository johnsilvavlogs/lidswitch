# Distribution

This project is set up for a small technical-friends release.

## What This Is

- A native macOS menu bar utility for Apple Silicon Macs
- A free manual DMG
- Source-visible and inspectable
- Designed for people comfortable with GitHub, manual macOS approval, and local
  helper tools

## What This Is Not

- Not a Mac App Store app
- Not notarized
- Not affiliated with Apple
- Not a background account, analytics, or cloud service

## Release Checklist

1. Run native and site validation.
2. Build the DMG:

   ```bash
   ./script/build_dmg.sh
   ```

3. Confirm `dist/LidSwitch.dmg.sha256`.
4. Create a GitHub Release.
5. Attach the Apple Silicon `dist/LidSwitch.dmg` and `dist/LidSwitch.dmg.sha256`.
6. Tell recipients to expect macOS manual approval on first launch.

Do not make the repository public until the final secret scan and launch review
are complete.
