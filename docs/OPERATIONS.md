# Operations

This document covers day-to-day local operation, restore, and uninstall.

## Start The App

```bash
./script/build_and_run.sh
```

The app appears in the macOS menu bar as a small power/bolt icon.

## Enable

1. Open the LidSwitch menu bar item.
2. Turn on **Keep awake when plugged in**.
3. Accept the macOS administrator prompt on first install.

After installation, future on/off toggles update only the user-owned desired-state file and do not require admin authorization.

## Allow Battery Keep-Awake

1. Turn on **Keep awake when plugged in**.
2. Turn on **Allow on battery**.
3. Update the helper if the panel asks for it.

This is intentionally opt-in. While enabled, LidSwitch may keep the Mac awake with the lid closed on battery power, which can drain the battery if the workload runs too long.

## Disable Without Uninstalling

Turn off **Keep awake when plugged in**.

Expected result:

```text
~/Library/Application Support/LidSwitch/desired-state:
mode=disabled
battery=disabled
pmset -g live shows SleepDisabled 0
```

The LaunchDaemon can remain installed while disabled. It will keep enforcing the safe disabled state.

## Restore Now

Use **Restore** when `SleepDisabled` is on and you want to clear it immediately.

Restore does this:

```bash
pmset -a disablesleep 0
pmset -c sleep <saved-original-ac-sleep> # when available
pmset -b sleep <saved-original-battery-sleep> # when available
```

It uses a macOS administrator prompt because these are privileged power-management changes.

## Uninstall

Use **Uninstall** from the menu bar panel.

Uninstall does this:

```text
desired-state -> disabled
pmset -a disablesleep 0
restore saved AC sleep value when available
launchctl bootout system /Library/LaunchDaemons/com.johnsilva.lidswitch.helper.plist
remove /Library/LaunchDaemons/com.johnsilva.lidswitch.helper.plist
remove /Library/Application Support/LidSwitch/lidswitch-helper
remove /Library/Application Support/LidSwitch
```

## Manual Verification

Check power source:

```bash
pmset -g batt
```

Check live sleep override:

```bash
pmset -g live | awk '/SleepDisabled/ { print }'
```

Check saved AC and battery profiles:

```bash
pmset -g custom
```

Check helper:

```bash
launchctl print system/com.johnsilva.lidswitch.helper
```

Check desired state:

```bash
cat "$HOME/Library/Application Support/LidSwitch/desired-state"
```

## Emergency Manual Restore

If the UI is unavailable and `SleepDisabled` is stuck on, run:

```bash
sudo pmset -a disablesleep 0
```

If the helper should be removed manually:

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.johnsilva.lidswitch.helper.plist 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/com.johnsilva.lidswitch.helper.plist
sudo rm -rf "/Library/Application Support/LidSwitch"
printf 'mode=disabled\nbattery=disabled\n' > "$HOME/Library/Application Support/LidSwitch/desired-state"
```

Prefer the in-app **Uninstall** control when possible because it also restores the saved AC sleep value.
