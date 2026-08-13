#!/bin/sh

set -u

exec "$HOME/.local/bin/vitals-notify" \
    activity-start xcode-build --id xcode-build
