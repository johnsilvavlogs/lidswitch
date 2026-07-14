# Privacy

## Mac app

LidSwitch has no app telemetry and sends no passwords, API keys, tokens, account identifiers, power state, or session data.

Local user-owned state is limited to the disabled migration preference, an inert migration/diagnostic activation-lease record, and a bounded owner-only session decision history. Root-owned state records helper version, current acknowledgement, only the settings needed to restore a LidSwitch-owned change, and private `0600` terminal/recovery ledgers bounded to the newest 64 random session UUIDs so ended sessions cannot be replayed. The menu-bar app treats private recovery authority as opaque and uses only metadata plus the public bounded status projection. Root-owned `0644` administrator receipts contain only a random transaction UUID, operation, state, bounded outcome/reason, and an optional random session UUID. These records contain no account, device, command, or power-history data.

The helper reads local power state through IOKit and macOS's local power-preference domain. It uses `pmset` only for privileged setting mutations and does not contact a network service.

## Battery

Version `0.2.10` has no battery keep-awake mode. Unplugging ends the session and restoring power does not restart it.

## Website and GitHub

The public website uses Vercel Web Analytics for aggregate traffic and download intent. GitHub records release download counts. Those public services are separate from the Mac app.
