#!/bin/sh -e
# Optional extras, staged into dist/ (build_images.sh copies dist/ into the rootfs).
# Every part can be switched off: WITH_FIX_ATTACH_APN=0 ./build.sh
DIST=${DIST=$(pwd)/dist}
X=configs/extras

enable_unit() { # enable a unit the same way systemctl would (no running systemd needed)
    mkdir -p ${DIST}/etc/systemd/system/multi-user.target.wants
    ln -sf /etc/systemd/system/$1 ${DIST}/etc/systemd/system/multi-user.target.wants/$1
}

mkdir -p ${DIST}/etc/systemd/system ${DIST}/usr/local/sbin

# fix-attach-apn: the UZ801 modem firmware resets its LTE attach APN to
# 'mobile.three.com.hk' at every modem boot; this sets the right one for the SIM.
if [ "${WITH_FIX_ATTACH_APN:-1}" = 1 ]; then
    install -m 0755 ${X}/fix-attach-apn ${DIST}/usr/local/sbin/fix-attach-apn
    install -m 0644 ${X}/fix-attach-apn.service ${DIST}/etc/systemd/system/
    enable_unit fix-attach-apn.service
fi

# fewer flash writes: small journal, quieter NetworkManager/ModemManager logs
# (measured on a UZ801: ~8 KiB/min of writes when idle)
if [ "${WITH_FLASH_TWEAKS:-1}" = 1 ]; then
    install -D -m 0644 ${X}/journald-flash.conf ${DIST}/etc/systemd/journald.conf.d/50-flash.conf
    install -D -m 0644 ${X}/NetworkManager-quiet.conf ${DIST}/etc/NetworkManager/conf.d/50-quiet.conf
    install -D -m 0644 ${X}/ModemManager-quiet.conf ${DIST}/etc/systemd/system/ModemManager.service.d/50-quiet.conf
fi

