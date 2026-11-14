# Builds PortMaster ports for aarch64 handhelds (PortMaster.md §4): Swift
# 6.4.2 on Ubuntu 22.04, the oldest glibc (2.35) Swift 6.4 ships for, and
# SDL3 and SDL3_ttf built from source.
FROM swift:6.4.2-jammy

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        cmake ninja-build pkg-config git ca-certificates curl python3 fonts-dejavu-core \
        libdrm-dev libgbm-dev libegl-dev libgles-dev libasound2-dev libudev-dev \
        libwayland-dev libxkbcommon-dev wayland-protocols libdecor-0-dev \
 && rm -rf /var/lib/apt/lists/*

# What `linux-app portmaster` bundles.
ENV LINUXAPPRUNTIME_PORT_LIBS=/opt/portmaster/libs
COPY build-sdl.sh /opt/portmaster/
# Into /usr: the Swift toolchain's linker doesn't search /usr/local.
RUN PORT_LIBS=$LINUXAPPRUNTIME_PORT_LIBS /opt/portmaster/build-sdl.sh /usr \
        -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu -DSDL_WAYLAND=ON \
 && ldconfig \
 && cp -L /usr/lib/aarch64-linux-gnu/libstdc++.so.6 /lib/aarch64-linux-gnu/libgcc_s.so.1 $LINUXAPPRUNTIME_PORT_LIBS/

# The headless driver, for testing ports.
ENV SDL_VIDEO_DRIVER=offscreen
