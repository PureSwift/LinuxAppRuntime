#!/bin/sh
# Runs a universal bundle in the runner, linux-app-host, in the development
# image, headless (SDL's offscreen driver), saving its first frame to
# SCREENSHOT (inside this checkout) and quitting; with
# CACAO_SCREENSHOT_DELAY=seconds, the first after that, as for a GL surface,
# whose frames come after the window's first. The runner loads the bundle's
# libapp.so for this machine. The bundle must be inside this checkout, such
# as .build/guest/<id>.app from AppRuntime's
# `guest.py bundle --target linux-arm64 --output .build/guest`.
#
#   Scripts/run-app.sh .build/guest/org.pureswift.ExampleUI.app .build/shots/ExampleUI.png
set -e
bundle=${1:?usage: Scripts/run-app.sh BUNDLE SCREENSHOT [linux-app-host arguments]}
screenshot=${2:?usage: Scripts/run-app.sh BUNDLE SCREENSHOT [linux-app-host arguments]}
shift 2
exec "$(dirname "$0")/docker.sh" \
    "swift build --scratch-path .build/linux-trixie --product linux-app-host && CACAO_SCREENSHOT=/src/$screenshot .build/linux-trixie/debug/linux-app-host --bundle /src/$bundle $*"
