# Operations

## Normal use

1. Leave the lid open while setting up.
2. Open LidSwitch.
3. Approve helper installation if requested. This authorization persists for the installed helper.
4. Choose **Plugged in**, **On battery**, or both. Battery operation is initially off.
5. Turn on **Keep Mac awake** and wait for **Awake while plugged in** or **Awake on battery** before closing the lid.
6. Turn the switch off to restore normal sleep, or choose **Quit** to restore and exit.

Switching between selected power sources keeps protection active. An unselected source restores normal sleep while the switch waits; a selected source resumes protection only while this app remains open with the switch on. Changing source choices safely ends the existing generation before applying a new policy. Both choices off turns the master off.

Quitting, restarting, or losing the heartbeat ends the session. Launching the app again keeps the saved source choices and leaves protection off. Ordinary switching and quitting do not ask for confirmation; setup, repair, updates, or removal may require macOS authorization.

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

Version `0.2.16` removes them during preparation. Do not re-enable them.

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
