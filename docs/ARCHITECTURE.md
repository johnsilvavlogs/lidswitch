# Architecture

LidSwitch is a small SwiftPM macOS app with a SwiftUI menu bar surface and a generated root helper.

## Main Components

```text
Sources/LidSwitch/App/LidSwitchApp.swift
Sources/LidSwitch/Views/LidSwitchPanel.swift
Sources/LidSwitch/Models/PowerPreferences.swift
Sources/LidSwitch/Models/PowerPolicy.swift
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
- secondary `Allow on battery` opt-in toggle
- live status text
- `SleepDisabled`, AC sleep, and battery sleep summary
- refresh, restore, install-helper, and uninstall actions depending on state

The UI uses SF Symbols, semantic colors, system controls, and an accessory-style app bundle (`LSUIElement=true`) so the app lives in the menu bar without a Dock icon.

## State Layer

`PowerController` owns app state and periodically refreshes:

- power source
- `SleepDisabled`
- AC idle-sleep setting
- battery idle-sleep setting
- keep-awake and battery opt-in preferences
- helper installation status
- helper version status

`PowerSnapshot` turns raw system values into user-facing status labels.

`PowerPolicy` is the table-tested mirror of the helper decision rules. The root helper still performs privileged changes, but the Swift policy tests protect the AC-only default and the battery opt-in matrix from drift.

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
mode=enabled
battery=disabled
```

Legacy values are still accepted:

```text
enabled   # treated as AC-only
disabled
```

This file is user-owned so turning menu bar toggles on or off after helper installation does not need administrator authorization.

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

Version `2` adds battery opt-in handling and writes:

```text
/Library/Application Support/LidSwitch/helper-version
```

Older installed helpers show **Update Helper** in the menu bar panel.

## Helper Decision Table

| Keep awake | Battery opt-in | Power source | Action |
| --- | --- | --- |
| enabled | disabled | AC Power | remember AC sleep, set `pmset -c sleep 0`, set `pmset -a disablesleep 1`, restore saved battery sleep if needed |
| enabled | disabled | Battery Power | set `pmset -a disablesleep 0`, restore saved battery sleep |
| enabled | enabled | AC Power | remember AC and battery sleep, set `pmset -c sleep 0`, set `pmset -b sleep 0`, set `pmset -a disablesleep 1` |
| enabled | enabled | Battery Power | remember battery sleep, set `pmset -b sleep 0`, set `pmset -a disablesleep 1` |
| disabled | any | Any | set `pmset -a disablesleep 0`, restore saved AC and battery sleep |

## Diagnostic Commands

The executable supports diagnostic output used by tests and the done gate:

```bash
.build/debug/LidSwitch --print-helper
.build/debug/LidSwitch --print-plist
.build/debug/LidSwitch --print-install-script
.build/debug/LidSwitch --print-uninstall-script
```

These commands print generated artifacts without installing anything.
