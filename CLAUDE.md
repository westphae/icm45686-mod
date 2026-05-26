# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Out-of-tree Linux IIO driver + Raspberry Pi DT overlay for the InvenSense/TDK **ICM-45686** 6-axis IMU (3-axis accel + 3-axis gyro + temperature) over I²C.

**The driver source is vendored verbatim from mainline Linux** (`drivers/iio/imu/inv_icm45600/`). Do **not** edit `inv_icm45600*.{c,h}` to fix bugs or add features — fix upstream and re-vendor instead. The whole point of this layout is that we track the mainline driver, not fork it. Only the OOT build glue (`Kbuild`, `Makefile`), the DT overlay (`dts/icm45686-overlay.dts`), and the docs are local to this repo.

The pinned upstream commit is recorded in `README.md` under "Vendored from"; bump it (and re-fetch the seven `inv_icm45600*.{c,h}` files) when picking up upstream fixes.

## Build / load / test

```sh
make                  # builds inv-icm45600.ko + inv-icm45600-i2c.ko
make dtbo             # builds dts/icm45686.dtbo
make clean
```

Kernel headers for the running kernel must be installed; the Makefile uses `M=$(CURDIR) modules` against `/lib/modules/$(uname -r)/build`. On rpi-update kernels with no packaged headers, run `sudo make setup-kbuild KSRC=...` to point that symlink at a matching prepared source tree (verbatim port from icm20948-mod, same caveats apply).

Manual load + bind on `i2c-1:0x68`:

```sh
sudo insmod ./inv-icm45600.ko          # core MUST load before the i2c stub
sudo insmod ./inv-icm45600-i2c.ko
# bind via DT (compatible = "invensense,icm45686") or manually:
echo icm45686 0x68 | sudo tee /sys/bus/i2c/devices/i2c-1/new_device
# data appears under /sys/bus/iio/devices/iio:deviceN/
sudo rmmod inv_icm45600_i2c inv_icm45600
```

After `make install`, `modprobe inv-icm45600-i2c` does the load order automatically (depmod sees the inter-module dep through Module.symvers).

## Architecture cheat sheet

**Two .ko files**, mirroring the upstream split:

- `inv-icm45600.ko` — core, FIFO/buffer, accel channels, gyro channels. Exports the `IIO_ICM45600` symbol namespace, with `inv_icm45686_chip_info` (and seven sibling structs) as the main symbols. Imports `IIO_INV_SENSORS_TIMESTAMP` from the in-tree `inv_sensors_timestamp.ko`.
- `inv-icm45600-i2c.ko` — I²C bus stub with `module_i2c_driver`, the `of_device_id` table (which includes `"invensense,icm45686"`), and the `i2c_device_id` table. Imports `IIO_ICM45600`.

If you ever need SPI or I3C support, drop the corresponding `inv_icm45600_spi.c` / `inv_icm45600_i3c.c` into the repo and add a new `obj-m += inv-icm45600-spi.o` line to `Kbuild` — the core .ko already exports everything they need.

**Chip info struct.** Upstream picks the chip variant by matching the DT compatible string (or `i2c_device_id.driver_data`) to one of `inv_icm45605_chip_info` … `inv_icm45689_chip_info`. The struct holds the WHO_AM_I value (`0xE9` for ICM-45686), the scale tables, and the FS enum. The ICM-45686 has the extended `INV_ICM45686_ACCEL_FS_32G` and `INV_ICM45686_GYRO_FS_4000DPS` enums; the smaller ICM-456xx parts use a different scale table.

**Regmap, FIFO, buffered streaming, INT1 trigger** all live in the vendored code and Just Work. No bank-select games like icm20948 has — the chip is regmap-friendly with paged IREG access handled inside the driver.

## DT overlay

`dts/icm45686-overlay.dts` is a standard Pi overlay targeting `&i2c1`. Defaults: `compatible = "invensense,icm45686"`, `reg = <0x68>`. Overrides: `addr=` (e.g. `dtoverlay=icm45686,addr=0x69`).

**INT1 is mandatory, not optional.** The mainline driver calls `fwnode_irq_get_byname(fwnode, "int1")` in probe (`inv_icm45600_core.c`) and aborts with `-EINVAL` ("Missing int1 interrupt") if it's absent — so without a wired-up INT1 the device node binds but the driver never probes (no `UU` in `i2cdetect`, no `iio:deviceN`). The chip's INT1 pin must be wired to a Pi GPIO and described in the overlay by **all three** of `interrupt-parent`, `interrupts`, and `interrupt-names = "int1"`. The name property is required because the driver looks the IRQ up by name, not index. The shipped overlay uses BCM GPIO17 (header pin 11), `interrupts = <17 1>` (`IRQ_TYPE_EDGE_RISING`, matching INT1's default push-pull active-high).

**Address conflict caveat**: this Pi historically ran an `icm20948` at 0x68 on i2c-1 — disable that overlay (or strap one chip to 0x69) before installing this one.

## Coverage map — what the upstream driver supports

| Feature | Upstream driver |
|---|---|
| I²C bus | ✓ |
| SPI bus | ✓ (need to add `inv_icm45600_spi.c` + Kbuild line if used) |
| I3C bus | ✓ (same) |
| Accel/gyro raw + scale + ODR | ✓ |
| Low-pass filter (UI path) | ✓ |
| Hardware FIFO + buffered IIO | ✓ (vendored upstream; see [TODO.md](TODO.md) for INT/kingfisher bring-up) |
| INT1 data-ready trigger | ✓ (**required** — probe fails without an `int1` interrupt in DT; see DT overlay section) |
| WoM / APEX motion functions | ✗ (not in the mainline driver as of the pinned SHA) |
| Self-test | ✗ (not in mainline yet) |
| DMP / EDMP gesture engine | ✗ (firmware blob, not in mainline) |
| Mount matrix | ✓ (DT `mount-matrix`) |

Future scope: when upstream lands self-test, motion, or DMP support, just re-vendor — no local porting work.

## Updating the vendored sources

```sh
SHA=<new-upstream-commit-sha>
for f in inv_icm45600.h inv_icm45600_core.c inv_icm45600_accel.c \
         inv_icm45600_gyro.c inv_icm45600_buffer.c inv_icm45600_buffer.h \
         inv_icm45600_i2c.c Kconfig Makefile; do
    curl -fsSL -o "$f" \
      "https://raw.githubusercontent.com/torvalds/linux/$SHA/drivers/iio/imu/inv_icm45600/$f"
done
mv Kconfig Kconfig.upstream
mv Makefile Makefile.upstream
make clean && make    # smoke-test that it still builds
```

Then update the "Vendored from" line in `README.md` with the new SHA + date. If kbuild has added a new IIO API the driver depends on and we're behind, either bump the Pi's running kernel or vendor from the matching `linux-6.<N>.y` stable branch instead of `master`.
