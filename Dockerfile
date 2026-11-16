# Linux environment for building and testing the host: Swift 6.4.2, SDL3,
# Cairo, FreeType, fontconfig and Wayland for Cacao, a font, Mesa's EGL and
# GLES 2.0 for GL surfaces (llvmpipe without a GPU), Python for AppRuntime's
# scripts, and WABT for the packager's wasm2c engine.
FROM swift:6.4.2

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        libsdl3-dev libsdl3-ttf-dev libfontconfig-dev fonts-dejavu-core \
        libcairo2-dev libfreetype-dev libwayland-dev wayland-protocols \
        libegl1 libegl-mesa0 libgles-dev libgl1-mesa-dri \
        pkgconf python3 wabt curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Ubuntu's wabt leaves out two files its wasm2c runtime includes; these are
# from the same release.
RUN cd /usr/share/wabt/wasm2c \
 && curl -fsSLO https://raw.githubusercontent.com/WebAssembly/wabt/1.0.36/wasm2c/wasm-rt-impl-tableops.inc \
 && curl -fsSLO https://raw.githubusercontent.com/WebAssembly/wabt/1.0.36/wasm2c/wasm-rt-mem-impl-helper.inc \
 && echo "fb0f00fa46edd9bee433f42a8868c7d082d52e97a699a6a8e2b345a8cd695fcd  wasm-rt-impl-tableops.inc" | sha256sum -c - \
 && echo "cde415d8cc9299abc8c596892f051f3ec96dae2c84d73cec83a72c7cecad969f  wasm-rt-mem-impl-helper.inc" | sha256sum -c -

# SDL's headless driver, for tests and screenshots without a display.
ENV SDL_VIDEO_DRIVER=offscreen
