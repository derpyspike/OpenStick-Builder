#!/bin/sh -e
# Optional extras, staged into dist/ (build_images.sh copies dist/ into the rootfs).
# Every part can be switched off: WITH_FIX_ATTACH_APN=0 ./build.sh
DIST=${DIST=$(pwd)/dist}
X=configs/extras

enable() { # enable a unit the same way systemctl would (no running systemd needed)
    mkdir -p ${DIST}/etc/systemd/system/multi-user.target.wants
    ln -sf /etc/systemd/system/$1 ${DIST}/etc/systemd/system/multi-user.target.wants/$1
}

mkdir -p ${DIST}/etc/systemd/system ${DIST}/usr/local/sbin

# fix-attach-apn: the UZ801 modem firmware resets its LTE attach APN to
# 'mobile.three.com.hk' at every modem boot; this sets the right one for the SIM.
if [ "${WITH_FIX_ATTACH_APN:-1}" = 1 ]; then
    install -m 0755 ${X}/fix-attach-apn ${DIST}/usr/local/sbin/fix-attach-apn
    install -m 0644 ${X}/fix-attach-apn.service ${DIST}/etc/systemd/system/
    enable fix-attach-apn.service
fi

# fewer flash writes: small journal, quieter NetworkManager/ModemManager logs
# (measured on a UZ801: ~8 KiB/min of writes when idle)
if [ "${WITH_FLASH_TWEAKS:-1}" = 1 ]; then
    install -D -m 0644 ${X}/journald-flash.conf ${DIST}/etc/systemd/journald.conf.d/50-flash.conf
    install -D -m 0644 ${X}/NetworkManager-quiet.conf ${DIST}/etc/NetworkManager/conf.d/50-quiet.conf
    install -D -m 0644 ${X}/ModemManager-quiet.conf ${DIST}/etc/systemd/system/ModemManager.service.d/50-quiet.conf
fi
