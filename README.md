ICM45686-mod
============
Out-of-tree Linux IIO driver for the [InvenSense/TDK **ICM-45686**](https://invensense.tdk.com/products/motion-tracking/6-axis/icm-45686/) 6-axis IMU (3-axis accel + 3-axis gyro + temperature) over I²C, plus a Raspberry Pi device-tree overlay so the chip auto-binds at boot.

This repo vendors the mainline `drivers/iio/imu/inv_icm45600` driver from `torvalds/linux` and wraps it for out-of-tree (OOT) builds. The upstream driver supports the entire ICM-456xx family (ICM-45605/45606/45608/45634/**45686**/45687/45688-P/45689); we just need an OOT build of it because the Raspberry Pi 6.18 kernel doesn't ship that driver yet (only `inv_icm42600` and `inv_mpu6050`). Hardware FIFO is implemented in the vendored driver; see [TODO.md](TODO.md) for INT1 bring-up and kingfisher integration work.

Tested target: Raspberry Pi running kernel `6.18.29+rpt-rpi-v8` (Debian Trixie). The chip is expected to live on `i2c-1` at address `0x68` (AP_AD0 = 0).

Vendored from
-------------
The seven driver source files (`inv_icm45600*.{c,h}`) are copied verbatim from `torvalds/linux` at commit `27fa826` (2026-05-19). When pulling updates, re-fetch from `https://raw.githubusercontent.com/torvalds/linux/<sha>/drivers/iio/imu/inv_icm45600/` and update this line. The upstream `Kconfig` and `Makefile` are preserved as `Kconfig.upstream` / `Makefile.upstream` for reference; they are not used by the OOT build.

Build
-----
Requires a prepared kernel build tree at `/lib/modules/$(uname -r)/build`. The Makefile defaults to that path; override `KDIR=...` if your tree is elsewhere.

```sh
make            # produces inv-icm45600.ko + inv-icm45600-i2c.ko
make dtbo       # produces dts/icm45686.dtbo
```

### Setting up the build tree

**Distro-packaged kernel** (Raspberry Pi OS, Debian/Ubuntu, etc.):

```sh
sudo apt install raspberrypi-kernel-headers    # Raspberry Pi
# or
sudo apt install linux-headers-$(uname -r)     # generic Debian/Ubuntu
```

The package places headers under `/usr/src/linux-headers-$(uname -r)` and registers the `/lib/modules/$(uname -r)/build` symlink for you.

**Custom or rpi-update kernel** (no headers package available): point at a kernel source tree of the *exact* same version, prepare it, and link it:

```sh
sudo apt install bc bison flex libssl-dev libncurses-dev
git clone --depth=1 --branch <matching-tag> https://github.com/raspberrypi/linux /root/linux
cd /root/linux
cp /proc/config.gz /tmp/config.gz && gunzip -c /tmp/config.gz > .config
make modules_prepare
make -j$(nproc) modules
sudo make -C /path/to/icm45686-mod setup-kbuild KSRC=/root/linux
```

`setup-kbuild` verifies the KSRC tree matches `$(uname -r)` and has `Module.symvers`, then creates the symlink. Re-run after anything (apt updates, depmod sweeps) wipes it.

Install (persistent, via DKMS — recommended)
--------------------------------------------
DKMS rebuilds the module automatically on every kernel upgrade, so a routine
`apt` kernel bump can't silently leave you with a dead sensor. This is the
recommended install on any machine that gets kernel updates.

On a Raspberry Pi with the sensor wired to `i2c-1` at `0x68`:

```sh
sudo apt install -y dkms linux-headers-rpi-2712   # meta-pkg tracks the running kernel
sudo make dkms-install                            # copies sources to /usr/src, dkms add/build/install
sudo make overlay-install                         # dtbo + config.txt (DKMS does not manage these)
sudo reboot
```

- **`make dkms-install`** copies the driver sources into `/usr/src/icm45686-1.0`,
  then runs `dkms add/build/install`. The module lands in
  `/lib/modules/$(uname -r)/updates/dkms/`. `AUTOINSTALL=yes` (in `dkms.conf`)
  rebuilds it for each new kernel — provided `linux-headers-rpi-2712` keeps the
  matching headers installed. Re-run `sudo make dkms-install` after editing any
  driver source (it re-copies `/usr/src` and rebuilds).
- **`make overlay-install`** = `dtbo_install` + `config_enable`: builds
  `dts/icm45686.dtbo` into `/boot/firmware/overlays/` (falls back to
  `/boot/overlays/`; override `DTBO_DIR=...`) and appends `dtoverlay=icm45686`
  to `/boot/firmware/config.txt` (override `CONFIG_TXT=...`) if not present.

Sources are **copied** into `/usr/src`, not symlinked, so moving or renaming
this repo won't break the autoinstall rebuild — the failure mode DKMS exists to
prevent. The cost is that you must re-run `make dkms-install` after source edits.

Verify: `dkms status` should show `icm45686/1.0, <kernel>: installed`.

After reboot the kernel matches the overlay's `compatible = "invensense,icm45686"` against `inv-icm45600-i2c`'s OF table and probes automatically. Sensor data appears under `/sys/bus/iio/devices/iio:deviceN/` with `name` reading `icm45686`.

Rebuild after a driver-source change:

```sh
sudo make dkms-install    # re-copies /usr/src and rebuilds for the running kernel
```

Install (persistent, manual — non-DKMS)
---------------------------------------
If you don't want DKMS (e.g. a fixed kernel that never updates), install the
module by hand. **This is mutually exclusive with DKMS**: a hand-installed
`.ko` in `.../updates/` collides with DKMS's `.../updates/dkms/` and makes a
later `dkms install` abort, so `make install`'s `modules_install` step aborts
if `dkms status` shows the module is DKMS-managed. Run `sudo make dkms-uninstall`
first if you're switching away from DKMS.

```sh
sudo make install
sudo reboot
```

That target:

1. `modules_install` — copies both `.ko` files into `/lib/modules/$(uname -r)/updates/` (or `extra/` depending on kbuild version) and runs `depmod -a`. Aborts if DKMS manages the module.
2. `dtbo_install` — builds `dts/icm45686-overlay.dts` and copies `icm45686.dtbo` into `/boot/firmware/overlays/` (falls back to `/boot/overlays/`; override with `DTBO_DIR=...`).
3. `config_enable` — appends `dtoverlay=icm45686` to `/boot/firmware/config.txt` (or `/boot/config.txt`; override with `CONFIG_TXT=...`) if not already present.

If your sensor uses address 0x69 (AP_AD0 tied high), pass the override:

```text
dtoverlay=icm45686,addr=0x69
```

### Address conflict warning

If you currently use the **icm20948** overlay on this Pi, both default to I²C address `0x68` on `i2c-1` and will collide. Before reboot:

```sh
sudo sed -i '/^dtoverlay=icm20948/d' /boot/firmware/config.txt   # if icm20948 is no longer wired
# OR strap the ICM-45686 to 0x69 and install with dtoverlay=icm45686,addr=0x69
```

Userspace interface
-------------------

Once bound, the chip presents as a single IIO device under `/sys/bus/iio/devices/iio:deviceN/`. The exact `N` depends on enumeration order — find it by reading the `name` file in each entry; the one that reads `icm45686` is yours. All values follow the standard Linux IIO ABI: `_raw` ADC values converted to physical units via `_scale` (and `_offset` for temperature).

```
/sys/bus/iio/devices/iio:deviceN/
├── name                                  # "icm45686"
├── in_accel_{x,y,z}_raw                  # ADC counts, signed
├── in_accel_scale                  (w)   # m/s² per LSB; select one of in_accel_scale_available
├── in_accel_scale_available              # ±2/4/8/16/32 g (ICM-45686 extended range)
├── in_accel_filter_low_pass_3db_frequency  (w)
├── in_accel_filter_low_pass_3db_frequency_available
├── in_anglvel_{x,y,z}_raw                # ADC counts, signed
├── in_anglvel_scale                (w)   # rad/s per LSB
├── in_anglvel_scale_available            # ±15.625 / 31.25 / 62.5 / 125 / 250 / 500 / 1000 / 2000 / 4000 dps
├── in_anglvel_filter_low_pass_3db_frequency  (w)
├── in_anglvel_filter_low_pass_3db_frequency_available
├── in_temp_raw                           # ADC counts, signed
├── in_temp_scale                         # milli-°C per LSB
├── in_temp_offset                        # additive offset
├── sampling_frequency              (w)   # output data rate
├── sampling_frequency_available
├── scan_elements/                        # buffered-capture channel masks
├── buffer/                               # length, enable
└── trigger/                              # current_trigger
```

| Channel | Unit | Default | Full-scale options |
|---|---|---|---|
| `in_accel_*` | m/s² | ±32 g (driver default) | 2 / 4 / 8 / 16 / **32** g |
| `in_anglvel_*` | rad/s | ±4000 dps (driver default) | 15.625 / 31.25 / 62.5 / 125 / 250 / 500 / 1000 / 2000 / **4000** dps |
| `in_temp` | milli-°C | — | — |

### Mount matrix

Add `mount-matrix = "row1col1","row1col2",...,"row3col3";` to the overlay's `icm45686@68 { ... }` node to expose `/sys/bus/iio/devices/iio:deviceN/in_mount_matrix`, used by userspace to rotate samples from the chip body frame into the board reference frame.

### Buffered streaming via INT1 (required)

Probe **requires** INT1 in device tree (`interrupt-names = "int1"`). The overlay defaults to **BCM GPIO17** (header pin 11) and **`IRQ_TYPE_LEVEL_LOW`** (`interrupts = <17 8>`), which matches the driver's active-low INT1 — the configuration that actually fires on the boards we deploy. Override after install:

```text
dtoverlay=icm45686,int_gpio=27
dtoverlay=icm45686,int_trigger=1
```

Use **`int_trigger=1`** (edge-rising) only for a push-pull active-high INT1. If `int1_verify.sh` shows buffered reads OK but the `/proc/interrupts` count stays at zero, you're on the wrong trigger type — the level-low default is correct for active-low INT1.

Rebuild/reinstall the overlay when changing the DTS default.

The driver exposes separate IIO devices `icm45686-gyro` and `icm45686-accel` (no `trigger/current_trigger` sysfs). FIFO watermark IRQs are handled inside `inv_icm45600`; userspace reads `/dev/iio:deviceN` and the kernel flushes the chip FIFO into the buffer.

Verify INT1 wiring and IRQ activity:

```sh
chmod +x tests/int1_verify.sh
sudo tests/int1_verify.sh
```

The script passes when buffered reads return data. A rising `inv_icm45600` count in `/proc/interrupts` confirms the INT1 watermark path is firing; the overlay default `int_trigger=8` (level-low) is what makes that count rise on active-low INT1 — only switch to an edge type (`int_trigger=1`) if your board has a push-pull active-high INT1. On Pi 5 the DT node lives under `.../rp1/i2c@74000/icm45686@68`, not the legacy `soc/i2c@7e804000` path. Header **pin 11 = BCM GPIO17** (overlay default). Overrides: `int_gpio`, `int_trigger`.

Dev / one-shot (no reboot)
--------------------------
To test against a live chip without touching `config.txt`:

```sh
make
sudo insmod ./inv-icm45600.ko          # core first
sudo insmod ./inv-icm45600-i2c.ko      # then I2C bus stub
echo "icm45686 0x68" | sudo tee /sys/bus/i2c/devices/i2c-1/new_device
# poke around /sys/bus/iio/devices/iio:deviceN/
echo 0x68 | sudo tee /sys/bus/i2c/devices/i2c-1/delete_device
sudo rmmod inv_icm45600_i2c inv_icm45600
```

After `make install`, `modprobe inv-icm45600-i2c` handles the load order via depmod.

Troubleshooting
---------------

**`make` fails with `No such file or directory` on `/lib/modules/.../build`.** Install kernel headers (`sudo apt install linux-headers-$(uname -r)`) or run `sudo make setup-kbuild KSRC=...` against a matching source tree.

**`modprobe inv-icm45600-i2c` reports `Unknown symbol in module` for `inv_icm45686_chip_info`.** `inv-icm45600.ko` (the core) didn't load first. `make modules_install && depmod -a` should fix it; manual loads need core before the i2c stub.

**`i2cdetect -y 1` shows `--` at 0x68.** Chip isn't ACKing. Check the I²C lines have pull-ups (Pi provides ~1.8 kΩ on i2c-1, fine for this chip; the datasheet's 10 kΩ recommendation just means *something*, not necessarily 10 kΩ), VDD/VDDIO are powered, and the right address is strapped via AP_AD0.

