KDIR      ?= /lib/modules/$(shell uname -r)/build
DTBO_DIR  ?= $(firstword $(wildcard /boot/firmware/overlays /boot/overlays))
CONFIG_TXT ?= $(firstword $(wildcard /boot/firmware/config.txt /boot/config.txt))
DTC       ?= dtc

# DKMS packaging: keep the module alive across kernel upgrades (AUTOINSTALL=yes
# in dkms.conf). PACKAGE_VERSION here must match dkms.conf.
DKMS_PACKAGE ?= icm45686
DKMS_VERSION ?= 1.0
DKMS_SRC     ?= /usr/src/$(DKMS_PACKAGE)-$(DKMS_VERSION)
# Target kernel for dkms-install (default: currently running).
KERNELRELEASE ?= $(shell uname -r)
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
# Copy sources into /usr/src (stable across repo moves; not a symlink) and
# register with DKMS if needed. Needs root + matching headers
# (linux-headers-rpi-2712 on Pi 5).
#
# dkms-install: safe default — sync sources, rebuild/install for KERNELRELEASE
#   only. Does NOT wipe builds for other installed kernels (important after
#   apt upgrades a new kernel that AUTOINSTALL already built, while you are
#   still running the old one).
#
# dkms-reinstall-all: nuclear — remove every kernel build, re-add from scratch,
#   install for KERNELRELEASE, then `dkms autoinstall` for any other kernels
#   that have headers. Use when sources/layout are badly wedged.
dkms-sync-src:
	install -d $(DKMS_SRC)
	cp -a $(DKMS_FILES) $(DKMS_SRC)/
	@if ! dkms status $(DKMS_PACKAGE)/$(DKMS_VERSION) 2>/dev/null | grep -q .; then \
		dkms add $(DKMS_PACKAGE)/$(DKMS_VERSION); \
	fi

dkms-install: dkms-sync-src
	dkms build $(DKMS_PACKAGE)/$(DKMS_VERSION) -k $(KERNELRELEASE) --force
	dkms install $(DKMS_PACKAGE)/$(DKMS_VERSION) -k $(KERNELRELEASE) --force

dkms-reinstall-all:
	-dkms remove $(DKMS_PACKAGE)/$(DKMS_VERSION) --all
	rm -rf $(DKMS_SRC)
	install -d $(DKMS_SRC)
	cp -a $(DKMS_FILES) $(DKMS_SRC)/
	dkms add $(DKMS_PACKAGE)/$(DKMS_VERSION)
	dkms build $(DKMS_PACKAGE)/$(DKMS_VERSION) -k $(KERNELRELEASE)
	dkms install $(DKMS_PACKAGE)/$(DKMS_VERSION) -k $(KERNELRELEASE)
	-dkms autoinstall

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
        overlay-install dkms-sync-src dkms-install dkms-reinstall-all \
        dkms-uninstall setup-kbuild
