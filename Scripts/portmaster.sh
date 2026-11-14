#!/bin/sh
# Builds and tests PortMaster ports (Documentation/PortMaster.md).
#
#   Scripts/portmaster.sh build BUNDLE [aarch64|armhf|all] [linux-app portmaster options …]
#   Scripts/portmaster.sh test [aarch64|armhf] [SCRIPT]
#
# `build` runs `linux-app portmaster` in Docker/portmaster-<arch>.Dockerfile's
# image, building the image first if needed; ports go to .build/portmaster.
# BUNDLE must be inside this checkout. `test` runs the built port as
# PortMaster would, with a stand-in control.txt, in Ubuntu 22.04 (armhf under
# emulation), headless; SCRIPT (inside this
# checkout) drives it, and screenshots go where it says, under /src.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
command=${1:?usage: Scripts/portmaster.sh build BUNDLE [arch] … | test [arch] [SCRIPT]}
shift

image() {
    name=linuxappruntime-portmaster-$1
    if ! docker image inspect "$name" >/dev/null 2>&1; then
        docker build -t "$name" -f "$root/Docker/portmaster-$1.Dockerfile" "$root/Docker"
    fi
    echo "$name"
}

architectures() {
    case "${1:-all}" in
        all) echo "aarch64 armhf" ;;
        aarch64 | armhf) echo "$1" ;;
        *) echo "unknown architecture $1" >&2; exit 1 ;;
    esac
}

case "$command" in
build)
    bundle=${1:?usage: Scripts/portmaster.sh build BUNDLE [arch] …}
    shift
    arches=$(architectures "${1:-all}")
    [ $# -gt 0 ] && shift
    for arch in $arches; do
        case $arch in aarch64) target=linux-arm64 ;; armhf) target=linux-armv7 ;; esac
        mounts=""
        if [ -n "$APPRUNTIME_PATH" ]; then
            mounts="-v $APPRUNTIME_PATH:/AppRuntime -e APPRUNTIME_PATH=/AppRuntime"
        fi
        # shellcheck disable=SC2086
        docker run --rm -v "$root:/src" -w /src -v linuxappruntime-swiftpm:/root/.cache $mounts "$(image $arch)" bash -c "
            set -e
            swift build --scratch-path .build/portmaster-$arch/tool --product linux-app
            .build/portmaster-$arch/tool/debug/linux-app portmaster '/src/$bundle' --target $target \
                --work .build/portmaster-$arch/work --output /src/.build/portmaster $*"
    done
    ;;
test)
    arches=$(architectures "${1:-aarch64}")
    script=${2:-}
    for arch in $arches; do
        case $arch in
            aarch64) platform=linux/arm64 distribution=ubuntu:22.04 ;;
            armhf) platform=linux/arm/v7 distribution=ubuntu:22.04 ;;
        esac
        port=$(find "$root/.build/portmaster" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | head -1)
        name=$(basename "$port")
        launcher=$(find "$port" -maxdepth 1 -name '*.sh' | head -1)
        # The tag holds one platform at a time: pull the one wanted.
        docker pull -q --platform "$platform" "$distribution" >/dev/null
        docker run --rm --platform "$platform" \
            -v "$root:/src" -v "$port/$name:/roms/ports/$name" -v "$launcher:/roms/ports/$(basename "$launcher")" \
            -v "$root/Scripts/portmaster-control.txt:/roms/ports/PortMaster/control.txt" \
            -e DEVICE_ARCH=$arch -e LINUXAPPRUNTIME_SCRIPT="$script" \
            "$distribution" bash "/roms/ports/$(basename "$launcher")"
        # The launcher ends with pm_finish, so its status says nothing: the
        # log does.
        if grep -E "error|No such file|cannot open" "$port/$name/log.txt"; then
            echo "$arch: the port failed" >&2
            exit 1
        fi
        echo "$arch: ok"
    done
    ;;
*)
    echo "unknown command $command" >&2
    exit 1
    ;;
esac
