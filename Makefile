KDIR      ?= /lib/modules/$(shell uname -r)/build
DTBO_DIR  ?= $(firstword $(wildcard /boot/firmware/overlays /boot/overlays))
CONFIG_TXT ?= $(firstword $(wildcard /boot/firmware/config.txt /boot/config.txt))
DTC       ?= dtc

# DKMS packaging: keep the module alive across kernel upgrades (AUTOINSTALL=yes
# in dkms.conf). PACKAGE_VERSION here must match dkms.conf.
DKMS_PACKAGE ?= icm45686
DKMS_VERSION ?= 1.0
DKMS_SRC     ?= /usr/src/$(DKMS_PACKAGE)-$(DKMS_VERSION)
# Files DKMS needs to build the module (driver sources + kbuild glue + config).
DKMS_FILES    = dkms.conf Kbuild $(wildcard inv_icm45600*.c inv_icm45600*.h)

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

dtbo: dts/icm45686.dtbo

dts/icm45686.dtbo: dts/icm45686-overlay.dts
	$(DTC) -@ -I dts -O dtb -o $@ $<

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
	rm -f dts/*.dtbo

modules_install:
	@if dkms status $(DKMS_PACKAGE) 2>/dev/null | grep -q ': installed'; then \
		echo "ERROR: $(DKMS_PACKAGE) is managed by DKMS (see 'dkms status')."; \
		echo "A plain module install into updates/ collides with DKMS's updates/dkms/"; \
		echo "and will make a later 'dkms install' abort."; \
		echo "Use 'make dkms-install' instead, or run 'make dkms-uninstall' first."; \
		exit 1; \
	fi
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules_install
	depmod -a

dtbo_install: dts/icm45686.dtbo
	@test -n "$(DTBO_DIR)" || { echo "DTBO_DIR not set and neither /boot/firmware/overlays nor /boot/overlays exists; pass DTBO_DIR=..."; exit 1; }
	install -d $(DTBO_DIR)
	install -m 0644 dts/icm45686.dtbo $(DTBO_DIR)/

config_enable:
	@test -n "$(CONFIG_TXT)" || { echo "CONFIG_TXT not set and no Pi config.txt found; pass CONFIG_TXT=..."; exit 1; }
	@if grep -q '^dtoverlay=icm45686' $(CONFIG_TXT); then \
		echo "$(CONFIG_TXT) already enables dtoverlay=icm45686"; \
	else \
		echo 'dtoverlay=icm45686' >> $(CONFIG_TXT); \
		echo "appended dtoverlay=icm45686 to $(CONFIG_TXT) -- reboot to activate"; \
	fi

# Overlay-only install: everything DKMS does NOT manage. Use this after
# 'make dkms-install' -- DKMS handles the .ko, this handles the .dtbo + config.txt.
overlay-install: dtbo_install config_enable

# Manual (non-DKMS) persistent install. Mutually exclusive with DKMS:
# modules_install aborts if DKMS already manages the module.
install: modules_install dtbo_install config_enable

# --- DKMS ----------------------------------------------------------------
# Copy the sources into /usr/src (a stable location that survives repo moves,
# unlike a symlink into the working tree) and register + build + install with
# DKMS. Re-run after any driver-source change to re-copy and rebuild. Needs
# root and matching kernel headers (linux-headers-rpi-2712 on Pi 5).
# The leading remove makes this idempotent: DKMS refuses to 'add' a
# version it already tracks, so an existing registration (from a prior run or
# the old symlink layout) must be cleared first. '-' ignores its failure on a
# first-ever install when nothing is registered yet.
dkms-install:
	-dkms remove $(DKMS_PACKAGE)/$(DKMS_VERSION) --all
	rm -rf $(DKMS_SRC)
	install -d $(DKMS_SRC)
	cp -a $(DKMS_FILES) $(DKMS_SRC)/
	dkms add $(DKMS_PACKAGE)/$(DKMS_VERSION)
	dkms build $(DKMS_PACKAGE)/$(DKMS_VERSION)
	dkms install $(DKMS_PACKAGE)/$(DKMS_VERSION)

dkms-uninstall:
	-dkms remove $(DKMS_PACKAGE)/$(DKMS_VERSION) --all
	rm -rf $(DKMS_SRC)

# Create the /lib/modules/$(uname -r)/build symlink that kbuild needs for
# out-of-tree module builds. Use this when the running kernel has no
# distro-packaged headers (e.g. rpi-update kernels) and you have a matching
# kernel source tree elsewhere. KSRC must point at a tree that:
#   - matches the running kernel exactly (UTS_RELEASE == $(uname -r))
#   - has had `make modules_prepare` run in it
#   - has Module.symvers (i.e. a prior `make modules` completed there)
# Needs root because /lib/modules/... is not user-writable.
setup-kbuild:
	@set -e; \
	LINK=/lib/modules/`uname -r`/build; \
	if [ -e "$$LINK" ]; then \
		echo "$$LINK already exists; nothing to do."; \
		exit 0; \
	fi; \
	if [ -z "$(KSRC)" ]; then \
		echo "Usage: sudo make setup-kbuild KSRC=/path/to/matching/kernel/source"; \
		echo ""; \
		echo "Prepare the source tree first if you haven't:"; \
		echo "  cd \$$KSRC && make modules_prepare && make -j\$$(nproc) modules"; \
		exit 1; \
	fi; \
	test -d "$(KSRC)" || { echo "KSRC=$(KSRC): not a directory"; exit 1; }; \
	test -f "$(KSRC)/Module.symvers" || { \
		echo "$(KSRC)/Module.symvers missing; run there:"; \
		echo "  make modules_prepare && make -j\$$(nproc) modules"; \
		exit 1; }; \
	KREL=`sed -n 's/.*UTS_RELEASE "\(.*\)".*/\1/p' "$(KSRC)/include/generated/utsrelease.h" 2>/dev/null`; \
	RUN=`uname -r`; \
	if [ "$$KREL" != "$$RUN" ]; then \
		echo "version mismatch: KSRC builds [$$KREL], running [$$RUN]"; \
		exit 1; \
	fi; \
	ln -sT "$(KSRC)" "$$LINK"; \
	echo "linked $$LINK -> $(KSRC)"

.PHONY: all dtbo clean modules_install dtbo_install config_enable install \
        overlay-install dkms-install dkms-uninstall setup-kbuild
