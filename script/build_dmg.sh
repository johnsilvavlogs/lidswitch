#!/bin/bash -p
# Retired: legacy DMG packaging cleaned metadata and rebuilt app bytes.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
printf '%s\n' 'immutable-candidate-required code=legacy-packager-retired phase=unqualified' >&2
exit 65
