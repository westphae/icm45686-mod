# TODO

## Hardware FIFO (ICM-45686) — integration, not driver core

The vendored mainline driver (`inv_icm45600_buffer.c`, etc.) **already implements**
hardware FIFO streaming, watermark IRQs, and `iio_triggered_buffer`. Do **not** add a
parallel FIFO path in this repo — fix upstream and re-vendor per `CLAUDE.md`.

Remaining work here is **bring-up and consumers**, not reimplementing FIFO in C.

**Goal:** Use chip FIFO + INT1 in production (cabin IMU on the Pi) instead of relying
only on `iio-trig-hrtimer`, and align kingfisher buffered capture with ODR/FIFO pacing.

**Rough plan:**

1. **Device tree** — Wire INT1 on the wing/cabin PCB; uncomment `interrupt-parent` /
   `interrupts` in `dts/icm45686-overlay.dts`. Verify `icm45686-devN` trigger appears and
   auto-binds (see `README.md` § Buffered streaming via INT1).
2. **Regression test** — Add `tests/fifo_stream.sh` (FIFO + INT trigger, or FIFO +
   hrtimer fallback): frame count, timestamp cadence, per-axis spread (mirror
   `icm20948-mod/tests/buffered_stream.sh`).
3. **`sampling_frequency`** — Document how device-level ODR relates to FIFO watermark
   and max sustainable rate; kingfisher should read `sampling_frequency_available` for
   `MaxBufferedHz` when this chip replaces or supplements `icm20948`.
4. **Kingfisher** — See `../kingfisher/CLAUDE.md` (driver TODOs): prefer INT/FIFO
   trigger over `kingfisher-*` hrtimer when `name` is `icm45686`; optional
   `use_buffer` + chip trigger name detection.

**Upstream FIFO changes** (watermark sizing, new packet formats, bugs): patch in
`torvalds/linux` `drivers/iio/imu/inv_icm45600/`, then bump the vendored SHA in
`README.md`.

## Local: calibbias / OFFUSER while buffered

Mainline `write_raw` for `IIO_CHAN_INFO_CALIBBIAS` uses `iio_device_claim_direct`,
so sysfs returns `-EBUSY` whenever the IIO buffer is enabled. That forced
userspace (kingfisher) to pause both cabin FIFOs around every OFFUSER program.

**Local change** (keep when re-vendoring):

1. Drop `claim_direct` for CALIBBIAS writes (scale still requires it).
2. While `st->fifo.on`, briefly clear chip FIFO sensor enables around the IREG
   write — userspace `/dev/iio` buffers stay open.
3. Shadow `gyro_offuser[3]` / `accel_offuser[3]` and restamp after
   `set_gyro_conf` / `set_accel_conf` so ODR/FS power transitions cannot leave
   OFFUSER at zero.

Test: `tests/calibbias_buffered.sh` (buffers enabled → write → readback → ODR
rewrite → OFFUSER still present).

Upstream these when proposing a patch to `inv_icm45600`.
