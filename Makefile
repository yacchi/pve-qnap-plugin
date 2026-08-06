VERSION ?= 0.2.0
PERLDIR ?= /usr/share/perl5
DESTDIR ?=

PACKAGE = pve-qnap-plugin
DEB     = $(PACKAGE)_$(VERSION)_all.deb
BUILD   = build

MODULES = \
	PVE/Storage/Custom/QnapPlugin.pm \
	PVE/Storage/Custom/Qnap/API.pm

.PHONY: all check install uninstall reload deb clean

all: check

# Syntax check. Skipped where libpve-storage-perl is absent (e.g. CI runners).
check:
	@if perl -MPVE::Storage::Plugin -e1 2>/dev/null; then \
		for m in $(MODULES); do perl -I. -c $$m || exit 1; done; \
	else \
		echo "libpve-storage-perl not installed, skipping syntax check"; \
	fi

install:
	install -d $(DESTDIR)$(PERLDIR)/PVE/Storage/Custom/Qnap
	install -m 0644 PVE/Storage/Custom/QnapPlugin.pm $(DESTDIR)$(PERLDIR)/PVE/Storage/Custom/
	install -m 0644 PVE/Storage/Custom/Qnap/API.pm   $(DESTDIR)$(PERLDIR)/PVE/Storage/Custom/Qnap/
	install -d $(DESTDIR)/usr/share/doc/$(PACKAGE)
	install -m 0644 README.md docs/qnap-api.md $(DESTDIR)/usr/share/doc/$(PACKAGE)/

uninstall:
	rm -f  $(DESTDIR)$(PERLDIR)/PVE/Storage/Custom/QnapPlugin.pm
	rm -rf $(DESTDIR)$(PERLDIR)/PVE/Storage/Custom/Qnap
	rm -rf $(DESTDIR)/usr/share/doc/$(PACKAGE)

# Only needed after 'make install'. The package does this from its postinst.
reload:
	systemctl try-restart pvedaemon pveproxy pvestatd

# Build a .deb with no build dependencies beyond dpkg-deb, so this runs
# unchanged on a Proxmox VE node.
deb: check
	rm -rf $(BUILD)
	$(MAKE) install DESTDIR=$(BUILD)
	install -d $(BUILD)/DEBIAN
	sed 's/@VERSION@/$(VERSION)/' packaging/control.in > $(BUILD)/DEBIAN/control
	install -m 0755 packaging/postinst packaging/postrm $(BUILD)/DEBIAN/
	dpkg-deb --root-owner-group --build $(BUILD) $(DEB)
	@echo
	@echo "built $(DEB)"

clean:
	rm -rf $(BUILD) $(PACKAGE)_*_all.deb
