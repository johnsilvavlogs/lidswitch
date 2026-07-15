#!/bin/bash -p
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
printf '%s\n' 'immutable-candidate-required code=legacy-dmg-validator-retired phase=unqualified' >&2
exit 65
