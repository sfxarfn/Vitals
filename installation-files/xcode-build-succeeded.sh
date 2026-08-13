#!/bin/sh

set -u

notify="$HOME/.local/bin/vitals-notify"

"$notify" activity-stop --id xcode-build || :
exec "$notify" event xcode-build-succeeded
