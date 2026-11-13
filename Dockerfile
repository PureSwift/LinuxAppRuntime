# Linux environment for building and testing the host: Swift 6.4.2, SDL3
# and SDL3_ttf for the player, fontconfig and a font for its text, and
# Python for AppRuntime's guest.py.
FROM swift:6.4.2

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        libsdl3-dev libsdl3-ttf-dev libfontconfig-dev fonts-dejavu-core \
        pkgconf python3 \
 && rm -rf /var/lib/apt/lists/*

# SDL's headless driver, for tests and screenshots without a display.
ENV SDL_VIDEO_DRIVER=offscreen
