# Operations

## Normal use

1. Connect AC power and leave the lid open.
2. Open LidSwitch.
3. Prepare the helper if requested. Protection remains off.
4. Confirm **Start Plugged-In Session**.
5. Wait for **Protection active — plugged in** before closing the lid.
6. Choose **Stop and Restore** before quitting when practical.

Unplugging, quitting, restarting, or losing the heartbeat ends the session. Replugging does not rearm it.

## Inspect live state

```bash
pmset -g batt
pmset -g live
pmset -g custom
launchctl print system/com.johnsilva.lidswitch.helper
```

`SleepDisabled=1` is valid only with a current lease and fresh matching helper status. If LidSwitch is inactive and it remains `1`, use **Restore Sleep**.

## Emergency rollback

Use the UI first. If the UI is unavailable, clear only the active system override and unload LidSwitch; do not run `pmset restoredefaults`:

```bash
sudo pmset -a disablesleep 0
sudo launchctl disable system/com.johnsilva.lidswitch.helper
sudo launchctl bootout system/com.johnsilva.lidswitch.helper 2>/dev/null || true
```

If a positive original AC sleep value exists in a valid LidSwitch applied-state record and the current AC sleep value is still `0`, restore that exact positive value. Never apply stale `original-ac-sleep=0`.

## Legacy residue

The following old components must remain disabled/unloaded until removed:

```text
~/Library/LaunchAgents/com.johnsilva.LidSwitch.login.plist
/Library/Application Support/LidSwitch/lidswitch-helper
```

Version `0.2.12` removes them during preparation. Do not re-enable them.

Preparation first creates/verifies only the fixed root lock. It does not treat
that as migration authorization. The administrator transaction must boot out
both historical/current writers and prove them absent before the helper may
classify or change legacy state. A source-only or daemon-startup observation
that reports `legacy-writers-not-quiesced` must not be worked around by editing
authority files or running `pmset` manually.

A successful no-UUID migration reports `migrated-idle`, `session=none`, and a
`legacy-migration` reason (or `legacy-migration-superseded` when a positive
timer owned by another actor was preserved). It does not mean the machine was
pristine. If recovery reports required/exit `75`, leave
`original-ac-sleep`, `original-battery-sleep`, `legacy-recovery-journal`, and
their `.lidswitch-delete` quarantines intact for an exact retry. Never set a
timer to `0` to make migration pass and never clear `SleepDisabled` based only
on an old helper, plist, or status file.
