#!/bin/bash -p
# Retired: a validator must consume an immutable manifest, never rebuild.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
printf '%s\n' 'immutable-candidate-required code=legacy-validator-retired phase=unqualified' >&2
exit 65
