#!/bin/sh
set -eu
# A disposable encrypted test keyring. This is not a production unlock bypass.
export HOME="$(mktemp -d /tmp/pi-remote-keyring.XXXXXX)"
chmod 700 "$HOME"
trap 'rm -rf "$HOME"' EXIT
keyring_environment="$(printf "%s" "isolated-test-password" | gnome-keyring-daemon --unlock --components=secrets 2>/dev/null)"
eval "$keyring_environment"
"$@"
