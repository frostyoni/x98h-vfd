# x98h-vfd — front 7-segment display driver for the X98H (Allwinner H618)

Drives the 4-digit blue 7-segment panel on the front of an **X98H** TV box running
Armbian, and turns it into a usable clock/notification display.

```
x98h-vfd --scroll "ALL SYSTEMS GO" --loops 2
x98h-vfd --hold "CHECK SD"          # stays until: x98h-vfd --release
x98h-vfd --status
```

## What this panel actually is

It is **not** 12 GPIOs. The panel hangs off an **SM1628/TM1623-class serial LED
driver — three wires** — and the pin map is declared in the *vendor bootloader's*
device tree (U-Boot `VNDRBOOT` partition on eMMC, DTB at offset 6144):

```dts
aw_vfd {
    compatible = "amediatech,yxt_vfd";
    vfd_data_gpio  = <&pio 2 2 0>;    /* PC2  -> gpiochip1 line 66 */
    vfd_clock_gpio = <&pio 2 7 0>;    /* PC7  -> line 71 */
    vfd_stb_gpio   = <&pio 2 12 0>;   /* PC12 -> line 76 */
};
```

Bank numbering was confirmed two independent ways: `cd-gpios = <&pio 5 6>`
resolves to `gpio-166` = PG6, and the eMMC pin group (`sdc2`) uses
`PC1,PC5,PC6,PC8..PC11,PC13..PC16` — i.e. exactly the pads PC2/PC7/PC12 skip.

Nothing in the mainline/Armbian DT describes this panel, and the kernel resets
pin state at probe, so the running OS cannot tell you what U-Boot had muxed.
Also note: the vendor U-Boot has **`bootdelay=0`**, so the serial console is
output-only — there is no `=>` prompt to query.

## Protocol

TM16xx-style 3-wire: `STB` low selects the chip, data is clocked **LSB-first** on
`CLK` rising edges, `STB` high latches.

| byte | meaning |
|---|---|
| `0x40` | write mode |
| `0xC0 + addr` | followed by one data byte |
| `0x88 \| brightness` | display on (brightness 0-7) |
| `0x80` | display off |

**The matrix is transposed**: *address* selects the segment line, *data bit*
selects the digit.

```
segments  a=addr 0   b=2   c=4   d=6   e=8   f=10   g=12     (odd addresses unused)
digits    bit 7 = leftmost … bit 6, bit 5, bit 4 = rightmost
icons     bit 3, selected per segment address:
          usb@4  card@6  colon@8  hd@10  cvbs@12
```

Icons **share the address byte with a segment**, so icon bits must be OR'd into
the segment byte — writing an icon separately silently wipes that segment.

## Letter approximations

A 7-segment display has no real X, K, M, W, etc. The convention used here:

| letter | rendered as | | letter | rendered as |
|---|---|---|---|---|
| X, K, M, W | `H` | | Z, S | `2` |
| G | `6` | | N | `n` |
| V | `U` | | Y, y | `y` |
| Q | `0` | | B | `b` |

Unknown characters render blank, so text degrades predictably.

## Architecture

```
            ┌──────────────┐  /run/x98h-vfd.sock   ┌────────────────┐
  callers → │ x98h-vfd CLI │ ───────────────────→  │      vfdd      │ → PC2/PC7/PC12
            └──────────────┘        (JSON)         │  owns the pins │
                                                    │  clock when idle│
                                                    └────────────────┘
```

One process owns the GPIO lines (`vfdd`). Everything else hands it messages, so
nothing ever collides with the clock:

- **default**: a message displays, then yields back to the clock
- **`--duration 30s|10m|1h`**: yields after that time
- **`--loops N`**: scroll N times, then yield
- **`--hold`**: stays until `x98h-vfd --release`, or a **higher priority** message
- **priority**: `0` clock, `10` normal, `20` alert (the failed-unit watcher uses 20)

Text length is unlimited (it scrolls). If the daemon isn't running, the CLI falls
back to driving the pins directly.

## Install (Armbian/Debian, python3-libgpiod)

```sh
apt install python3-libgpiod
install -D x98h_vfd.py /usr/local/lib/python3.13/dist-packages/x98h_vfd.py
install -m755 vfdd x98h-vfd /usr/local/bin/
install -m644 vfdd.service /etc/systemd/system/
printf 'SUBSYSTEM=="gpio", KERNEL=="gpiochip*", GROUP="gpio", MODE="0660"\n' \
  > /etc/udev/rules.d/60-gpiochip.rules
systemctl daemon-reload && systemctl enable --now vfdd
```

The daemon starts from `sysinit.target` so it can show `boot` while the system
comes up that early; it shows the clock once idle, and `ERRn` for 4 s whenever
`systemctl --failed` is non-empty.

## Shutdown behaviour

These boxes have no power button (the vendor expects the IR remote), so a
shutdown **halts the SoC but never drops the 5 V rail** — the panel keeps
whatever was last latched. `vfdd` therefore latches `bye` in its SIGTERM handler,
so a halted box shows `bye` until someone cuts power. If you see the clock still
running after a shutdown, the machine is merely halted, not stuck.

## Notes / gotchas

- `gpioset` in gpiod v2 has no `--mode=wait`; hold lines with `-p <period>`.
- `/dev/gpiochip*` is `0600 root:root` by default — the udev rule above is needed
  for non-root use.
- Only one process may hold the lines: a second `x98h-vfd` while `vfdd` runs gets
  `EBUSY` unless it goes through the socket.
- Backing up: keep the SD card as the recovery medium; the eMMC (Android) is
  untouched by this project.

## Files

| file | role |
|---|---|
| `x98h_vfd.py` | driver: GPIO bit-banging, font, transposed-matrix render |
| `vfdd` | daemon: owns the pins, clock, arbitration, failure watcher |
| `x98h-vfd` | CLI client (with direct-mode fallback) |
| `vfdd.service` | systemd unit |
