# Builds PortMaster ports for armhf handhelds (PortMaster.md §4): Swift 6.4.0
# on Ubuntu 22.04 with the community armv7 SDK for Ubuntu 22.04 (glibc
# 2.35), which PortMaster builds against, from
# swift-embedded-linux/armhf-debian (its destination for static Swift),
# and SDL3 and SDL3_ttf cross-compiled against its sysroot. The image itself
# runs on the build machine's architecture.
FROM swift:6.4.0-jammy

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        cmake ninja-build pkg-config git ca-certificates curl python3 fonts-dejavu-core lld \
 && rm -rf /var/lib/apt/lists/*

# The SDK, whose version matches the image's compiler. `linux-app` builds
# with it through SwiftPM's native build system, which takes destination files.
ARG SDK=swift-6.4.0-RELEASE-ubuntu-jammy-armv7
RUN curl -fsSL https://github.com/swift-embedded-linux/armhf-debian/releases/download/6.4.0/$SDK-sdk.tar.gz | tar -xz -C /opt \
 && ln -s "$(find /opt/$SDK -maxdepth 1 -name '*-static.json' | head -1)" /opt/armv7-destination.json \
 && ln -s "$(dirname "$(find /opt/$SDK -maxdepth 4 -type d -name arm-linux-gnueabihf -path '*/usr/lib/*' | head -1)" | xargs dirname | xargs dirname)" /opt/armv7-sysroot

# The headers SDL's KMSDRM, EGL and ALSA support needs, from Ubuntu 22.04's
# armhf packages; SDL loads the libraries themselves at run time.
RUN mkdir -p /tmp/jammy/lists/partial /tmp/jammy/archives/partial \
 && echo "deb [arch=armhf] http://ports.ubuntu.com/ubuntu-ports jammy main universe" > /tmp/jammy/sources.list \
 && apt="apt-get -o Dir::Etc::SourceList=/tmp/jammy/sources.list -o Dir::Etc::SourceParts=- -o Dir::State::Lists=/tmp/jammy/lists -o Dir::Cache::Archives=/tmp/jammy/archives -o APT::Architecture=armhf -o APT::Architectures=armhf -o Dir::State::Status=/dev/null" \
 && $apt update \
 && cd /tmp/jammy && $apt download libdrm-dev libdrm2 libgbm-dev libgbm1 libegl-dev libgles-dev libgl-dev libglx-dev libasound2-dev libasound2 libudev-dev libudev1 \
 && sysroot=$(readlink -f /opt/armv7-sysroot) \
 && for deb in /tmp/jammy/*.deb; do \
        rm -rf /tmp/jammy/x && dpkg-deb -x "$deb" /tmp/jammy/x \
        && if [ -d /tmp/jammy/x/lib ]; then mkdir -p $sysroot/usr/lib && cp -a /tmp/jammy/x/lib/. $sysroot/usr/lib/ && rm -rf /tmp/jammy/x/lib; fi \
        && cp -a /tmp/jammy/x/. $sysroot/; \
    done \
 && if [ ! -e $sysroot/lib ]; then ln -s usr/lib $sysroot/lib; fi \
 && rm -rf /tmp/jammy

# A CMake toolchain for the sysroot, with the image's clang and lld.
RUN printf '%s\n' \
        'set(CMAKE_SYSTEM_NAME Linux)' 'set(CMAKE_SYSTEM_PROCESSOR arm)' \
        'set(CMAKE_SYSROOT /opt/armv7-sysroot)' \
        'set(CMAKE_C_COMPILER clang)' 'set(CMAKE_CXX_COMPILER clang++)' \
        'set(CMAKE_C_COMPILER_TARGET armv7-unknown-linux-gnueabihf)' 'set(CMAKE_CXX_COMPILER_TARGET armv7-unknown-linux-gnueabihf)' \
        'set(CMAKE_C_FLAGS_INIT "-march=armv7-a -mfpu=neon -mfloat-abi=hard")' 'set(CMAKE_CXX_FLAGS_INIT "-march=armv7-a -mfpu=neon -mfloat-abi=hard")' \
        'set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld")' 'set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld")' \
        'set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)' 'set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)' \
        'set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)' 'set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)' \
        > /opt/armv7-toolchain.cmake

# SDL into the sysroot, where `swift build --destination` finds it.
ENV LINUXAPPRUNTIME_PORT_LIBS=/opt/portmaster/libs
ENV LINUXAPPRUNTIME_SWIFT_DESTINATION=/opt/armv7-destination.json
COPY build-sdl.sh /opt/portmaster/
RUN PKG_CONFIG_SYSROOT_DIR=/opt/armv7-sysroot \
    PKG_CONFIG_LIBDIR=/opt/armv7-sysroot/usr/lib/arm-linux-gnueabihf/pkgconfig:/opt/armv7-sysroot/usr/share/pkgconfig \
    DESTDIR=/opt/armv7-sysroot PORT_LIBS=$LINUXAPPRUNTIME_PORT_LIBS \
    /opt/portmaster/build-sdl.sh /usr -DCMAKE_TOOLCHAIN_FILE=/opt/armv7-toolchain.cmake \
        -DCMAKE_INSTALL_LIBDIR=lib/arm-linux-gnueabihf -DSDL_WAYLAND=OFF -DSDL_UNIX_CONSOLE_BUILD=ON \
 && cp -L /opt/armv7-sysroot/usr/lib/arm-linux-gnueabihf/libstdc++.so.6 \
          /opt/armv7-sysroot/lib/arm-linux-gnueabihf/libgcc_s.so.1 $LINUXAPPRUNTIME_PORT_LIBS/ 2>/dev/null \
 || cp -L /opt/armv7-sysroot/usr/lib/arm-linux-gnueabihf/libstdc++.so.6 \
          /opt/armv7-sysroot/usr/lib/arm-linux-gnueabihf/libgcc_s.so.1 $LINUXAPPRUNTIME_PORT_LIBS/

# The SDK links libatomic for 64-bit atomics on armv7, which handhelds may
# not have.
RUN cp -L "$(find /opt/armv7-sysroot/ -name 'libatomic.so.1' | head -1)" $LINUXAPPRUNTIME_PORT_LIBS/
