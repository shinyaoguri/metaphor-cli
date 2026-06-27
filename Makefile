PRODUCT := metaphor
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
SHAREDIR ?= $(PREFIX)/share/metaphor
BUILD_CONFIG ?= release
INSTALL_BIN := $(BINDIR)/$(PRODUCT)
FRAMEWORKDIR := $(SHAREDIR)/Frameworks
BUILT_FRAMEWORK := .build/$(BUILD_CONFIG)/Syphon.framework

.PHONY: build release test install uninstall clean doctor hooks contract

build:
	swift build

# Install git hooks (pre-push cross-repo contract check)
hooks:
	@echo "Installing git hooks (core.hooksPath=scripts/hooks)..."
	@git config core.hooksPath scripts/hooks

# Run the cross-repo contract checks (token presence + CONTRACT.md identity)
contract:
	@./scripts/check-contract.sh
	@./scripts/check-contract-identity.sh

release:
	swift build -c release

test:
	swift test

install: release
	mkdir -p "$(BINDIR)"
	install -m 755 ".build/$(BUILD_CONFIG)/$(PRODUCT)" "$(INSTALL_BIN)"
	rm -rf "$(SHAREDIR)/templates"
	mkdir -p "$(SHAREDIR)"
	cp -R "Templates" "$(SHAREDIR)/templates"
	# Syphon.framework を同梱し rpath を通す（`watch --viewer` のライブビューアに必要）。
	# バイナリの install name は @rpath/Syphon.framework/... なので、同梱先を
	# 絶対パスの rpath に追加する。install_name_tool で署名が無効になるため再署名する。
	rm -rf "$(FRAMEWORKDIR)/Syphon.framework"
	mkdir -p "$(FRAMEWORKDIR)"
	cp -R "$(BUILT_FRAMEWORK)" "$(FRAMEWORKDIR)/Syphon.framework"
	install_name_tool -add_rpath "$(FRAMEWORKDIR)" "$(INSTALL_BIN)" 2>/dev/null || true
	codesign --force --sign - "$(INSTALL_BIN)"
	@echo "Installed $(PRODUCT) to $(INSTALL_BIN)"
	@echo "Installed templates to $(SHAREDIR)/templates"
	@echo "Installed Syphon.framework to $(FRAMEWORKDIR)"
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
	rm -rf "$(SHAREDIR)/templates"
	rm -rf "$(FRAMEWORKDIR)/Syphon.framework"
	@echo "Removed $(INSTALL_BIN)"
	@echo "Removed $(SHAREDIR)/templates"
	@echo "Removed $(FRAMEWORKDIR)/Syphon.framework"

doctor:
	swift run $(PRODUCT) doctor

clean:
	swift package clean
