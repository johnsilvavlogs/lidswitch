# Privacy

## Mac app

LidSwitch has no app telemetry and sends no passwords, API keys, tokens, account identifiers, power state, or session data.

Local user-owned state is limited to the disabled migration preference, the short-lived activation lease, and a bounded owner-only session decision history. Root-owned state records helper version, current acknowledgement, only the settings needed to restore a LidSwitch-owned change, and a local terminal-generation ledger bounded to the newest 64 random session UUIDs so ended sessions cannot be replayed.

The helper reads local power state through IOKit and `pmset`. It does not contact a network service.

## Battery

Version `0.2.2` has no battery keep-awake mode. Unplugging ends the session and restoring power does not restart it.

## Website and GitHub

The public website uses Vercel Web Analytics for aggregate traffic and download intent. GitHub records release download counts. Those public services are separate from the Mac app.
