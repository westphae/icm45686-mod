#!/usr/bin/env bash
# Verify ICM-45686 DT + INT1 + buffered capture on the Pi.
# Pin 11 (header) = BCM GPIO17, matching the default overlay.
set -euo pipefail

cleanup() {
	local dev
	for dev in "${GYRO_DEV:-}" "${ACCEL_DEV:-}"; do
		[[ -n "$dev" ]] || continue
		echo 0 >"$dev/buffer/enable" 2>/dev/null || true
	done
}
trap cleanup EXIT

# Read INV register via debugfs (hex address without 0x prefix).
read_inv_reg() {
	local dev=$1 reg=$2
	local d=/sys/kernel/debug/iio/$(basename "$dev")
	[[ -d "$d" ]] || return 1
	printf '0x%x' "$reg" >"$d/direct_reg_access" 2>/dev/null || return 1
	cat "$d/direct_reg_access" 2>/dev/null
}

check_dev_free() {
	local path=$1
	if fuser -s "$path" 2>/dev/null; then
		echo "FAIL: $path is busy — another process holds the device:"
		fuser -v "$path" 2>&1 || true
		echo "Stop it (e.g. kill <pid>). Stuck 'dd' often remains after a cancelled buffer test."
		exit 1
	fi
}

irq_total() {
	awk '/inv_icm45600/{s=0; for(i=2;i<=5;i++) s+=$i; print s+0; exit}' /proc/interrupts
}

irq_line() {
	grep -E 'inv_icm45600|inv-icm45600' /proc/interrupts || true
}

find_dev() {
	local want=$1
	for d in /sys/bus/iio/devices/iio:device*; do
		[[ -f "$d/name" ]] || continue
		if [[ "$(cat "$d/name")" == "$want" ]]; then
			echo "$d"
			return 0
		fi
	done
	return 1
}

find_dt_node() {
	local d
	if [[ -d /sys/firmware/devicetree/base/axi/pcie@1000120000/rp1/i2c@74000/icm45686@68 ]]; then
		echo /sys/firmware/devicetree/base/axi/pcie@1000120000/rp1/i2c@74000/icm45686@68
		return 0
	fi
	while IFS= read -r -d '' d; do
		echo "$d"
		return 0
	done < <(find /sys/firmware/devicetree/base -name 'icm45686@68' -type d -print0 2>/dev/null)
	return 1
}

dt_gpio_from_interrupts() {
	local node=$1 f
	f="$node/interrupts"
	[[ -f "$f" ]] || return 1
	python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(8); print(struct.unpack(">II",d)[0])' "$f"
}

enable_scan() {
	local dev=$1 prefix=$2
	local ch
	for ch in x y z; do
		echo 1 >"$dev/scan_elements/in_${prefix}_${ch}_en" 2>/dev/null || true
	done
	echo 1 >"$dev/scan_elements/in_temp_en" 2>/dev/null || true
}

echo "== Device tree =="
if node=$(find_dt_node); then
	echo "Node: $node"
	echo -n "compatible: "; tr '\0' ' ' <"$node/compatible"; echo
	if gpio=$(dt_gpio_from_interrupts "$node"); then
		echo "INT1 GPIO (DT first cell): $gpio (expect 17 for header pin 11)"
		if [[ "$gpio" != "17" ]]; then
			echo "WARN: DT GPIO is not 17 — check overlay int_gpio= or wiring"
		fi
	else
		echo "WARN: could not read interrupts property"
	fi
else
	echo "WARN: icm45686@68 node not found under /sys/firmware/devicetree"
	echo "      (driver may still be bound via overlay — check: ls /sys/bus/iio/devices/)"
fi

GYRO="$(find_dev icm45686-gyro)" || {
	echo "FAIL: no icm45686-gyro IIO device"
	exit 1
}
ACCEL="$(find_dev icm45686-accel)" || {
	echo "FAIL: no icm45686-accel IIO device"
	exit 1
}
GYRO_DEV=$GYRO
ACCEL_DEV=$ACCEL
echo "Gyro:  $GYRO"
echo "Accel: $ACCEL"

