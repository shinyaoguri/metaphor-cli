PRODUCT := metaphor
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
BUILD_CONFIG ?= release
INSTALL_BIN := $(BINDIR)/$(PRODUCT)

.PHONY: build release test install uninstall clean doctor

build:
	swift build

release:
	swift build -c release

test:
	swift test

install: release
	mkdir -p "$(BINDIR)"
	install -m 755 ".build/$(BUILD_CONFIG)/$(PRODUCT)" "$(INSTALL_BIN)"
	@echo "Installed $(PRODUCT) to $(INSTALL_BIN)"
	@if echo ":$$PATH:" | grep -q ":$(BINDIR):"; then \
		echo "You can now run: $(PRODUCT) --help"; \
	else \
		echo ""; \
		echo "$(BINDIR) is not currently on PATH."; \
		echo "Add this to your shell profile:"; \
		echo "  export PATH=\"$(BINDIR):\$$PATH\""; \
	fi

uninstall:
	rm -f "$(INSTALL_BIN)"
	@echo "Removed $(INSTALL_BIN)"

doctor:
	swift run $(PRODUCT) doctor

clean:
	swift package clean
