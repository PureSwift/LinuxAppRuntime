#!/bin/sh
# Builds SDL3 from source for the development image and CI, which run on
# Debian 13: its SDL is 3.2, and PureSwift/SDL needs 3.4. Only the offscreen
# driver, for tests and screenshots without a display.
#
#   Scripts/build-sdl3.sh PREFIX [cmake arguments …]
#
# SDL3_TAG picks the release, as Docker/build-sdl.sh's does for ports.
set -e
prefix=${1:?usage: Scripts/build-sdl3.sh PREFIX [cmake arguments …]}
shift
SDL3_TAG=${SDL3_TAG:-release-3.4.20}
work=$(mktemp -d)
git clone -q --depth 1 --branch "$SDL3_TAG" https://github.com/libsdl-org/SDL.git "$work/SDL"
cmake -S "$work/SDL" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_INSTALL_TESTS=OFF -DSDL_EXAMPLES=OFF \
    -DSDL_UNIX_CONSOLE_BUILD=ON -DSDL_X11=OFF -DSDL_WAYLAND=OFF -DSDL_KMSDRM=OFF -DSDL_OFFSCREEN=ON -DSDL_VULKAN=OFF \
    -DSDL_PULSEAUDIO=OFF -DSDL_PIPEWIRE=OFF -DSDL_JACK=OFF -DSDL_SNDIO=OFF -DSDL_ALSA=OFF \
    "$@"
cmake --build "$work/build"
cmake --install "$work/build"
rm -rf "$work"
