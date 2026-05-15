# Architecture

LidSwitch is a small SwiftPM macOS app with a SwiftUI menu bar surface and a generated root helper.

## Main Components

```text
Sources/LidSwitch/App/LidSwitchApp.swift
Sources/LidSwitch/Views/LidSwitchPanel.swift
Sources/LidSwitch/Models/PowerSnapshot.swift
Sources/LidSwitch/Services/PowerController.swift
Sources/LidSwitch/Services/PowerInspector.swift
Sources/LidSwitch/Services/DesiredStateStore.swift
Sources/LidSwitch/Services/PrivilegedHelperManager.swift
Sources/LidSwitch/Services/Shell.swift
Sources/LidSwitch/Support/AppPaths.swift
Sources/LidSwitch/Support/DebugCommands.swift
```

## UI Layer

`LidSwitchApp` defines a SwiftUI `MenuBarExtra` with `.window` style.

`LidSwitchPanel` renders:

- app identity and power source
- primary `Keep awake on power` toggle
- live status text
- `SleepDisabled` and AC sleep summary
- refresh, restore, install-helper, and uninstall actions depending on state

The UI uses SF Symbols, semantic colors, system controls, and an accessory-style app bundle (`LSUIElement=true`) so the app lives in the menu bar without a Dock icon.

## State Layer

`PowerController` owns app state and periodically refreshes:

- power source
- `SleepDisabled`
- AC idle-sleep setting
- desired state
- helper installation status

`PowerSnapshot` turns raw system values into user-facing status labels.

## System Inspection

`PowerInspector` shells out to:

```bash
pmset -g batt
pmset -g live
pmset -g custom
launchctl print system/com.johnsilva.lidswitch.helper
```

Parser coverage lives in `Tests/LidSwitchTests/PowerInspectorTests.swift`.

## Desired State

The app stores the user's intent in:

```text
~/Library/Application Support/LidSwitch/desired-state
```

Accepted values:

```text
enabled
disabled
```

This file is user-owned so turning the menu bar toggle on or off after helper installation does not need administrator authorization.

## Privileged Helper

`PrivilegedHelperManager` generates, installs, restores, and uninstalls helper scripts through macOS authorization.

The helper is installed at:

```text
/Library/Application Support/LidSwitch/lidswitch-helper
```

The LaunchDaemon is installed at:

```text
/Library/LaunchDaemons/com.johnsilva.lidswitch.helper.plist
```

The helper runs at load and every 5 seconds. It exits quickly after reconciling state.

## Helper Decision Table

| Desired state | Power source | Action |
| --- | --- | --- |
| `enabled` | AC Power | remember AC sleep, set `pmset -c sleep 0`, set `pmset -a disablesleep 1` |
| `enabled` | Battery Power | set `pmset -a disablesleep 0` |
| `disabled` | Any | set `pmset -a disablesleep 0`, restore saved AC sleep |

## Diagnostic Commands

The executable supports diagnostic output used by tests and the done gate:

```bash
.build/debug/LidSwitch --print-helper
.build/debug/LidSwitch --print-plist
.build/debug/LidSwitch --print-install-script
.build/debug/LidSwitch --print-uninstall-script
```

These commands print generated artifacts without installing anything.
