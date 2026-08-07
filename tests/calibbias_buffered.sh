#!/usr/bin/env bash
# Verify calibbias/OFFUSER can be programmed while IIO buffers are enabled.
set -euo pipefail

gyro=""
accel=""
for d in /sys/bus/iio/devices/iio:device*; do
  name=$(cat "$d/name")
  case "$name" in
    icm45686-gyro) gyro=$d ;;
    icm45686-accel) accel=$d ;;
  esac
done

if [[ -z "$gyro" || -z "$accel" ]]; then
  echo "FAIL: icm45686 devices not found" >&2
  exit 1
fi

if [[ "$(cat "$gyro/buffer/enable")" != "1" || "$(cat "$accel/buffer/enable")" != "1" ]]; then
  echo "FAIL: both buffers must be enabled (start kingfisher or enable manually)" >&2
  exit 1
fi

write_axis() {
  local dev=$1 axis=$2 val=$3
  echo "$val" > "$dev/in_anglvel_${axis}_calibbias"
  local got
  got=$(cat "$dev/in_anglvel_${axis}_calibbias")
  echo "  anglvel_$axis wrote=$val read=$got"
}

echo "Writing gyro calibbias with buffer/enable=1 ..."
write_axis "$gyro" x "-0.008787005"
write_axis "$gyro" y "0.006400623"
write_axis "$gyro" z "-0.001358898"

echo "Rewriting sampling_frequency (ODR path) ..."
freq=$(cat "$gyro/sampling_frequency")
echo "$freq" > "$gyro/sampling_frequency"
sleep 0.2

echo "OFFUSER after ODR rewrite:"
for axis in x y z; do
  echo "  $axis=$(cat "$gyro/in_anglvel_${axis}_calibbias")"
done

echo "PASS"
