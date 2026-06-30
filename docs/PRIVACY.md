# Privacy And Safety

LidSwitch does one job locally: it controls macOS power-management settings so a
plugged-in MacBook can stay awake with the lid closed.

## Data

The LidSwitch Mac app does not collect, transmit, or store:

- passwords
- API keys
- tokens
- account identifiers
- personal analytics
- telemetry

The app stores only local preference intent in:

```text
~/Library/Application Support/LidSwitch/desired-state
```

Example:

```text
mode=enabled
battery=disabled
```

## Helper

The privileged helper is local. It is installed through the normal macOS
administrator prompt and is used to apply or restore power-management settings.

Root-owned files live under:

```text
/Library/LaunchDaemons/com.johnsilva.lidswitch.helper.plist
/Library/Application Support/LidSwitch/
```

## Battery Default

LidSwitch is AC-only by default. Battery lid-close sleep remains allowed unless
you explicitly enable battery keep-awake in the app.

## Network

LidSwitch does not require a network connection for normal operation.

## Website Analytics

The public landing page uses Vercel Web Analytics for aggregate website traffic:
page views, referrers, device/browser class, geography, and visited paths such
as `/download/`.

The website does not add ad pixels, marketing cookies, or fingerprinting scripts.

The download button routes through `/download/` so the Vercel dashboard can show
download intent. The DMG itself is hosted on GitHub Releases, and actual release
asset download counts are reported by GitHub for `LidSwitch.dmg` and
`LidSwitch.dmg.sha256`.

The Mac app still sends no telemetry and does not contact LidSwitch servers for
normal operation.
