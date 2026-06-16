.PHONY: install uninstall status start stop

PROJECT_DIR := $(shell pwd)
RUNTIME_DIR := $(HOME)/.forgechain-nightguardian

install:
	@echo "Installing NightGuardian..."
	@mkdir -p $(RUNTIME_DIR)/{manifest,logs}
	@ln -sf $(PROJECT_DIR)/src $(RUNTIME_DIR)/bin
	@ln -sf $(PROJECT_DIR)/config $(RUNTIME_DIR)/config
	@mkdir -p $(HOME)/.local/bin
	@ln -sf $(PROJECT_DIR)/src/nightguardian $(HOME)/.local/bin/nightguardian 2>/dev/null || true
	@echo "Done. Run 'nightguardian start' to launch."

uninstall:
	@echo "Uninstalling NightGuardian..."
	@nightguardian stop 2>/dev/null || true
	@rm -rf $(RUNTIME_DIR)/bin $(RUNTIME_DIR)/config
	@rm -f $(HOME)/.local/bin/nightguardian
	@echo "Done."

status:
	@nightguardian status

start:
	@nightguardian start

stop:
	@nightguardian stop
