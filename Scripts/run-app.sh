#!/bin/sh
# Builds linux-app-host linked with a universal bundle's Linux slice and runs
# it in the development image, headless (SDL's offscreen driver). The bundle
# must be inside this checkout, such as .build/guest/<id>.app from
# AppRuntime's `guest.py bundle --target linux-arm64 --output .build/guest`.
#
#   Scripts/run-app.sh .build/guest/org.pureswift.ExampleUI.app --script Scripts/ExampleUI.script
#
# Screenshots a script takes land where it says, inside the container; paths
# under /src are this checkout.
set -e
bundle=${1:?usage: Scripts/run-app.sh BUNDLE [linux-app-host arguments]}
shift
case "$(uname -m)" in
    arm64 | aarch64) target=linux-arm64 ;;
    *) target=linux-x86_64 ;;
esac
library="/src/$bundle/lib/$target/libapp.a"
LINUXAPPRUNTIME_APP_LIBRARY=$library exec "$(dirname "$0")/docker.sh" \
    "swift build --scratch-path .build/linux --product linux-app-host && .build/linux/debug/linux-app-host --bundle /src/$bundle $*"