**`i2cdetect -y 1` shows `UU` at 0x68.** That's success — `UU` means the kernel owns the address. Verify with `cat /sys/bus/iio/devices/iio:deviceN/name` (should read `icm45686`).

**`dmesg | grep icm45600` shows nothing after boot.** Check the overlay applied: `cat /sys/firmware/devicetree/base/soc/i2c@7e804000/icm45686@68/compatible` should print `invensense,icm45686`. If it doesn't, the overlay didn't load — check `vcgencmd otp_dump | head` warnings or `sudo dmesg | grep -i overlay`.

Uninstall
---------
DKMS install:

```sh
sudo make dkms-uninstall                       # dkms remove --all + rm /usr/src/icm45686-1.0
sudo rm /boot/firmware/overlays/icm45686.dtbo
sudo sed -i '/^dtoverlay=icm45686/d' /boot/firmware/config.txt
sudo reboot
```

Manual (non-DKMS) install:

```sh
sudo rm /boot/firmware/overlays/icm45686.dtbo
sudo sed -i '/^dtoverlay=icm45686/d' /boot/firmware/config.txt
sudo find /lib/modules/$(uname -r) -name 'inv-icm45600*.ko*' -delete
sudo depmod -a
sudo reboot
```

License
-------
GPL-2.0-or-later. The vendored kernel sources retain their original SPDX headers; build glue and the DT overlay are released under the same license. See `COPYING`.
