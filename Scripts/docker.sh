#!/bin/sh
# Runs a command in the Linux development image (Dockerfile), with this
# checkout at /src and, if APPRUNTIME_PATH is set, that AppRuntime checkout at
# /AppRuntime; likewise CACAO_PATH at /Cacao. Builds go to .build/linux, apart
# from a Mac's .build.
#
#   Scripts/docker.sh swift test --scratch-path .build/linux
#   APPRUNTIME_PATH=~/Developer/AppRuntime Scripts/docker.sh swift build --scratch-path .build/linux
#
# LINUXAPPRUNTIME_APP_LIBRARY, a path inside the container, and
# CACAO_SCREENSHOT_DELAY are passed through.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
image=linuxappruntime-dev

if ! docker image inspect "$image" >/dev/null 2>&1; then
    docker build -t "$image" "$root"
fi

command="$*"
set --
if [ -n "$APPRUNTIME_PATH" ]; then
    set -- "$@" -v "$APPRUNTIME_PATH:/AppRuntime" -e APPRUNTIME_PATH=/AppRuntime
fi
if [ -n "$CACAO_PATH" ]; then
    set -- "$@" -v "$CACAO_PATH:/Cacao" -e CACAO_PATH=/Cacao
fi
exec docker run --rm \
    -v "$root:/src" -w /src \
    -v linuxappruntime-swiftpm:/root/.cache \
    -e LINUXAPPRUNTIME_APP_LIBRARY -e CACAO_SCREENSHOT_DELAY \
    "$@" "$image" bash -c "$command"
