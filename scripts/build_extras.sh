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
DONGIE_RS_REPO=${DONGIE_RS_REPO=https://github.com/derpyspike/dongie-rs.git}
DONGIE_RS_REF=${DONGIE_RS_REF=v0.2.0}
DONGIE_IMS_REPO=${DONGIE_IMS_REPO=https://github.com/derpyspike/dongie-ims.git}
DONGIE_IMS_REF=${DONGIE_IMS_REF=v0.2.0}
if [ "${WITH_DONGIE:-1}" = 1 ]; then
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

    # complete corresponding source, including vendored Rust/Go dependencies
    (cd ${SRC}/dongie-rs && cargo vendor -q --locked vendor >/dev/null && mkdir -p .cargo && \
        printf '\n[source.crates-io]\nreplace-with = "vendored-sources"\n\n[source.vendored-sources]\ndirectory = "vendor"\n' >> .cargo/config.toml)
    (cd ${SRC}/dongie-ims && go mod vendor)
    rm -rf ${SRC}/dongie-rs/target ${SRC}/dongie-rs/.git ${SRC}/dongie-ims/.git ${SRC}/dongie-ims/dongie-ims
    tar -C ${SRC} -cJf files/sources-dongie-rs-${DONGIE_RS_REF}.tar.xz dongie-rs
    tar -C ${SRC} -cJf files/sources-dongie-ims-${DONGIE_IMS_REF}.tar.xz dongie-ims
fi
