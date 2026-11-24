#!/bin/sh
# install.sh - install x98h-vfd (driver + daemon + client) on Debian/Armbian.
# Run as root:  sudo ./install.sh
set -e

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
PYVER=$(python3 -c 'import sys; print("python%d.%d" % sys.version_info[:2])')
DEST=/usr/local/lib/$PYVER/dist-packages

command -v gpioset >/dev/null || apt-get install -y gpiod
python3 -c 'import gpiod' 2>/dev/null || apt-get install -y python3-libgpiod

install -D -m644 x98h_vfd.py "$DEST/x98h_vfd.py"
install -m755 vfdd x98h-vfd /usr/local/bin/
install -m644 vfdd.service /etc/systemd/system/

# /dev/gpiochip* is root:root 0600 by default
printf 'SUBSYSTEM=="gpio", KERNEL=="gpiochip*", GROUP="gpio", MODE="0660"\n' \
  > /etc/udev/rules.d/60-gpiochip.rules
udevadm control --reload-rules && udevadm trigger --subsystem-match=gpio || true

systemctl daemon-reload
systemctl enable --now vfdd.service
systemctl --no-pager status vfdd.service | head -3
echo "installed. try: x98h-vfd --scroll 'HELLO' --loops 1"
