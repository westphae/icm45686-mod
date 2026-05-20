# SPDX-License-Identifier: GPL-2.0-or-later
#
# Out-of-tree kbuild for the ICM-456xx (incl. ICM-45686) IIO driver.
#
# Upstream (drivers/iio/imu/inv_icm45600) builds two modules: inv-icm45600.ko
# (core + buffer + accel + gyro, exporting the IIO_ICM45600 symbol namespace)
# and inv-icm45600-i2c.ko (the I2C bus stub, importing that namespace). We
# mirror that split here so each module has exactly one MODULE_LICENSE /
# module_i2c_driver, and Module.symvers wires them together — same as upstream.
#
# depmod handles the load order: modprobe inv-icm45600-i2c pulls in
# inv-icm45600 and the in-tree inv-sensors-timestamp dependency.

obj-m += inv-icm45600.o
inv-icm45600-y := \
    inv_icm45600_core.o \
    inv_icm45600_buffer.o \
    inv_icm45600_gyro.o \
    inv_icm45600_accel.o

obj-m += inv-icm45600-i2c.o
inv-icm45600-i2c-y := inv_icm45600_i2c.o
