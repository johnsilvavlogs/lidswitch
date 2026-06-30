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
- The Mac app is not a background account, analytics, or cloud service

## Release Checklist

1. Run native and site validation.
2. Run the public secret scan:

   ```bash
   npm run scan:secrets
   npm run scan:secrets:test
   ```

3. Build the DMG:

   ```bash
   ./script/build_dmg.sh
   ```

4. Validate the release artifact:

   ```bash
   ./script/validate_dmg.sh
   ```

   This confirms the checksum, mounted app signature, release-artifact secret
   scan, and expected Gatekeeper rejection for the manual approval flow.

5. Create a GitHub Release.
6. Attach the Apple Silicon `dist/LidSwitch.dmg` and `dist/LidSwitch.dmg.sha256`.
7. Make the repository public and publish the release.
8. Confirm the public GitHub surface is reachable without authentication:

   ```bash
   npm run launch:check-public
   ```

9. Confirm the landing page download CTA reaches the release.
10. Confirm Web Analytics is enabled for the Vercel project:

   ```bash
   npx -y vercel@latest project web-analytics --format json --scope team_fs4VucfgpyXLHSRITEcuK5gu
   ```

11. Check current release asset download counts:

   ```bash
   npm run analytics:downloads
   ```

12. Tell recipients to expect macOS manual approval on first launch.

Do not make the repository public until the final secret scan and launch review
are complete.
