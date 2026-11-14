#!/bin/sh
# Builds SDL3 and SDL3_ttf (with FreeType and HarfBuzz built in) for a
# PortMaster port, and gathers what a port bundles into $PORT_LIBS: the
# libraries, the C++ runtime, and their licenses.
#
#   build-sdl.sh PREFIX [cmake arguments for both builds …]
#
# DESTDIR installs into a sysroot when cross-compiling. SDL3_TAG and
# SDL3_TTF_TAG pick the releases.
set -e
prefix=$1
shift
SDL3_TAG=${SDL3_TAG:-release-3.4.20}
SDL3_TTF_TAG=${SDL3_TTF_TAG:-release-3.2.2}
work=$(mktemp -d)
cd "$work"

git clone -q --depth 1 --branch "$SDL3_TAG" https://github.com/libsdl-org/SDL.git
# KMSDRM for handhelds, Wayland where the image has it (sway on some
# firmware), offscreen for tests; no X11, and the audio and input backends
# SDL loads at run time.
cmake -S SDL -B SDL/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_INSTALL_TESTS=OFF -DSDL_EXAMPLES=OFF \
    -DSDL_X11=OFF -DSDL_KMSDRM=ON -DSDL_OFFSCREEN=ON -DSDL_OPENGLES=ON -DSDL_VULKAN=OFF \
    -DSDL_PULSEAUDIO=OFF -DSDL_PIPEWIRE=OFF -DSDL_JACK=OFF -DSDL_SNDIO=OFF \
    "$@"
cmake --build SDL/build
cmake --install SDL/build

git clone -q --depth 1 --branch "$SDL3_TTF_TAG" --recurse-submodules --shallow-submodules https://github.com/libsdl-org/SDL_ttf.git
cmake -S SDL_ttf -B SDL_ttf/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_PREFIX_PATH="${DESTDIR}${prefix}" -DSDL3_DIR="${DESTDIR}${prefix}/lib/cmake/SDL3" \
    -DBUILD_SHARED_LIBS=ON -DSDLTTF_VENDORED=ON -DSDLTTF_HARFBUZZ=ON -DSDLTTF_PLUTOSVG=OFF -DSDLTTF_SAMPLES=OFF \
    "$@"
cmake --build SDL_ttf/build
cmake --install SDL_ttf/build

mkdir -p "$PORT_LIBS/licenses"
cp -L "${DESTDIR}${prefix}"/lib*/libSDL3.so.0 "${DESTDIR}${prefix}"/lib*/libSDL3_ttf.so.0 "$PORT_LIBS"/ 2>/dev/null \
    || cp -L "${DESTDIR}${prefix}"/lib/*/libSDL3.so.0 "${DESTDIR}${prefix}"/lib/*/libSDL3_ttf.so.0 "$PORT_LIBS"/
cp SDL/LICENSE.txt "$PORT_LIBS/licenses/SDL3.txt"
cp SDL_ttf/LICENSE.txt "$PORT_LIBS/licenses/SDL3_ttf.txt"
cp SDL_ttf/external/freetype/LICENSE.TXT "$PORT_LIBS/licenses/FreeType.txt"
cp SDL_ttf/external/harfbuzz/COPYING "$PORT_LIBS/licenses/HarfBuzz.txt"
cd /
rm -rf "$work"
