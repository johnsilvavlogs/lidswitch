# Privacy And Safety

LidSwitch does one job locally: it controls macOS power-management settings so a
plugged-in MacBook can stay awake with the lid closed.

## Data

LidSwitch does not collect, transmit, or store:

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
