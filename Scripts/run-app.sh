#!/bin/sh
# Builds linux-app-host linked with a universal bundle's Linux slice and runs
# it in the development image, headless (SDL's offscreen driver), saving its
# first frame to SCREENSHOT (inside this checkout) and quitting; with
# CACAO_SCREENSHOT_DELAY=seconds, the first after that, as for a GL surface,
# whose frames come after the window's first. The bundle
# must be inside this checkout, such as .build/guest/<id>.app from
# AppRuntime's `guest.py bundle --target linux-arm64 --output .build/guest`.
#
#   Scripts/run-app.sh .build/guest/org.pureswift.ExampleUI.app .build/shots/ExampleUI.png
set -e
bundle=${1:?usage: Scripts/run-app.sh BUNDLE SCREENSHOT [linux-app-host arguments]}
screenshot=${2:?usage: Scripts/run-app.sh BUNDLE SCREENSHOT [linux-app-host arguments]}
shift 2
case "$(uname -m)" in
    arm64 | aarch64) target=linux-arm64 ;;
    *) target=linux-x86_64 ;;
esac
library="/src/$bundle/lib/$target/libapp.a"
LINUXAPPRUNTIME_APP_LIBRARY=$library exec "$(dirname "$0")/docker.sh" \
    "swift build --scratch-path .build/linux --product linux-app-host && CACAO_SCREENSHOT=/src/$screenshot .build/linux/debug/linux-app-host --bundle /src/$bundle $*"