check_dev_free "/dev/$(basename "$GYRO")"
check_dev_free "/dev/$(basename "$ACCEL")"

echo
echo "== IRQ line (before test) =="
irq_line
irq_before=$(irq_total)
echo "Total inv_icm45600 count: $irq_before"

# Phase A: both halves on (shared FIFO) — wait for INT1 watermark IRQ without reading.
enable_scan "$GYRO" anglvel
enable_scan "$ACCEL" accel
for dev in "$GYRO" "$ACCEL"; do
	echo 100 >"$dev/sampling_frequency"
	echo 1 >"$dev/buffer/watermark" 2>/dev/null || true
	echo 16 >"$dev/buffer/length"
done
echo 1 >"$ACCEL/buffer/enable"
echo 1 >"$GYRO/buffer/enable"

echo
echo "== Waiting 3s for FIFO watermark IRQ (no userspace read) =="
sleep 3
irq_mid=$(irq_total)
echo "IRQ count after wait: $irq_mid (delta $((irq_mid - irq_before)))"
int_status=""
if int_status=$(read_inv_reg "$GYRO" 25 2>/dev/null); then
	# 0x19 INT_STATUS: bit1 FIFO_THS, bit0 FIFO_FULL
	echo "Chip INT_STATUS (0x19): $int_status"
fi

echo 0 >"$ACCEL/buffer/enable" 2>/dev/null || true
echo 0 >"$GYRO/buffer/enable" 2>/dev/null || true
sleep 0.2

# Phase B: gyro-only buffered read (one IIO device, typical userspace client).
enable_scan "$GYRO" anglvel
echo 100 >"$GYRO/sampling_frequency"
echo 8 >"$GYRO/buffer/length"
echo 1 >"$GYRO/buffer/enable"
sleep 0.3
tmp=$(mktemp)
bytes=0
if timeout 2 dd if="/dev/$(basename "$GYRO")" of="$tmp" bs=64 count=8 status=none 2>/dev/null; then
	bytes=$(wc -c <"$tmp" | tr -d ' ')
fi
rm -f "$tmp"
echo 0 >"$GYRO/buffer/enable" 2>/dev/null || true

echo
echo "== IRQ line (after test) =="
irq_line
irq_after=$(irq_total)
echo "Total inv_icm45600 count: $irq_after (delta since start: $((irq_after - irq_before)))"

ok_data=0
ok_irq=0
[[ "$bytes" -ge 32 ]] && ok_data=1
[[ "$irq_after" -gt "$irq_before" ]] && ok_irq=1

if [[ "$ok_data" -eq 1 ]]; then
	echo "OK: read $bytes bytes from gyro IIO buffer"
else
	echo "FAIL: no buffer data ($bytes bytes)"
	if fuser -s "/dev/$(basename "$GYRO")" 2>/dev/null; then
		echo "      /dev/$(basename "$GYRO") is busy:"
		fuser -v "/dev/$(basename "$GYRO")" 2>&1 | sed 's/^/      /' || true
	fi
fi

if [[ "$ok_irq" -eq 1 ]]; then
	echo "OK: INT1 IRQ fired (hardware FIFO watermark path alive)"
else
	echo "NOTE: IRQ count did not increase (GPIO17 never saw an edge)."
	echo "      Buffered reads OK => probe + DT + hwfifo flush-on-read are working."
	if [[ -n "$int_status" && "$int_status" != "0x0" && "$int_status" != "0" ]]; then
		echo "      INT_STATUS=$int_status => chip FIFO IRQ flags are set, but INT1 is not"
		echo "      toggling GPIO17 (check chip INT1 pad vs INT2, scope pin 11, open-drain pull-up)."
	else
		echo "      INT_STATUS idle => FIFO watermark may not be armed; less common if reads work."
	fi
	echo "      For active-low INT1, use dtoverlay=icm45686,int_trigger=8 (level-low), not edge types."
	echo "      Open-drain INT: add drive-open-drain to the overlay node + pull-up on GPIO17."
fi

if [[ "$ok_data" -eq 1 ]]; then
	exit 0
fi
exit 1
