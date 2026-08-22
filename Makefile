PRODUCT := metaphor
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
SHAREDIR ?= $(PREFIX)/share/metaphor
BUILD_CONFIG ?= release
INSTALL_BIN := $(BINDIR)/$(PRODUCT)

.PHONY: setup build release test install uninstall clean doctor hooks contract

# 初回セットアップ。クローン直後にこれを打つ。
# metaphor 側の `make setup` と同じ入口（あちらはサブモジュール初期化も含む）。
# このリポジトリは `swift build` だけで動くぶん setup を打つ動機が弱く、
# pre-push フックが入らないまま契約チェックが CI 任せになっていた。
setup: hooks
	@echo "Setup complete. Run 'make build' to build."

build:
	swift build

# Install git hooks (pre-push cross-repo contract check).
# パスは相対のままにする — core.hooksPath の相対パスは各作業ツリーのトップレベル
# 基準で解決されるので、worktree でもその worktree のスクリプトが走る。
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
	# 旧版（frame IPC 以前のビューア）が同梱していた Syphon.framework の残骸を消す。
	rm -rf "$(SHAREDIR)/Frameworks/Syphon.framework"
	@echo "Installed $(PRODUCT) to $(INSTALL_BIN)"
	@echo "Installed templates to $(SHAREDIR)/templates"
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
	rm -rf "$(SHAREDIR)/Frameworks/Syphon.framework"
	@echo "Removed $(INSTALL_BIN)"
	@echo "Removed $(SHAREDIR)/templates"

doctor:
	swift run $(PRODUCT) doctor

clean:
	swift package clean
