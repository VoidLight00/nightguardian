.PHONY: install uninstall status start stop test

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

# 회귀 방지: 리밋 메시지 파서 셀프테스트 + 셸 구문검사.
# 새 리밋 메시지 형식이 생기면 src/parse_reset.py 의 _selftest cases 에 추가할 것.
test:
	@echo "→ shell syntax check"
	@bash -n src/guardian-watch.sh && bash -n src/nightguardian && echo "  syntax OK"
	@echo "→ reset-time parser selftest (모든 메시지 형식)"
	@python3 src/parse_reset.py --selftest
	@echo "→ loop-bug regression selftest (self-trigger / dialog 오탐 방지)"
	@bash src/guardian-watch.sh --selftest