# dongie-rs (web dashboard + API: modem, SMS, hotspot; EUPL-1.2) and dongie-ims
# (Wi-Fi calling/VoWiFi + SMS over IMS, calls in the browser; GPL-3.0).
# Built from source at a pinned tag; their complete source (with vendored
# dependencies) is written to files/ next to the images.
# Needs: git, cargo with target aarch64-unknown-linux-musl, go >= 1.26.
# Versions: configs/extras/dongie-versions (also used by flake.nix).
# DONGIE_PREBUILT=<dir> uses binaries + source archives built elsewhere instead
# (layout of `nix build .#dongie`: bin/dongie, bin/dongie-ims, sources/*.tar.xz).
. ${X}/dongie-versions
DONGIE_RS_REPO=${DONGIE_RS_REPO=https://github.com/derpyspike/dongie-rs.git}
DONGIE_IMS_REPO=${DONGIE_IMS_REPO=https://github.com/derpyspike/dongie-ims.git}
if [ "${WITH_DONGIE:-1}" = 1 ] && [ -n "${DONGIE_PREBUILT}" ]; then
    mkdir -p files
    install -D -m 0755 ${DONGIE_PREBUILT}/bin/dongie ${DIST}/usr/local/bin/dongie
    install -D -m 0755 ${DONGIE_PREBUILT}/bin/dongie-ims ${DIST}/usr/local/bin/dongie-ims
    install -m 0644 ${DONGIE_PREBUILT}/sources/*.tar.xz files/
elif [ "${WITH_DONGIE:-1}" = 1 ]; then
    for t in git cargo go; do
        command -v $t >/dev/null || { echo "build_extras: '$t' not found (or build with WITH_DONGIE=0)"; exit 1; }
    done
    SRC=$(pwd)/build/extras
    rm -rf ${SRC} && mkdir -p ${SRC} files
    git clone -q --depth 1 -b ${DONGIE_RS_REF} ${DONGIE_RS_REPO} ${SRC}/dongie-rs
    git clone -q --depth 1 -b ${DONGIE_IMS_REF} ${DONGIE_IMS_REPO} ${SRC}/dongie-ims

    (cd ${SRC}/dongie-rs && cargo build -q --release --locked --target aarch64-unknown-linux-musl)
    (cd ${SRC}/dongie-ims && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
        go build -trimpath -ldflags='-s -w' -o dongie-ims .)

    install -D -m 0755 ${SRC}/dongie-rs/target/aarch64-unknown-linux-musl/release/dongie ${DIST}/usr/local/bin/dongie
    install -D -m 0755 ${SRC}/dongie-ims/dongie-ims ${DIST}/usr/local/bin/dongie-ims

    # complete corresponding source, including vendored Rust/Go dependencies
    (cd ${SRC}/dongie-rs && cargo vendor -q --locked vendor >/dev/null && mkdir -p .cargo && \
        printf '\n[source.crates-io]\nreplace-with = "vendored-sources"\n\n[source.vendored-sources]\ndirectory = "vendor"\n' >> .cargo/config.toml)
    (cd ${SRC}/dongie-ims && go mod vendor)
    rm -rf ${SRC}/dongie-rs/target ${SRC}/dongie-rs/.git ${SRC}/dongie-ims/.git ${SRC}/dongie-ims/dongie-ims
    tar -C ${SRC} -cJf files/sources-dongie-rs-${DONGIE_RS_REF}.tar.xz dongie-rs
    tar -C ${SRC} -cJf files/sources-dongie-ims-${DONGIE_IMS_REF}.tar.xz dongie-ims
fi

# muxtastic (shares one Meshtastic node between apps; AGPL-3.0-or-later,
# https://github.com/derpyspike/muxtastic): for a node with Wi-Fi on the
# stick's hotspot. Shown on dongie's Mesh tab. Installed, NOT enabled (it
# needs the node's address first). Has C parts (SQLite, aws-lc): needs zig
# (or `pip install ziglang`) as the aarch64 C compiler, plus cmake.
# MUXTASTIC_PREBUILT=<dir> takes bin/muxtastic + sources/*.tar.xz instead.
MUXTASTIC_REPO=${MUXTASTIC_REPO=https://github.com/derpyspike/muxtastic.git}
if [ "${WITH_MUXTASTIC:-1}" = 1 ] && [ -n "${MUXTASTIC_PREBUILT}" ]; then
    mkdir -p files
    install -D -m 0755 ${MUXTASTIC_PREBUILT}/bin/muxtastic ${DIST}/usr/local/bin/muxtastic
    install -m 0644 ${MUXTASTIC_PREBUILT}/sources/*.tar.xz files/
elif [ "${WITH_MUXTASTIC:-1}" = 1 ]; then
    command -v zig >/dev/null || python3 -m ziglang version >/dev/null 2>&1 || \
        { echo "build_extras: zig not found (pip install ziglang, or build with WITH_MUXTASTIC=0)"; exit 1; }
    for t in git cargo cmake; do
        command -v $t >/dev/null || { echo "build_extras: '$t' not found (or build with WITH_MUXTASTIC=0)"; exit 1; }
    done
    SRC=$(pwd)/build/extras-muxtastic
    ZCC=$(pwd)/scripts/zigcc-aarch64-musl
    rm -rf ${SRC} && mkdir -p ${SRC} files
    git clone -q --depth 1 -b ${MUXTASTIC_REF} ${MUXTASTIC_REPO} ${SRC}/muxtastic
    (cd ${SRC}/muxtastic && \
        CC_aarch64_unknown_linux_musl=${ZCC} AR_aarch64_unknown_linux_musl=${ZCC}-ar \
        CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=rust-lld \
        CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C target-feature=+crt-static" \
        cargo build -q --release --locked --target aarch64-unknown-linux-musl -p muxtastic)
    install -D -m 0755 ${SRC}/muxtastic/target/aarch64-unknown-linux-musl/release/muxtastic ${DIST}/usr/local/bin/muxtastic
    # complete corresponding source (AGPL), with vendored dependencies
    (cd ${SRC}/muxtastic && cargo vendor -q --locked vendor >/dev/null && mkdir -p .cargo && \
        printf '\n[source.crates-io]\nreplace-with = "vendored-sources"\n\n[source.vendored-sources]\ndirectory = "vendor"\n' >> .cargo/config.toml)
    rm -rf ${SRC}/muxtastic/target ${SRC}/muxtastic/.git
    tar -C ${SRC} -cJf files/sources-muxtastic-${MUXTASTIC_REF}.tar.xz muxtastic
fi
if [ "${WITH_MUXTASTIC:-1}" = 1 ]; then
    install -D -m 0644 ${X}/muxtastic.service ${DIST}/etc/systemd/system/muxtastic.service
    install -D -m 0644 ${X}/muxtastic.toml ${DIST}/etc/muxtastic/muxtastic.toml
    # not enabled: set tcp_host in /etc/muxtastic/muxtastic.toml, then
    # systemctl enable --now muxtastic
fi

if [ "${WITH_DONGIE:-1}" = 1 ]; then
    install -D -m 0644 ${X}/dongie.service ${DIST}/etc/systemd/system/dongie.service
    install -D -m 0644 ${X}/dongie-ims.service ${DIST}/etc/systemd/system/dongie-ims.service
    install -D -m 0640 ${X}/dongie.toml ${DIST}/etc/dongie/config.toml
    install -D -m 0644 ${X}/dongie.sysusers ${DIST}/usr/lib/sysusers.d/dongie.conf
    install -D -m 0644 ${X}/dongie.tmpfiles ${DIST}/usr/lib/tmpfiles.d/dongie.conf
    install -D -m 0644 ${X}/50-dongie.rules ${DIST}/etc/polkit-1/rules.d/50-dongie.rules
    install -D -m 0440 ${X}/sudoers-dongie ${DIST}/etc/sudoers.d/dongie
    if command -v visudo >/dev/null; then visudo -cqf ${DIST}/etc/sudoers.d/dongie; fi
    enable_unit dongie.service
    # dongie-ims is NOT enabled: registering for Wi-Fi calling moves the SIM's
    # calls to the stick. Turn on with: systemctl enable --now dongie-ims
fi
