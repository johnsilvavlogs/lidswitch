#!/bin/bash -p
# Retired: legacy assembly mutates/re-signs a bundle and is never a release path.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
printf '%s\n' 'immutable-candidate-required code=legacy-builder-retired phase=unqualified' >&2
exit 65
