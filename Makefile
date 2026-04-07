# Makefile — Tenacious Infra v2
# Usage:  make help

# Use bash for portability (recipes use bash syntax like [[ ]]), but prevent
# sourcing of ~/.bash_profile / ~/.bashrc which pollute output with
# copilot/stty/docker errors in non-interactive contexts (e.g. Jupyter).
SHELL     := bash
.SHELLFLAGS := --norc --noprofile -c

# Variables
# UV path - try common locations (uv installs to ~/.local/bin by default)
UV_PATH := $(shell command -v uv 2>/dev/null || echo $(HOME)/.local/bin/uv)
UV = $(UV_PATH)

VENV = .venv
VENV_BIN = $(VENV)/bin
PYTHON    := $(VENV)/bin/python3
PIP = $(VENV)/bin/pip3
PYTEST = $(VENV)/bin/pytest
COVERAGE = $(VENV)/bin/coverage

# BASE_DIR: read from defaults.yaml repos.base_dir, .env overrides, fallback ~/tenai-projects
BASE_DIR  ?= $(shell $(PYTHON) -c "import sys; sys.path.insert(0,'.'); from scripts.lib.load_config import load_config; c=load_config(); print(c.get('repos',{}).get('base_dir','~/tenai-projects'))" 2>/dev/null || echo $(HOME)/tenai-projects)

# INFRA_REPO: the directory name of this repo on remote devices (~/<INFRA_REPO>).
# Defaults to 'tenai' (the new repo name). Override via env or config/local.yaml.
INFRA_REPO ?= $(shell $(PYTHON) -c "import sys; sys.path.insert(0,'.'); from scripts.lib.load_config import load_config; c=load_config(); print(c.get('repos',{}).get('infra_dir','tenai'))" 2>/dev/null || echo tenai)


PYTHON_VERSION = python3.12
SCRIPTS_DIR = scripts
PYTHONPATH = $(PWD)/src:$(PWD)

# Colors for pretty output
GREEN = \033[0;32m
YELLOW = \033[1;33m
BLUE = \033[0;34m
PINK = \033[0;35m
RED = \033[0;31m
NC = \033[0m

# Bootstrap guard: installs uv if absent, creates .venv, installs all deps.
# MUST be called as a standalone recipe line — never inside a shell if/else block.
# The sentinel .venv/.deps-installed makes repeated calls instant.
define ensure_venv
	@set -e; \
	if [ ! -x "$(HOME)/.local/bin/uv" ] && ! command -v uv >/dev/null 2>&1; then \
	  echo "Installing uv..."; \
	  curl -LsSf https://astral.sh/uv/install.sh | sh; \
	fi; \
	if [ -x "$(HOME)/.local/bin/uv" ]; then \
	  _UV="$(HOME)/.local/bin/uv"; \
	else \
	  _UV="$$(command -v uv)"; \
	fi; \
	if [ ! -d "$(VENV)" ]; then \
	  echo "Creating .venv..."; \
	  "$$_UV" venv $(VENV) --python $(PYTHON_VERSION); \
	fi; \
	if [ ! -f "$(VENV)/.deps-installed" ]; then \
	  echo "Installing Python deps..."; \
	  "$$_UV" pip install -p $(VENV) \
	    hydra-core omegaconf python-dotenv pyyaml \
	    fastapi uvicorn pydantic \
	    pytest httpx ruff; \
	  touch "$(VENV)/.deps-installed"; \
	fi
endef

.PHONY: install configure aliases ssh tmux tailscale tools gemini vt-server \
        cli-setup cli-extensions cli-mcp cli-plugins cli-skills cli-vercel-skills cli-settings cli-rules cli-list cli-install \
        tmux-list tmux-clean tmux-kill-all \
        onboard new-server sync sync-all sync-envs push-aliases distribute-keys new-project list-tools check-tools \
        conductor conductor-all conductor-list \
        parse-tasks validate-tasks dispatch-tasks \
        clone pull pull-all repos repo-status \
        worktree dispatch tmux-worktree clean-worktrees clean-artifacts \
        validate-worktrees check-conflicts integration-test merge-sequential \
        lint test validate ci-workflow ci-daemon ci-history monitor-agents github-issues install-symphony install-gastown agent-history poll-reviews \
        agent-watcher agent-watcher-check agent-watcher-status \
        orchestrate orchestrate-webhook \
        task-add task-list task-query task-register task-import task-import-track task-sync task-delete tasks \
        webapp webapp-install webapp-docker webapp-docker-stop webapp-docker-build webapp-docker-logs \
        proxy proxy-start proxy-stop proxy-status proxy-daemon set-exit-node \
        install-multipass install-tart test-sandbox \
        check status clean help

-include .env
export

# ══════════════════════════════════════════════════════════════════════════════
# DEFAULT — show help when running `make` with no arguments
# ══════════════════════════════════════════════════════════════════════════════
.DEFAULT_GOAL := help


## Full device setup:  make setup
##   Runs install (venv + dependencies) then configure (SSH, aliases, CLI, proxy, dirs).
##   Safe to re-run — all steps are idempotent.
setup: install configure
	@echo ""
	@echo "✓ Tenacious infra setup complete"
	@echo "Run: source ~/.bashrc  (or source ~/.zshrc on Mac)"
	@echo ""
	@echo "Next: make repos    — list all managed repositories"
	@echo "      make webapp   — start browser control panel"

# ══════════════════════════════════════════════════════════════════════════════
# INSTALL — supports optional HOST= for remote execution
# ══════════════════════════════════════════════════════════════════════════════
# Check if uv is installed, install if not
# Uses absolute path $(HOME)/.local/bin/uv after install
define check_uv
	@if [ ! -x "$(HOME)/.local/bin/uv" ] && ! command -v uv > /dev/null 2>&1; then \
		echo -e "${YELLOW}uv is not installed. Installing uv...${NC}"; \
		curl -LsSf https://astral.sh/uv/install.sh | sh; \
		echo -e "${GREEN}uv installed to $(HOME)/.local/bin/uv${NC}"; \
	else \
		echo -e "${GREEN}uv is already installed${NC}"; \
	fi
endef

# Check if terraform is installed, install if not
define check_terraform
	@if ! command -v terraform > /dev/null; then \
		echo -e "${YELLOW}Terraform is not installed. Installing terraform...${NC}"; \
		curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg; \
		echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $$(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list; \
		sudo apt-get update && sudo apt-get install -y terraform; \
		echo -e "${GREEN}Terraform installed successfully${NC}"; \
	else \
		echo -e "${GREEN}Terraform is already installed: $$(terraform version -json | head -1 | jq -r .terraform_version)${NC}"; \
	fi
endef

.PHONY: setup-terraform
setup-terraform: ## Install Terraform if not present
	$(call check_terraform)

# Virtual environment activation
define activate_venv
	@if [ ! -d "$(VENV)" ]; then \
		echo -e "${YELLOW}Virtual environment not found. Creating one...${NC}"; \
		$(UV) venv $(VENV) --python $(PYTHON_VERSION); \
	fi
	@echo -e "${GREEN}Activating virtual environment...${NC}"
	@source $(VENV_BIN)/activate || exit 1
endef

# Execute command in virtual environment (with uv path)
define run_in_venv
	@source $(VENV_BIN)/activate && \
	export PATH="$(HOME)/.local/bin:$$PATH" && \
	PYTHONPATH=$(PYTHONPATH) HOSTIP=$(DBIP) $1
endef

# Internal helper: run a command locally or on HOST (if set)
define run_on_host
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  echo "── Running on $${RESOLVED_NAME} ($${RESOLVED_USER}@$${RESOLVED_IP}) ──"; \
	  ssh -o ConnectTimeout=5 $${RESOLVED_USER}@$${RESOLVED_IP} $(1); \
	else \
	  $(1); \
	fi
endef

# Allow CMD or COMMAND for backward compatibility
CMD ?= $(COMMAND)
.PHONY: run 
run: ## Run and COMMAND passed as CMD="command"
	@echo -e "${BLUE}Starting all services...${NC}"
	@$(call run_in_venv, $(CMD))
	@echo -e "${GREEN}✓ Completed running ${CMD}${NC}"


install: install-deps
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  echo "── Installing on $${RESOLVED_NAME} (type=$${RESOLVED_TYPE}) ──"; \
	  ssh -p $${RESOLVED_SSH_PORT:-22} $${RESOLVED_USER}@$${RESOLVED_IP} \
	    "cd ~/$(INFRA_REPO) && make install SKIP_TOOLS=$${RESOLVED_SKIP_TOOLS} DEVICE_TYPE=$${RESOLVED_TYPE}"; \
	elif [ "$(DEVICE_TYPE)" = "android" ] || [ "$(DEVICE_TYPE)" = "ios_ish" ]; then \
	  echo "── Installing for $(DEVICE_TYPE) ──"; \
	  SKIP_TOOLS="$(SKIP_TOOLS)" bash scripts/install/tools.sh; \
	elif [ "$(DEVICE_TYPE)" = "windows" ]; then \
	  echo "── Windows: use scripts/install/bootstrap_windows.ps1 ──"; \
	  echo "  Run: powershell -File scripts/install/bootstrap_windows.ps1"; \
	elif [ "$(DEVICE_TYPE)" = "ios_termius" ]; then \
	  echo "── Termius (iOS): No local install needed — configure hosts in the Termius app ──"; \
	else \
	  $(PYTHON) setup.py device=$(or $(DEVICE),$(DEVICE_TYPE),server) +action=install_all; \
	fi

## Install Python dependencies (uv venv + pyproject.toml)
install-deps:
ifeq ($(DEVICE_TYPE),android)
	@echo "── Installing android Python deps (pip) ──"
	@command -v python3 &>/dev/null || pkg install -y python
	@pip install --quiet pyyaml 2>/dev/null || pip3 install --quiet pyyaml
	@echo "✓ Android deps ready"
else ifeq ($(DEVICE_TYPE),ios_ish)
	@echo "── Installing iSH Python deps (apk) ──"
	@command -v python3 &>/dev/null || apk add python3 py3-pip
	@pip3 install --quiet pyyaml 2>/dev/null || true
	@echo "✓ iSH deps ready"
else
	@echo "── Installing Python deps ──"
	@rm -f "$(VENV)/.deps-installed"
	$(ensure_venv)
	@echo "✓ Python deps ready"
endif

tailscale:
	@bash scripts/install/tailscale.sh

mosh:
	@bash scripts/install/mosh.sh

tmux:
	@bash scripts/install/tmux.sh

tools:
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  echo "── Installing tools on $${RESOLVED_NAME} ──"; \
	  ssh $${RESOLVED_USER}@$${RESOLVED_IP} \
	    "cd ~/$(INFRA_REPO) && SKIP_TOOLS=$${RESOLVED_SKIP_TOOLS} bash scripts/install/tools.sh"; \
	else \
	  bash scripts/install/tools.sh; \
	fi

gemini:
	@INSTALL_ONLY=gemini_cli bash scripts/install/tools.sh

vibetunnel:
	@INSTALL_ONLY=vibtunnel bash scripts/install/tools.sh

muxtree:
	@INSTALL_ONLY=muxtree bash scripts/install/tools.sh

install-multipass:
	@bash -c 'if command -v multipass >/dev/null 2>&1; then echo "✓ Multipass is already installed."; exit 0; fi; \
	if [ "$(AUTO)" = "1" ]; then \
		echo "✗ Multipass is not installed. Install it first: brew install multipass (macOS) or snap install multipass (Linux)"; exit 1; \
	fi; \
	if [ "$$(uname -s)" = "Darwin" ]; then \
		read -p "Install multipass via Homebrew? [y/N] " confirm; [[ "$$confirm" =~ ^[yY] ]] && brew install multipass || echo "Aborted."; \
	elif [ "$$(uname -s)" = "Linux" ]; then \
		read -p "Install multipass via Snap? [y/N] " confirm; [[ "$$confirm" =~ ^[yY] ]] && sudo snap install multipass || echo "Aborted."; \
	else \
		echo "Please install multipass manually from https://multipass.run/"; \
	fi'

install-tart:
	@bash -c 'if command -v tart >/dev/null 2>&1; then echo "✓ Tart is already installed."; exit 0; fi; \
	if [ "$(AUTO)" = "1" ]; then \
		echo "✗ Tart is not installed. Install it first: brew install cirruslabs/cli/tart"; exit 1; \
	fi; \
	if [ "$$(uname -s)" = "Darwin" ]; then \
		read -p "Install tart via Homebrew? [y/N] " confirm; [[ "$$confirm" =~ ^[yY] ]] && brew install cirruslabs/cli/tart || echo "Aborted."; \
	else \
		echo "Tart is only supported on macOS (Apple Silicon)."; exit 1; \
	fi'

test-sandbox:
	@_engine="$(or $(ENGINE),multipass)"; \
	$(MAKE) --no-print-directory install-$${_engine} || exit 1; \
	_args="$${_engine}"; \
	if [ "$(INTERACTIVE)" = "1" ]; then _args="$$_args --interactive"; fi; \
	if [ "$(AUTO)" = "1" ]; then _args="$$_args --auto"; fi; \
	if [ "$(KEEP)" = "1" ]; then _args="$$_args --keep"; fi; \
	if [ -n "$(UBUNTU_VERSION)" ]; then _args="$$_args --ubuntu-version=$(UBUNTU_VERSION)"; fi; \
	if [ -n "$(TART_IMAGE)" ]; then _args="$$_args --tart-image=$(TART_IMAGE)"; fi; \
	if [ -n "$(NAME)" ]; then _args="$$_args --name=$(NAME)"; fi; \
	if [ "$(UPDATE_PACKAGES)" = "1" ]; then _args="$$_args --update-packages"; fi; \
	bash scripts/dev/test_sandbox.sh $$_args

## Set a device as the exit node (config + advertise + proxy + aliases):  make set-exit-node HOST=<device>
set-exit-node:
	@if [ -z "$(HOST)" ]; then echo "✗ Required: make set-exit-node HOST=<device>"; exit 1; fi
	@DRY_RUN=$(DRY_RUN) bash scripts/configure/set_exit_node.sh "$(HOST)"

## Verify proxy prerequisites (SSH access to exit node):  make proxy
proxy:
	@bash scripts/install/proxy.sh

## Start SSH SOCKS5 proxy tunnel:  make proxy-start [EXIT_NODE=myserver] [PORT=1055]
proxy-start:
	@_port="$${PROXY_PORT:-$(or $(PORT),1055)}"; \
	_node="$(or $(EXIT_NODE),)"; \
	if [ -z "$$_node" ]; then \
	  _node=$$($(PYTHON) -c "import sys; sys.path.insert(0,'.'); from scripts.lib.load_config import load_config; c=load_config(); \
	    en=c.get('proxy',{}).get('exit_node',''); \
	    devs=c.get('tailscale',{}).get('devices',{}); \
	    print(en or next((n for n,d in devs.items() if d.get('advertise_exit_node')),''))" 2>/dev/null); \
	fi; \
	if [ -z "$$_node" ]; then echo "✗ No exit node. Use: make proxy-start EXIT_NODE=<name>"; exit 1; fi; \
	if lsof -nP -i4TCP:$$_port 2>/dev/null | grep -q LISTEN; then \
	  echo "✓ SOCKS5 tunnel already running on port $$_port"; \
	else \
	  _user=$$($(PYTHON) -c "import sys; sys.path.insert(0,'.'); from scripts.lib.load_config import load_config; c=load_config(); \
	    devs=c.get('tailscale',{}).get('devices',{}); \
	    d=devs.get('$$_node',{}); print(d.get('user',''))" 2>/dev/null); \
	  _target="$$_node"; [ -n "$$_user" ] && _target="$${_user}@$${_node}"; \
	  echo "Starting SSH SOCKS5 tunnel → $$_target (port $$_port)..."; \
	  if command -v autossh >/dev/null 2>&1; then \
	    AUTOSSH_GATETIME=0 autossh -M 0 \
	      -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
	      -o ConnectTimeout=10 -o ExitOnForwardFailure=yes \
	      -o StrictHostKeyChecking=accept-new \
	      -D $$_port -fN "$$_target" 2>/dev/null; \
	  else \
	    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -D $$_port -fNq "$$_target" 2>/dev/null; \
	  fi; \
	  sleep 1; \
	  if lsof -nP -i4TCP:$$_port 2>/dev/null | grep -q LISTEN; then \
	    echo "✓ SOCKS5 tunnel on 127.0.0.1:$$_port → $$_target"; \
	  else \
	    echo "✗ SSH tunnel failed. Check SSH connectivity to $$_target"; exit 1; \
	  fi; \
	fi

## Stop SSH SOCKS5 proxy tunnel:  make proxy-stop
proxy-stop:
	@_port="$${PROXY_PORT:-1055}"; \
	_pids=$$(lsof -nP -i4TCP:$$_port 2>/dev/null | grep LISTEN | awk '{print $$2}'); \
	if [ -n "$$_pids" ]; then echo "$$_pids" | xargs kill 2>/dev/null && echo "✓ SOCKS5 tunnel stopped"; \
	else echo "SOCKS5 tunnel was not running"; fi

## Check proxy status:  make proxy-status
proxy-status:
	@_port="$${PROXY_PORT:-1055}"; \
	if lsof -nP -i4TCP:$$_port 2>/dev/null | grep -q LISTEN; then \
	  echo "✓ SOCKS5 tunnel running on port $$_port"; \
	  lsof -nP -i4TCP:$$_port | grep LISTEN; \
	else \
	  echo "✗ SOCKS5 tunnel not running (port $$_port)"; \
	fi

## Enable/disable/status persistent SOCKS5 daemon:  make proxy-daemon [ACTION=enable|disable|status]
proxy-daemon:
	@_action="$${ACTION:-status}"; \
	if [ "$$(uname)" = "Darwin" ]; then \
	  _plist="$$HOME/Library/LaunchAgents/com.tenai.socks5.plist"; \
	  if [ ! -f "$$_plist" ]; then echo "✗ Daemon plist not found. Run: make proxy"; exit 1; fi; \
	  case "$$_action" in \
	    enable)  launchctl load "$$_plist" 2>/dev/null && echo "✓ SOCKS5 daemon enabled (launchd)" ;; \
	    disable) launchctl unload "$$_plist" 2>/dev/null && echo "✓ SOCKS5 daemon disabled" ;; \
	    status)  launchctl list com.tenai.socks5 2>/dev/null | grep -q PID && \
	             echo "✓ SOCKS5 daemon: running (launchd)" || \
	             echo "✗ SOCKS5 daemon: not running" ;; \
	    *) echo "Usage: make proxy-daemon ACTION=enable|disable|status" ;; \
	  esac; \
	else \
	  case "$$_action" in \
	    enable)  systemctl --user enable --now tenai-socks5 2>/dev/null && \
	             loginctl enable-linger "$$(whoami)" 2>/dev/null; \
	             echo "✓ SOCKS5 daemon enabled (systemd)" ;; \
	    disable) systemctl --user disable --now tenai-socks5 2>/dev/null && \
	             echo "✓ SOCKS5 daemon disabled" ;; \
	    status)  systemctl --user is-active tenai-socks5 >/dev/null 2>&1 && \
	             echo "✓ SOCKS5 daemon: running (systemd)" || \
	             echo "✗ SOCKS5 daemon: not running" ;; \
	    *) echo "Usage: make proxy-daemon ACTION=enable|disable|status" ;; \
	  esac; \
	fi

## Start/restart VibeTunnel server:  make vt-server [HOST=myserver] [PORT=4020]
vt-server:
	@VT_PORT="$${VT_PORT:-$(or $(PORT),4020)}"; \
	if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  echo "── Starting VibeTunnel on $${RESOLVED_NAME} (port $$VT_PORT) ──"; \
	  ssh $${RESOLVED_USER}@$${RESOLVED_IP} " \
	    if systemctl --user is-active vibetunnel >/dev/null 2>&1; then \
	      echo '✓ VibeTunnel already running (systemd)'; \
	      systemctl --user status vibetunnel 2>&1 | head -5; \
	    elif ss -tlnp 2>/dev/null | grep -q :$$VT_PORT; then \
	      echo '✓ VibeTunnel already running on port $$VT_PORT'; \
	    else \
	      if systemctl --user start vibetunnel 2>/dev/null; then \
	        sleep 2; \
	        echo '✓ VibeTunnel started (systemd)'; \
	      else \
	        VT_DIR=\$$(npm root -g)/vibetunnel; \
	        tmux new-session -d -s vt-server \"cd \$$VT_DIR && exec node dist/cli.js --no-auth --port $$VT_PORT\" 2>/dev/null; \
	        sleep 3; echo '✓ VibeTunnel started (tmux fallback)'; \
	      fi; \
	    fi"; \
	else \
	  if systemctl --user is-active vibetunnel >/dev/null 2>&1; then \
	    echo "✓ VibeTunnel already running (systemd)"; \
	    systemctl --user status vibetunnel 2>&1 | head -5; \
	  elif ss -tlnp 2>/dev/null | grep -q ":$$VT_PORT"; then \
	    echo "✓ VibeTunnel already running on port $$VT_PORT"; \
	  else \
	    systemctl --user start vibetunnel 2>/dev/null && echo "✓ VibeTunnel started (systemd)" || \
	    { VT_DIR=$$(npm root -g)/vibetunnel; \
	      tmux new-session -d -s vt-server "cd $$VT_DIR && exec node dist/cli.js --no-auth --port $$VT_PORT"; \
	      sleep 3; echo "✓ VibeTunnel started (tmux fallback)"; }; \
	  fi; \
	fi

## ── CLI Configuration Targets ──
# All targets support: HOST=device|all, CLI=gemini|claude
# Shared helper: scripts/install/cli_setup.sh (ACTION, CLI, TYPE, EXT env vars)

_cli_run = \
	if [ -n "$(HOST)" ] && [ "$(HOST)" != "$$(hostname)" ]; then \
	  if [ "$(HOST)" = "all" ]; then \
	    echo "── Running on all devices ──"; \
	    $(PYTHON) -c "import yaml; \
	      import sys; sys.path.insert(0,'.'); from scripts.lib.load_config import load_config; cfg=load_config(); \
	      devs=cfg.get('tailscale',{}).get('devices',{}); \
	      [print(f\"{n} {d.get('user','ubuntu')} {d.get('ip','')}\") for n,d in devs.items()]" 2>/dev/null | \
	    while read dname duser dip; do \
	      echo "── $$dname ($$dip) ──"; \
	      ssh -o BatchMode=yes -o ConnectTimeout=10 $$duser@$$dip \
	        "cd ~/$(INFRA_REPO) && $(1) bash scripts/install/cli_setup.sh" 2>/dev/null || \
	        echo "  ⚠ $$dname: failed (offline?)"; \
	    done; \
	  else \
	    _user=$$($(PYTHON) -c "import sys; sys.path.insert(0,'.'); from scripts.lib.load_config import load_config; d=load_config(); print(d.get('tailscale',{}).get('devices',{}).get('$(HOST)',{}).get('user','ubuntu'))" 2>/dev/null || echo ubuntu); \
	    _ip=$$($(PYTHON) -c "import sys; sys.path.insert(0,'.'); from scripts.lib.load_config import load_config; d=load_config(); print(d.get('tailscale',{}).get('devices',{}).get('$(HOST)',{}).get('ip','$(HOST)'))" 2>/dev/null || echo "$(HOST)"); \
	    ssh -o BatchMode=yes $$_user@$$_ip \
	      "cd ~/$(INFRA_REPO) && $(1) bash scripts/install/cli_setup.sh"; \
	  fi; \
	else \
	  $(1) bash scripts/install/cli_setup.sh; \
	fi

## Install all CLI config from config/cli/:  make cli-setup [HOST=x|all] [CLI=gemini|claude]
cli-setup:
	$(ensure_venv)
	@$(call _cli_run,CLI=$(CLI) TYPE=$(TYPE) ACTION=setup)

## Install/update CLI extensions only:  make cli-extensions [HOST=x|all] [CLI=gemini|claude]
cli-extensions:
	$(ensure_venv)
	@$(call _cli_run,CLI=$(CLI) TYPE=extensions ACTION=setup)

## Install/update MCP servers only:  make cli-mcp [HOST=x|all] [CLI=claude]
cli-mcp:
	$(ensure_venv)
	@$(call _cli_run,CLI=$(CLI) TYPE=mcp ACTION=setup)

## Install/update CLI plugins only:  make cli-plugins [HOST=x|all] [CLI=claude]
cli-plugins:
	$(ensure_venv)
	@$(call _cli_run,CLI=$(CLI) TYPE=plugins ACTION=setup)

## Copy skill files:  make cli-skills [HOST=x|all] [CLI=gemini|claude]
cli-skills:
	$(ensure_venv)
	@$(call _cli_run,CLI=$(CLI) TYPE=skills ACTION=setup)

## Merge settings.json:  make cli-settings [HOST=x|all] [CLI=gemini|claude]
cli-settings:
	$(ensure_venv)
	@$(call _cli_run,CLI=$(CLI) TYPE=settings ACTION=setup)

## Copy global rule files:  make cli-rules [HOST=x|all] [CLI=gemini|claude]
cli-rules:
	$(ensure_venv)
	@$(call _cli_run,CLI=$(CLI) TYPE=rules ACTION=setup)

## Install Vercel skills (cross-CLI):  make cli-vercel-skills [HOST=x|all] [CLI=gemini|claude]
cli-vercel-skills:
	$(ensure_venv)
	@$(call _cli_run,CLI=$(CLI) TYPE=vercel-skills ACTION=setup)

## List all installed CLI assets:  make cli-list [HOST=x] [CLI=gemini|claude]
cli-list:
	$(ensure_venv)
	@$(call _cli_run,CLI=$(CLI) ACTION=list)

## Install a single CLI asset:  make cli-install CLI=gemini TYPE=extensions EXT=conductor [HOST=x]
cli-install:
	$(ensure_venv)
	@if [ -z "$(CLI)" ] || [ -z "$(TYPE)" ] || [ -z "$(EXT)" ]; then \
	  echo "Usage: make cli-install CLI=gemini|claude TYPE=extensions|mcp|plugins EXT=name [HOST=x]"; \
	  exit 1; \
	fi
	@$(call _cli_run,CLI=$(CLI) TYPE=$(TYPE) EXT=$(EXT) ACTION=install)

# ══════════════════════════════════════════════════════════════════════════════
# CONFIGURE  (local equivalent of 'make sync' for remote devices)
# ══════════════════════════════════════════════════════════════════════════════
## Configure local device:  make configure
##   Runs: SSH config, aliases, CLI setup (skills/extensions/settings/rules),
##   symlinks, and pre-creates data directories with correct permissions.
configure: configure-ssh configure-aliases configure-cli configure-proxy configure-dirs
	@echo "✓ Configuration complete"

configure-ssh:
	@bash scripts/configure/ssh.sh

configure-aliases:
	@bash scripts/configure/aliases.sh

configure-cli:
	@echo "── Setting up CLI skills/extensions/settings ──"
	@bash scripts/install/cli_setup.sh || true
	@$(MAKE) skills-sync 2>/dev/null || true

configure-proxy:
	$(ensure_venv)
	@_proxy_enabled=$$($(PYTHON) -c "import sys; sys.path.insert(0,'.'); \
	  from scripts.lib.load_config import load_config; c=load_config(); \
	  print(c.get('proxy',{}).get('enabled',False))" 2>/dev/null || echo False); \
	if [ "$$_proxy_enabled" = "True" ]; then \
	  echo "── Setting up proxy (SSH SOCKS5 + privoxy bridge) ──"; \
	  bash scripts/install/proxy.sh; \
	else \
	  echo "── Proxy disabled (proxy.enabled=false in config) ──"; \
	fi

configure-dirs:
	@mkdir -p ~/.tenai_envs && chmod 700 ~/.tenai_envs 2>/dev/null || true
	@mkdir -p ~/.tenai && chmod 700 ~/.tenai 2>/dev/null || true
	@if [ -d .env ]; then echo "⚠ .env is a directory — fixing"; rm -rf .env; touch .env; fi

aliases: configure-aliases

## List all available tools (static):  make list-tools [HOST=mydevice]
list-tools:
	@$(PYTHON) scripts/configure/list_tools.py --mode=available $(if $(HOST),--host $(HOST))

## Check which tools are installed (dynamic):  make check-tools [HOST=mydevice]
check-tools:
	@$(PYTHON) scripts/configure/list_tools.py --mode=installed $(if $(HOST),--host $(HOST))

## Push aliases to a remote device:  make push-aliases HOST=mydevice
push-aliases:
	@if [ -z "$(HOST)" ]; then echo "Usage: make push-aliases HOST=<device>"; exit 1; fi
	@bash scripts/configure/push_aliases.sh $(HOST)

## Set up per-org SSH keys for GitHub:  make git-ssh [ORG=myorg] [KEY=my-ssh-key] [HOST=myserver]
##   Without ORG: sets up all orgs from config.  Without KEY: uses org's ssh_key from config.
##   Without HOST: runs locally.  With HOST: runs on remote (copies local key first).
##   GENERATE_GIT_SSH_KEY=1: generate a new key on the device instead of copying.
git-ssh:
	@HOST="$(HOST)" ORG="$(ORG)" KEY="$(KEY)" TOKEN="$(TOKEN)" \
	  GENERATE_GIT_SSH_KEY="$(GENERATE_GIT_SSH_KEY)" \
	  bash scripts/entrypoints/git_ssh.sh "$(HOST)"


# ==========================================
# GitHub Actions Secrets (gh-*)
# ==========================================

.PHONY: gh-secrets-set
gh-secrets-set: ## Set GitHub Actions secrets (PARAMETERS="KEY1=VALUE1,KEY2=VALUE2")
	@if [ -z "$(PARAMETERS)" ]; then \
		echo -e "${RED}Error: PARAMETERS required.${NC}"; \
		echo "Usage: make gh-secrets-set PARAMETERS=\"EC2_INSTANCE_ID=i-0abc123,EC2_HOST=1.2.3.4\""; \
		exit 1; \
	fi
	@echo -e "${BLUE}Setting GitHub Actions secrets...${NC}"
	@IFS=',' ; for pair in $(PARAMETERS); do \
		key=$$(echo "$$pair" | cut -d'=' -f1); \
		value=$$(echo "$$pair" | cut -d'=' -f2-); \
		if [ -z "$$key" ] || [ -z "$$value" ]; then \
			echo -e "${RED}Skipping invalid pair: $$pair${NC}"; \
			continue; \
		fi; \
		echo -n "  Setting $$key... "; \
		echo "$$value" | gh secret set "$$key" && \
			echo -e "${GREEN}✅${NC}" || \
			echo -e "${RED}❌ Failed${NC}"; \
	done
	@echo -e "${GREEN}Done.${NC}"

.PHONY: gh-secrets-list
gh-secrets-list: ## List all GitHub Actions secrets
	@echo -e "${BLUE}GitHub Actions secrets:${NC}"
	@gh secret list

# ══════════════════════════════════════════════════════════════════════════════
# DEVICE ONBOARDING & BOOTSTRAP
# ══════════════════════════════════════════════════════════════════════════════

## Reset device config:  make reset-device [TAILNET=yourname@] [FULL_RESET=1] [NONINTERACTIVE=1]
##   Backs up config, resets device list, walks through .env and API keys.
##   FULL_RESET=1: also runs make uninstall to reverse all tracked changes.
##   NONINTERACTIVE=1: skip prompts (uses env vars for TAILNET, keeps .env as-is).
reset-device:
	@TAILNET=$(TAILNET) NONINTERACTIVE=$(NONINTERACTIVE) FULL_RESET=$(FULL_RESET) \
	 CONFIRM=$(CONFIRM) bash scripts/entrypoints/reset_device.sh

##   HOST=x: perform setup remotely over SSH
_setup: install configure
	@echo "══════════════════════════════════════════════════"
	@echo "  TenAI Infrastructure — Setup Complete"

## Onboard a device:  make onboard [IP=x] [HOST=x] [SSH_KEY=path] [TYPE=server|mac|...] [NAME=x] [TERMIUS=1]
##   IP — direct IP address of the target device
##   HOST — SSH config alias or device name from defaults.yaml
##   SSH_KEY — path to SSH private key for initial access
##   TYPE — override auto-detection (server|mac|windows|android|ios|wsl)
onboard:
	@TYPE=$(TYPE) NAME=$(NAME) IP=$(IP) HOST=$(or $(HOST),) SSH_KEY=$(SSH_KEY) \
	 REMOTE_USER=$(REMOTE_USER) TERMIUS=$(TERMIUS) DRY_RUN=$(DRY_RUN) \
	 EXIT_NODE=$(EXIT_NODE) TEST=$(TEST) \
	 bash scripts/entrypoints/onboard.sh

## Bootstrap a remote device:  make new-server HOST=<name|ip> [NAME=label] [SSH_KEY=path]
##   HOST can be: device name from config, IP address, or ~/.ssh/config alias
new-server:
	@if [ -z "$(HOST)" ] && [ -z "$(IP)" ]; then echo "Usage: make new-server HOST=<device-name-or-ip> [NAME=label] [SSH_KEY=path]"; exit 1; fi
	@PYTHON=$(PYTHON) SSH_KEY=$(SSH_KEY) bash scripts/entrypoints/new_server.sh "$(or $(HOST),$(IP))" "$(NAME)"

## Sync code to a remote device:  make sync HOST=myserver [GIT_PULL=1]
##   Default: rsync local codebase. GIT_PULL=1: git pull on the remote instead.
sync:
	@if [ -z "$(HOST)" ]; then echo "Usage: make sync HOST=<device> [GIT_PULL=1]"; exit 1; fi
	@PYTHON=$(PYTHON) bash scripts/entrypoints/sync.sh "$(HOST)" "$(GIT_PULL)"

## Sync code to ALL remote devices:  make sync-all [GIT_PULL=1]
##   Automatically skips the local device.
sync-all:
	@echo "══════════════════════════════════════════════════"
	@echo "  Syncing to all remote devices"
	@echo "══════════════════════════════════════════════════"
	@for device in $$($(PYTHON) scripts/configure/list_devices.py --exclude-local); do \
	   echo ""; \
	   echo "━━━━━━━ $$device ━━━━━━━"; \
	   $(MAKE) sync HOST=$$device GIT_PULL=$(GIT_PULL) || echo "✗ Failed to sync $$device (continuing)"; \
	 done
	@echo ""
	@echo "✓ Sync-all complete"

## Distribute SSH keys across devices:  make distribute-keys [HOST=mydevice]
##   Without HOST: full mesh (all ↔ all). With HOST: single device ↔ all.
distribute-keys:
	@bash scripts/configure/distribute_ssh_keys.sh $(HOST)

# ══════════════════════════════════════════════════════════════════════════════
# UNINSTALL & STATE TRACKING
# ══════════════════════════════════════════════════════════════════════════════

## Uninstall what we added:  make uninstall [HOST=myserver] [DRY_RUN=1] [KEEP=mosh]
##   Reverses all tracked actions on the local or specified remote device.
uninstall:
	@bash scripts/entrypoints/uninstall.sh "$(HOST)"

## Show current device state:  make state [HOST=myserver]
##   Displays the tracked manifest of what tenai has installed/changed.
state:
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  REMOTE_INFRA_DIR=$$($(PYTHON) -c "import sys; sys.path.insert(0, '.'); from scripts.lib.load_config import load_config; print(load_config().get('repos', {}).get('infra_dir', 'tenai'))" 2>/dev/null || echo tenai); \
	  ssh -p $${RESOLVED_SSH_PORT:-22} $${RESOLVED_USER}@$${RESOLVED_IP} "python3 ~/$$REMOTE_INFRA_DIR/scripts/lib/state_tracker.py show --device $$RESOLVED_NAME"; \
	else \
	  $(PYTHON) scripts/lib/state_tracker.py show --device "$${DEVICE_NAME:-$$(hostname -s 2>/dev/null || echo local)}"; \
	fi

## Reconstruct missing manifest:  make state-audit [HOST=myserver]
##   Scans the device to retroactively build a best-effort install manifest.
state-audit:
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  REMOTE_INFRA_DIR=$$($(PYTHON) -c "import sys; sys.path.insert(0, '.'); from scripts.lib.load_config import load_config; print(load_config().get('repos', {}).get('infra_dir', 'tenai'))" 2>/dev/null || echo tenai); \
	  ssh -p $${RESOLVED_SSH_PORT:-22} $${RESOLVED_USER}@$${RESOLVED_IP} "python3 ~/$$REMOTE_INFRA_DIR/scripts/lib/state_tracker.py audit --device $$RESOLVED_NAME --infra-dir ~/$$REMOTE_INFRA_DIR"; \
	else \
	  $(PYTHON) scripts/lib/state_tracker.py audit --device "$${DEVICE_NAME:-$$(hostname -s 2>/dev/null || echo local)}" --infra-dir "$(PWD)"; \
	fi


## Sync named env files to devices:  make sync-envs [HOST=mydevice]
##   Syncs ~/.tenai_envs/ directory to remote devices via rsync.
##   Without HOST: syncs to all devices. With HOST: syncs to one device.
sync-envs:
	@if [ ! -d "$$HOME/.tenai_envs" ]; then \
	  echo "No ~/.tenai_envs/ directory found. Create named env files first."; exit 0; \
	fi
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  echo "── Syncing env files to $${RESOLVED_NAME} ──"; \
	  rsync -avz --chmod=D700,F600 $$HOME/.tenai_envs/ \
	    $${RESOLVED_USER}@$${RESOLVED_IP}:~/.tenai_envs/; \
	else \
	  echo "── Syncing env files to ALL devices ──"; \
	  for device in $$($(PYTHON) scripts/configure/list_devices.py --exclude-local); do \
	    eval $$($(PYTHON) scripts/configure/resolve_host.py $$device); \
	    echo "  → $${RESOLVED_NAME}"; \
	    rsync -avz --chmod=D700,F600 $$HOME/.tenai_envs/ \
	      $${RESOLVED_USER}@$${RESOLVED_IP}:~/.tenai_envs/ 2>/dev/null || \
	      echo "  ⚠ Failed (offline?)"; \
	  done; \
	  echo "✓ Sync complete"; \
	fi

## Push a local .env to a device:  make push-env HOST=x [ENV_FILE=.env] [NAME=myrepo]
##   Copies ENV_FILE (default: .env) as ~/.tenai_envs/{NAME}.env on the device.
##   NAME defaults to {org}--{repo} from git remote, or directory basename.
push-env:
	@if [ -z "$(HOST)" ]; then echo "Usage: make push-env HOST=<device> [ENV_FILE=.env] [NAME=myrepo]"; exit 1; fi
	@_env_src="$(or $(ENV_FILE),.env)"; \
	if [ ! -f "$$_env_src" ]; then echo "✗ File not found: $$_env_src"; exit 1; fi; \
	if [ -n "$(NAME)" ]; then \
	  _env_name="$(NAME).env"; \
	else \
	  _origin=$$(git remote get-url origin 2>/dev/null || echo ""); \
	  if [ -n "$$_origin" ]; then \
	    _env_name=$$(echo "$$_origin" | sed 's|.*[:/]\([^/]*/[^/]*\)\.git$$|\1|;s|.*[:/]\([^/]*/[^/]*\)$$|\1|;s|/|--|'); \
	    _env_name="$${_env_name}.env"; \
	  else \
	    _env_name="$$(basename $$(pwd)).env"; \
	  fi; \
	fi; \
	eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	echo "── Pushing $$_env_src → $${RESOLVED_NAME}:~/.tenai_envs/$$_env_name ──"; \
	ssh -o BatchMode=yes $${RESOLVED_USER}@$${RESOLVED_IP} \
	  "mkdir -p ~/.tenai_envs && chmod 700 ~/.tenai_envs 2>/dev/null; \
	   cat > ~/.tenai_envs/$$_env_name && chmod 600 ~/.tenai_envs/$$_env_name" \
	  < "$$_env_src" || \
	  { echo "✗ Failed to push env file"; exit 1; }; \
	echo "✓ Pushed as ~/.tenai_envs/$$_env_name on $${RESOLVED_NAME}"

## Create tagged release:  make tagged-release [PATCH=1|MINOR=1|MAJOR=1] [AUTO_MESSAGE=1|MESSAGE="..."|MESSAGE_FILE=path]
##   Increments version from last git tag, sanitizes config, tags and pushes.
##   AUTO_MESSAGE=1: use pre-generated .release_notes/ file (or auto-generate).
tagged-release:
	@bash scripts/entrypoints/tagged_release.sh

## Generate release notes:  make release-notes [PATCH=1|MINOR=1|MAJOR=1] [FROM=tag] [MESSAGE="..."] [FORCE=1]
##   Saves to .release_notes/{next_version}.md. Idempotent unless FORCE=1. Default: PATCH.
release-notes:
	@bash scripts/entrypoints/release_notes.sh \
	  $(if $(PATCH),PATCH=$(PATCH)) $(if $(MINOR),MINOR=$(MINOR)) $(if $(MAJOR),MAJOR=$(MAJOR)) \
	  $(if $(FROM),FROM=$(FROM)) $(if $(MESSAGE),MESSAGE="$(MESSAGE)") $(if $(FORCE),FORCE=$(FORCE))

# ══════════════════════════════════════════════════════════════════════════════
# PROJECT SCAFFOLD
# ══════════════════════════════════════════════════════════════════════════════
new-project:
	@DIR_VAL=$(or $(DIR),$(PWD)); \
	 NAME_VAL=$(or $(NAME),$(shell basename $(or $(DIR),$(PWD)))); \
	 PROJECT_DIR=$${DIR_VAL} PROJECT_NAME=$${NAME_VAL} bash scripts/configure/agents_md.sh; \
	 PROJECT_DIR=$${DIR_VAL} PROJECT_NAME=$${NAME_VAL} bash scripts/configure/claude_md.sh; \
	 PROJECT_DIR=$${DIR_VAL} PROJECT_NAME=$${NAME_VAL} bash scripts/configure/gemini_md.sh; \
	 echo "✓ Project scaffolded: $${DIR_VAL}"

# ══════════════════════════════════════════════════════════════════════════════
# GEMINI CONDUCTOR — per-repo task generation sessions
# ══════════════════════════════════════════════════════════════════════════════

## Start Gemini Conductor for a repo:  make conductor REPO=myapp [HOST=myserver] [ORG=myorg] [NEW=1]
conductor:
	@if [ -z "$(REPO)" ]; then \
	  echo "Usage: make conductor REPO=<repo-name> [HOST=<device>] [ORG=<org>]"; \
	  echo "       REPO can be a name under $(BASE_DIR) or a full path"; \
	  exit 1; \
	fi
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  if [ "$${RESOLVED_USER}" = "root" ]; then REMOTE_HOME="/root"; else REMOTE_HOME="/home/$${RESOLVED_USER}"; fi; \
	  REMOTE_BASE="$${REMOTE_HOME}/tenai-projects"; \
	  REMOTE_REPO="$${REMOTE_BASE}/$(if $(ORG),$(ORG)/)$(REPO)"; \
	  echo "── Conductor on $${RESOLVED_NAME}: $(REPO) ──"; \
	  echo "   Repo path: $${REMOTE_REPO}"; \
	  ssh -p $${RESOLVED_SSH_PORT:-22} $${RESOLVED_USER}@$${RESOLVED_IP} \
	    "if [ '$(NEW)' = '1' ] || ! tmux has-session -t $(REPO)-conductor 2>/dev/null; then \
	       cd $${REMOTE_REPO} 2>/dev/null || { echo '✗ Repo not found: $${REMOTE_REPO}'; exit 1; }; \
	       NO_ATTACH=1 NEW_SESSION=$(NEW) REPO_DIR=$${REMOTE_REPO} ACTION=start bash ~/$(INFRA_REPO)/scripts/conductor/gemini_session.sh; \
	     fi"; \
	  SESSION_NAME="$(REPO)-conductor"; \
	  if [ "$(NEW)" = "1" ]; then \
	    SESSION_NAME=$$(ssh -p $${RESOLVED_SSH_PORT:-22} $${RESOLVED_USER}@$${RESOLVED_IP} \
	      "tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^$(REPO)-conductor' | sort | tail -1" < /dev/null); \
	    [ -z "$$SESSION_NAME" ] && SESSION_NAME="$(REPO)-conductor"; \
	  fi; \
	  echo "Attaching to $$SESSION_NAME (detach: prefix + d)..."; \
	  ssh -t -p $${RESOLVED_SSH_PORT:-22} $${RESOLVED_USER}@$${RESOLVED_IP} \
	    "tmux attach-session -t $$SESSION_NAME"; \
	else \
	  REPO_PATH=$(BASE_DIR)/$(REPO); \
	  [ -d "$(REPO)" ] && REPO_PATH=$(REPO) || true; \
	  NEW_SESSION=$(NEW) REPO_DIR=$${REPO_PATH} ACTION=start bash scripts/conductor/gemini_session.sh; \
	fi

## Send a prompt to running conductor:  make conductor-send REPO=x PROMPT="..." [HOST=y]
conductor-send:
	@if [ -z "$(REPO)" ] || [ -z "$(PROMPT)" ]; then \
	  echo "Usage: make conductor-send REPO=<name> PROMPT='...' [HOST=<device>]"; exit 1; fi
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  if [ "$${RESOLVED_USER}" = "root" ]; then REMOTE_HOME="/root"; else REMOTE_HOME="/home/$${RESOLVED_USER}"; fi; \
	  REMOTE_BASE="$${REMOTE_HOME}/tenai-projects"; \
	  ssh -p $${RESOLVED_SSH_PORT:-22} $${RESOLVED_USER}@$${RESOLVED_IP} \
	    "REPO_DIR=$${REMOTE_BASE}/$(if $(ORG),$(ORG)/)$(REPO) ACTION=send PROMPT='$(PROMPT)' bash ~/$(INFRA_REPO)/scripts/conductor/gemini_session.sh" < /dev/null; \
	else \
	  REPO_DIR=$(BASE_DIR)/$(REPO) ACTION=send PROMPT="$(PROMPT)" bash scripts/conductor/gemini_session.sh; \
	fi

## Show TASKS.md for a repo:  make tasks REPO=myapp [HOST=y] [ORG=x]
tasksmd:
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  if [ "$${RESOLVED_USER}" = "root" ]; then REMOTE_HOME="/root"; else REMOTE_HOME="/home/$${RESOLVED_USER}"; fi; \
	  REMOTE_BASE="$${REMOTE_HOME}/tenai-projects"; \
	  REMOTE_REPO="$${REMOTE_BASE}/$(if $(ORG),$(ORG)/)$(or $(REPO),.)"; \
	  ssh -p $${RESOLVED_SSH_PORT:-22} $${RESOLVED_USER}@$${RESOLVED_IP} \
	    "REPO_DIR=$${REMOTE_REPO} ACTION=tasks bash ~/$(INFRA_REPO)/scripts/conductor/gemini_session.sh" < /dev/null; \
	else \
	  REPO_DIR=$(BASE_DIR)/$(or $(REPO),.) ACTION=tasks bash scripts/conductor/gemini_session.sh; \
	fi

## List all conductor sessions [HOST=y]
conductor-list:
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  ssh -p $${RESOLVED_SSH_PORT:-22} $${RESOLVED_USER}@$${RESOLVED_IP} \
	    "cd ~/$(INFRA_REPO) && ACTION=list REPO_DIR=. bash scripts/conductor/gemini_session.sh" < /dev/null; \
	else \
	  ACTION=list REPO_DIR=$(PWD) bash scripts/conductor/gemini_session.sh; \
	fi

## Start conductors for ALL repos in BASE_DIR
conductor-all:
	@echo "── Starting conductors for all repos ──"
	@for dir in $(BASE_DIR)/*/; do \
	  if [ -d "$${dir}/.git" ]; then \
	    echo "  → $${dir}"; \
	    REPO_DIR="$${dir}" ACTION=start bash scripts/conductor/gemini_session.sh 2>/dev/null & \
	  fi; \
	done; \
	echo "✓ All conductors started (detached)"

## Parse TASKS.md for a repo:  make parse-tasks REPO=x [HOST=y] [SECTION=Active] [JSON=1]
parse-tasks:
	@if [ -z "$(REPO)" ]; then echo "Usage: make parse-tasks REPO=<name> [HOST=<device>] [SECTION=Active|'In Progress'|Done] [JSON=1]"; exit 1; fi
	@PARSE_ARGS="$(BASE_DIR)/$(REPO)"; \
	 if [ -n "$(SECTION)" ]; then PARSE_ARGS="$$PARSE_ARGS --section '$(SECTION)'"; fi; \
	 if [ "$(JSON)" = "1" ]; then PARSE_ARGS="$$PARSE_ARGS --json"; fi; \
	 if [ "$(DISPATCHABLE)" = "1" ]; then PARSE_ARGS="$$PARSE_ARGS --dispatchable"; fi; \
	 if [ -n "$(HOST)" ]; then \
	   eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	   if [ "$${RESOLVED_USER}" = "root" ]; then REMOTE_HOME="/root"; else REMOTE_HOME="/home/$${RESOLVED_USER}"; fi; \
	   REMOTE_BASE="$${REMOTE_HOME}/tenai-projects"; \
	   REMOTE_REPO="$${REMOTE_BASE}/$(if $(ORG),$(ORG)/)$(REPO)"; \
	   ssh -p $${RESOLVED_SSH_PORT:-22} $${RESOLVED_USER}@$${RESOLVED_IP} \
	     "cd ~/$(INFRA_REPO) && make parse-tasks REPO=$(REPO) $(if $(SECTION),SECTION='$(SECTION)',) $(if $(filter 1,$(JSON)),JSON=1,)" < /dev/null; \
	 else \
	   $(PYTHON) scripts/conductor/parse_tasks.py $$PARSE_ARGS; \
	 fi

## Validate TASKS.md ATC compliance:  make validate-tasks REPO=x [HOST=y] [ORG=z]
validate-tasks:
	@if [ -z "$(REPO)" ]; then echo "Usage: make validate-tasks REPO=<name> [HOST=<device>] [ORG=<org>]"; exit 1; fi
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  if [ "$${RESOLVED_USER}" = "root" ]; then REMOTE_HOME="/root"; else REMOTE_HOME="/home/$${RESOLVED_USER}"; fi; \
	  REMOTE_BASE="$${REMOTE_HOME}/tenai-projects"; \
	  REMOTE_REPO="$${REMOTE_BASE}/$(if $(ORG),$(ORG)/)$(REPO)"; \
	  ssh -p $${RESOLVED_SSH_PORT:-22} $${RESOLVED_USER}@$${RESOLVED_IP} \
	    "cd ~/$(INFRA_REPO) && make validate-tasks REPO=$(REPO) $(if $(ORG),ORG=$(ORG),)" < /dev/null; \
	else \
	  $(PYTHON) scripts/conductor/parse_tasks.py $(BASE_DIR)/$(if $(ORG),$(ORG)/)$(REPO) --validate; \
	fi

## Auto-dispatch all Active tasks:  make dispatch-tasks REPO=x [HOST=y] [CLI=claude] [ORG=z]
dispatch-tasks:
	@if [ -z "$(REPO)" ]; then echo "Usage: make dispatch-tasks REPO=<name> [HOST=<device>] [CLI=claude|gemini|codex] [ORG=<org>]"; exit 1; fi
	@echo "── Auto-dispatching Active tasks from TASKS.md ──"
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  ssh -p $${RESOLVED_SSH_PORT:-22} $${RESOLVED_USER}@$${RESOLVED_IP} \
	    "cd ~/$(INFRA_REPO) && make dispatch-tasks REPO=$(REPO) \
	      $(if $(ORG),ORG=$(ORG),) \
	      $(if $(CLI),CLI=$(CLI),)" < /dev/null; \
	else \
	  TASKS_JSON=$$($(PYTHON) scripts/conductor/parse_tasks.py $(BASE_DIR)/$(if $(ORG),$(ORG)/)$(REPO) --dispatchable --json); \
	  if [ -z "$$TASKS_JSON" ] || [ "$$TASKS_JSON" = "[]" ]; then \
	    echo "No dispatchable tasks found in TASKS.md"; exit 0; \
	  fi; \
	  echo "$$TASKS_JSON" | $(PYTHON) -c "import json, sys, subprocess; tasks = json.load(sys.stdin); [subprocess.run(['make', 'dispatch', 'REPO=$(REPO)', f'BRANCH={t[\"branch\"]}', f'TASK={t[\"description\"]}'] + (['CLI=$(or $(CLI),claude)'] if '$(CLI)' else [])) or print(f'\\n━━━ Task {t[\"number\"]}: {t[\"title\"]} (branch={t[\"branch\"]}) ━━━') for t in tasks]; print('\\n✓ All tasks dispatched')"; \
	fi

# ══════════════════════════════════════════════════════════════════════════════
# REPO MANAGEMENT
# ══════════════════════════════════════════════════════════════════════════════

## Clone a repo:  make clone REPO=git@github.com:org/repo.git [BRANCH=main]
clone:
	@if [ -z "$(REPO)" ]; then echo "Usage: make clone REPO=<git-url>"; exit 1; fi
	@BASE_DIR=$(BASE_DIR) ACTION=clone REPO_URL=$(REPO) BRANCH=$(or $(BRANCH),main) \
	  bash scripts/repos/manage.sh

## Pull a specific repo:  make pull REPO=brownfield-cartographer
pull:
	@if [ -z "$(REPO)" ]; then \
	  $(MAKE) pull-all; \
	else \
	  BASE_DIR=$(BASE_DIR) ACTION=pull REPO_DIR=$(BASE_DIR)/$(REPO) bash scripts/repos/manage.sh; \
	fi

## Pull all repos in BASE_DIR
pull-all:
	@BASE_DIR=$(BASE_DIR) ACTION=pull-all bash scripts/repos/manage.sh

## List all repos
repos:
	@BASE_DIR=$(BASE_DIR) ACTION=list bash scripts/repos/manage.sh

## Full git status across all repos
repo-status:
	@BASE_DIR=$(BASE_DIR) ACTION=status bash scripts/repos/manage.sh

# ══════════════════════════════════════════════════════════════════════════════
# GIT WORKTREES — parallel agent isolation
# ══════════════════════════════════════════════════════════════════════════════

## Create a worktree:  make worktree REPO=myapp BRANCH=feat/auth [HOST=x] [ORG=y]
##   If REPO is omitted and CWD is a git repo, auto-detects org/repo from git remote.
worktree:
	@if [ -z "$(REPO)" ]; then \
	  if [ ! -d .git ]; then \
	    echo "Usage: make worktree REPO=<name> BRANCH=<branch> [HOST=<device>] [ORG=<org>]"; \
	    echo "  (or run from inside a git repo to auto-detect)"; exit 1; \
	  fi; \
	  _origin=$$(git remote get-url origin 2>/dev/null || echo ""); \
	  if [ -z "$$_origin" ]; then echo "✗ No git remote found"; exit 1; fi; \
	  _repo=$$(echo "$$_origin" | sed 's|.*[:/]\([^/]*/[^/]*\)\.git$$|\1|;s|.*[:/]\([^/]*/[^/]*\)$$|\1|'); \
	  _auto_org=$$(echo "$$_repo" | cut -d/ -f1); \
	  _auto_name=$$(echo "$$_repo" | cut -d/ -f2); \
	  if [ -z "$(BRANCH)" ]; then echo "Usage: make worktree BRANCH=<branch> (REPO auto-detected: $$_auto_name)"; exit 1; fi; \
	  echo "── Auto-detected: org=$$_auto_org repo=$$_auto_name ──"; \
	  REPO_DIR=$$(pwd) ACTION=create BRANCH=$(BRANCH) bash $(CURDIR)/scripts/repos/worktree.sh; \
	else \
	  if [ -z "$(BRANCH)" ]; then echo "Usage: make worktree REPO=<name> BRANCH=<branch>"; exit 1; fi; \
	  if [ -n "$(HOST)" ]; then \
	    eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	    if [ "$${RESOLVED_USER}" = "root" ]; then REMOTE_HOME="/root"; else REMOTE_HOME="/home/$${RESOLVED_USER}"; fi; \
	    REMOTE_BASE="$${REMOTE_HOME}/tenai-projects"; \
	    REMOTE_REPO="$${REMOTE_BASE}/$(if $(ORG),$(ORG)/)$(REPO)"; \
	    ssh -p $${RESOLVED_SSH_PORT:-22} $${RESOLVED_USER}@$${RESOLVED_IP} \
	      "cd ~/$(INFRA_REPO) && REPO_DIR=$${REMOTE_REPO} ACTION=create BRANCH=$(BRANCH) bash scripts/repos/worktree.sh" < /dev/null; \
	  else \
	    REPO_DIR=$(BASE_DIR)/$(REPO) ACTION=create BRANCH=$(BRANCH) bash scripts/repos/worktree.sh; \
	  fi; \
	fi

## Create worktree + dispatch agent:  make dispatch REPO=x BRANCH=feat/y TASK="..." [HOST=z] [ORG=o] [CLI=gemini]
##   If REPO is omitted and CWD is a git repo, auto-detects org/repo from git remote.
##   If BRANCH is omitted but TASK is set, auto-generates branch as task/<slugified-title>.
dispatch:
	@if [ -z "$(REPO)" ]; then \
	  if [ ! -d .git ]; then \
	    echo "Usage: make dispatch REPO=<name> BRANCH=<branch> [TASK='...'] [HOST=<device>] [CLI=claude|gemini|codex]"; \
	    echo "  (or run from inside a git repo to auto-detect)"; exit 1; \
	  fi; \
	  _origin=$$(git remote get-url origin 2>/dev/null || echo ""); \
	  if [ -z "$$_origin" ]; then echo "✗ No git remote found"; exit 1; fi; \
	  _repo=$$(echo "$$_origin" | sed 's|.*[:/]\([^/]*/[^/]*\)\.git$$|\1|;s|.*[:/]\([^/]*/[^/]*\)$$|\1|'); \
	  _auto_org=$$(echo "$$_repo" | cut -d/ -f1); \
	  _auto_name=$$(echo "$$_repo" | cut -d/ -f2); \
	  _branch="$(BRANCH)"; \
	  if [ -z "$$_branch" ] && [ -z "$(TASK)" ]; then echo "Usage: make dispatch BRANCH=<branch> or TASK='...' (REPO auto-detected: $$_auto_name)"; exit 1; fi; \
	  echo "── Auto-detected: org=$$_auto_org repo=$$_auto_name ──"; \
	  REPO_DIR=$$(pwd) ACTION=dispatch BRANCH="$$_branch" TASK="$(or $(TASK),)" AGENT_CLI=$(or $(CLI),claude) bash $(CURDIR)/scripts/repos/worktree.sh; \
	else \
	  if [ -z "$(BRANCH)" ] && [ -z "$(TASK)" ]; then \
	    echo "Usage: make dispatch REPO=<name> BRANCH=<branch> [TASK='...'] [CLI=claude|gemini|codex]"; exit 1; fi; \
	  if [ -n "$(HOST)" ]; then \
	    eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	    if [ "$${RESOLVED_USER}" = "root" ]; then REMOTE_HOME="/root"; else REMOTE_HOME="/home/$${RESOLVED_USER}"; fi; \
	    REMOTE_BASE="$${REMOTE_HOME}/tenai-projects"; \
	    REMOTE_REPO="$${REMOTE_BASE}/$(if $(ORG),$(ORG)/)$(REPO)"; \
	    ssh -t -p $${RESOLVED_SSH_PORT:-22} $${RESOLVED_USER}@$${RESOLVED_IP} \
	      "cd ~/$(INFRA_REPO) && REPO_DIR=$${REMOTE_REPO} ACTION=dispatch BRANCH=$(BRANCH) TASK='$(or $(TASK),)' AGENT_CLI=$(or $(CLI),claude) bash scripts/repos/worktree.sh" < /dev/null; \
	  else \
	    REPO_DIR=$(BASE_DIR)/$(REPO) ACTION=dispatch BRANCH=$(BRANCH) TASK="$(or $(TASK),)" AGENT_CLI=$(or $(CLI),claude) bash scripts/repos/worktree.sh; \
	  fi; \
	fi

## Alias for dispatch — local worktree + agent:  make tmux-worktree TASK="..." [BRANCH=x] [CLI=claude]
tmux-worktree: dispatch

## List worktrees for a repo:  make list-worktrees REPO=x [HOST=y] [ORG=z]
list-worktrees:
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  if [ "$${RESOLVED_USER}" = "root" ]; then REMOTE_HOME="/root"; else REMOTE_HOME="/home/$${RESOLVED_USER}"; fi; \
	  REMOTE_BASE="$${REMOTE_HOME}/tenai-projects"; \
	  REMOTE_REPO="$${REMOTE_BASE}/$(if $(ORG),$(ORG)/)$(or $(REPO),.)"; \
	  ssh -p $${RESOLVED_SSH_PORT:-22} $${RESOLVED_USER}@$${RESOLVED_IP} \
	    "cd ~/$(INFRA_REPO) && REPO_DIR=$${REMOTE_REPO} ACTION=list bash scripts/repos/worktree.sh" < /dev/null; \
	else \
	  REPO_DIR=$(BASE_DIR)/$(or $(REPO),.) ACTION=list bash scripts/repos/worktree.sh; \
	fi

## Remove merged worktrees:  make clean-worktrees REPO=x
clean-worktrees:
	@if [ -z "$(REPO)" ]; then echo "Usage: make clean-worktrees REPO=<name>"; exit 1; fi
	@BASE_DIR=$(BASE_DIR) ACTION=clean-worktrees REPO_DIR=$(BASE_DIR)/$(REPO) \
	  bash scripts/repos/manage.sh

## Clean build artifacts:  make clean-artifacts REPO=x
clean-artifacts:
	@if [ -z "$(REPO)" ]; then echo "Usage: make clean-artifacts REPO=<name>"; exit 1; fi
	@BASE_DIR=$(BASE_DIR) ACTION=clean-artifacts REPO_DIR=$(BASE_DIR)/$(REPO) \
	  bash scripts/repos/manage.sh

# ══════════════════════════════════════════════════════════════════════════════
# TMUX SESSION MANAGEMENT
# ══════════════════════════════════════════════════════════════════════════════

## List all tmux sessions:  make tmux-list [HOST=x|all]
tmux-list:
	$(ensure_venv)
	@if [ -n "$(HOST)" ]; then \
	  if [ "$(HOST)" = "all" ]; then \
	    $(PYTHON) -c "import yaml; \
	      import sys; sys.path.insert(0,'.'); from scripts.lib.load_config import load_config; cfg=load_config(); \
	      devs=cfg.get('tailscale',{}).get('devices',{}); \
	      [print(f\"{n} {d.get('user','ubuntu')} {d.get('ip','')}\") for n,d in devs.items()]" 2>/dev/null | \
	    while read dname duser dip; do \
	      echo "── $$dname ($$dip) ──"; \
	      ssh -o BatchMode=yes -o ConnectTimeout=5 $$duser@$$dip "tmux ls 2>/dev/null || echo '  (none)'" 2>/dev/null || \
	        echo "  ⚠ offline"; \
	    done; \
	  else \
	    _user=$$($(PYTHON) -c "import sys; sys.path.insert(0,'.'); from scripts.lib.load_config import load_config; d=load_config(); print(d.get('tailscale',{}).get('devices',{}).get('$(HOST)',{}).get('user','ubuntu'))" 2>/dev/null || echo ubuntu); \
	    _ip=$$($(PYTHON) -c "import sys; sys.path.insert(0,'.'); from scripts.lib.load_config import load_config; d=load_config(); print(d.get('tailscale',{}).get('devices',{}).get('$(HOST)',{}).get('ip','$(HOST)'))" 2>/dev/null || echo "$(HOST)"); \
	    ssh -o BatchMode=yes $$_user@$$_ip "tmux ls 2>/dev/null || echo 'No tmux sessions'"; \
	  fi; \
	else \
	  tmux ls 2>/dev/null || echo "No tmux sessions"; \
	fi

## Kill ALL tmux sessions (nuclear):  make tmux-kill-all [HOST=x|all]
tmux-kill-all:
	$(ensure_venv)
	@echo "⚠  Killing ALL tmux sessions..."
	@if [ -n "$(HOST)" ]; then \
	  if [ "$(HOST)" = "all" ]; then \
	    $(PYTHON) -c "import yaml; \
	      import sys; sys.path.insert(0,'.'); from scripts.lib.load_config import load_config; cfg=load_config(); \
	      devs=cfg.get('tailscale',{}).get('devices',{}); \
	      [print(f\"{n} {d.get('user','ubuntu')} {d.get('ip','')}\") for n,d in devs.items()]" 2>/dev/null | \
	    while read dname duser dip; do \
	      echo "── $$dname ──"; \
	      ssh -o BatchMode=yes -o ConnectTimeout=5 $$duser@$$dip "tmux kill-server 2>/dev/null; echo '  ✓ killed'" 2>/dev/null || \
	        echo "  ⚠ offline"; \
	    done; \
	  else \
	    _user=$$($(PYTHON) -c "import sys; sys.path.insert(0,'.'); from scripts.lib.load_config import load_config; d=load_config(); print(d.get('tailscale',{}).get('devices',{}).get('$(HOST)',{}).get('user','ubuntu'))" 2>/dev/null || echo ubuntu); \
	    _ip=$$($(PYTHON) -c "import sys; sys.path.insert(0,'.'); from scripts.lib.load_config import load_config; d=load_config(); print(d.get('tailscale',{}).get('devices',{}).get('$(HOST)',{}).get('ip','$(HOST)'))" 2>/dev/null || echo "$(HOST)"); \
	    ssh -o BatchMode=yes $$_user@$$_ip "tmux kill-server 2>/dev/null; echo '✓ All sessions killed'"; \
	  fi; \
	else \
	  tmux kill-server 2>/dev/null; echo "✓ All sessions killed"; \
	fi

## Kill stale tmux sessions (keeps main):  make tmux-clean [HOST=x|all]
tmux-clean:
	$(ensure_venv)
	@echo "Cleaning stale tmux sessions (keeping 'main')..."
	@if [ -n "$(HOST)" ]; then \
	  if [ "$(HOST)" = "all" ]; then \
	    $(PYTHON) -c "import yaml; \
	      import sys; sys.path.insert(0,'.'); from scripts.lib.load_config import load_config; cfg=load_config(); \
	      devs=cfg.get('tailscale',{}).get('devices',{}); \
	      [print(f\"{n} {d.get('user','ubuntu')} {d.get('ip','')}\") for n,d in devs.items()]" 2>/dev/null | \
	    while read dname duser dip; do \
	      echo "── $$dname ──"; \
	      ssh -o BatchMode=yes -o ConnectTimeout=5 $$duser@$$dip 'for s in $$(tmux ls -F "#{session_name}" 2>/dev/null); do \
	        [ "$$s" = "main" ] && continue; \
	        tmux kill-session -t "$$s" 2>/dev/null && echo "  ✗ $$s"; \
	      done; echo "  ✓ done"' 2>/dev/null || echo "  ⚠ offline"; \
	    done; \
	  else \
	    _user=$$($(PYTHON) -c "import sys; sys.path.insert(0,'.'); from scripts.lib.load_config import load_config; d=load_config(); print(d.get('tailscale',{}).get('devices',{}).get('$(HOST)',{}).get('user','ubuntu'))" 2>/dev/null || echo ubuntu); \
	    _ip=$$($(PYTHON) -c "import sys; sys.path.insert(0,'.'); from scripts.lib.load_config import load_config; d=load_config(); print(d.get('tailscale',{}).get('devices',{}).get('$(HOST)',{}).get('ip','$(HOST)'))" 2>/dev/null || echo "$(HOST)"); \
	    ssh -o BatchMode=yes $$_user@$$_ip 'for s in $$(tmux ls -F "#{session_name}" 2>/dev/null); do \
	      [ "$$s" = "main" ] && continue; \
	      tmux kill-session -t "$$s" 2>/dev/null && echo "  ✗ $$s"; \
	    done; echo "✓ Cleanup done (kept main)"'; \
	  fi; \
	else \
	  for s in $$(tmux ls -F "#{session_name}" 2>/dev/null); do \
	    [ "$$s" = "main" ] && continue; \
	    tmux kill-session -t "$$s" 2>/dev/null && echo "  ✗ $$s"; \
	  done; echo "✓ Cleanup done (kept main)"; \
	fi

# ══════════════════════════════════════════════════════════════════════════════
# MERGE SAFETY — validation and conflict prevention for parallel worktrees
# ══════════════════════════════════════════════════════════════════════════════

define run_merge_safety
	@if [ -z "$(REPO)" ]; then echo "Usage: make $@ REPO=<name> [HOST=<device>] [ORG=<org>]"; exit 1; fi
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  if [ "$${RESOLVED_USER}" = "root" ]; then REMOTE_HOME="/root"; else REMOTE_HOME="/home/$${RESOLVED_USER}"; fi; \
	  REMOTE_BASE="$${REMOTE_HOME}/tenai-projects"; \
	  ssh -t -p $${RESOLVED_SSH_PORT:-22} $${RESOLVED_USER}@$${RESOLVED_IP} \
	    "cd ~/$(INFRA_REPO) && REPO_DIR=$${REMOTE_BASE}/$(if $(ORG),$(ORG)/)$(REPO) ACTION=$(1) bash scripts/repos/merge_safety.sh" < /dev/null; \
	else \
	  REPO_DIR=$(BASE_DIR)/$(REPO) ACTION=$(1) bash scripts/repos/merge_safety.sh; \
	fi
endef

## Validate all worktrees:  make validate-worktrees REPO=x [HOST=y]
validate-worktrees:
	$(call run_merge_safety,validate-worktrees)

## Check file overlap between branches:  make check-conflicts REPO=x [HOST=y]
check-conflicts:
	$(call run_merge_safety,check-conflicts)

## Integration test (merge all → test branch → validate):  make integration-test REPO=x [HOST=y]
integration-test:
	$(call run_merge_safety,integration-test)

## Sequential merge with validation:  make merge-sequential REPO=x [HOST=y]
merge-sequential:
	$(call run_merge_safety,sequential-merge)

# ══════════════════════════════════════════════════════════════════════════════
# SKILLS — single source of truth in .agents/skills/
# ══════════════════════════════════════════════════════════════════════════════

## Sync skills symlinks:  make skills-sync
##   Creates/refreshes symlinks from .claude/.gemini/.codex/skills/ → .agents/skills/
skills-sync:
	@echo "── Syncing skills from .agents/skills/ ──"
	@for cli_dir in .claude/skills .gemini/skills .codex/skills; do \
	  mkdir -p $$cli_dir; \
	  for skill in .agents/skills/*/; do \
	    name=$$(basename "$$skill"); \
	    target="../../.agents/skills/$$name"; \
	    link="$$cli_dir/$$name"; \
	    if [ -L "$$link" ]; then rm "$$link"; fi; \
	    if [ -d "$$link" ]; then rm -rf "$$link"; fi; \
	    ln -s "$$target" "$$link"; \
	    echo "  $$link → $$target"; \
	  done; \
	done
	@echo "✓ Skills synced"

# ══════════════════════════════════════════════════════════════════════════════
# LINT & TEST — tenai-infra's own test suite
# ══════════════════════════════════════════════════════════════════════════════

## Run ruff linter:  make lint
lint:
	@$(PYTHON) -m ruff check scripts/ webapp/ tests/

## Run pytest suite:  make test
test:
	@$(PYTHON) -m pytest tests/ -x -q --tb=short

# ══════════════════════════════════════════════════════════════════════════════
# CI — validation loop and webhook
# ══════════════════════════════════════════════════════════════════════════════

## Run validation suite:  make validate [REPO=x] [HOST=y] [ORG=z]
validate:
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  if [ "$${RESOLVED_USER}" = "root" ]; then REMOTE_HOME="/root"; else REMOTE_HOME="/home/$${RESOLVED_USER}"; fi; \
	  REMOTE_BASE="$${REMOTE_HOME}/tenai-projects"; \
	  REMOTE_REPO="$${REMOTE_BASE}/$(if $(ORG),$(ORG)/)$(or $(REPO),.)"; \
	  echo "── Validating on $${RESOLVED_NAME}: $(or $(REPO),.) ──"; \
	  ssh -p $${RESOLVED_SSH_PORT:-22} $${RESOLVED_USER}@$${RESOLVED_IP} \
	    "cd ~/$(INFRA_REPO) && REPO_DIR=$${REMOTE_REPO} ACTION=validate bash scripts/conductor/ci_loop.sh" < /dev/null; \
	else \
	  REPO_DIR=$(or $(and $(REPO),$(BASE_DIR)/$(REPO)),$(PWD)) ACTION=validate \
	    bash scripts/conductor/ci_loop.sh; \
	fi

## Generate GitHub Actions CI workflow:  make ci-workflow [REPO=x]
ci-workflow:
	@REPO_DIR=$(or $(and $(REPO),$(BASE_DIR)/$(REPO)),$(PWD)) ACTION=gen-workflow \
	  bash scripts/conductor/ci_loop.sh

## Start webhook listener daemon (watches ntfy.sh topic, resumes agents)
ci-daemon:
	@echo "── Starting CI webhook listener daemon ──"
	@echo "   Topic: ntfy.sh/$${NTFY_TOPIC:-<set NTFY_TOPIC in .env>}"
	@REPO_DIR=$(PWD) ACTION=daemon bash scripts/conductor/ci_loop.sh

## Poll PR for reviews:  make poll-reviews [PR=123] [TIMEOUT=300] [INTERVAL=30] [EXCLUDE=bot1,bot2]
poll-reviews:
	@bash scripts/conductor/poll_pr_reviews.sh \
	  $(if $(PR),--pr $(PR),) \
	  $(if $(TIMEOUT),--timeout $(TIMEOUT),) \
	  $(if $(INTERVAL),--interval $(INTERVAL),) \
	  $(if $(EXCLUDE),--exclude '$(EXCLUDE)',) \
	  $(if $(NTFY_TOPIC),--ntfy-topic $(NTFY_TOPIC),) \
	  $(if $(filter 1,$(VERBOSE)),--verbose,)

## Show CI run history
ci-history:
	@ACTION=history bash scripts/conductor/ci_loop.sh

## Start agent watcher daemon (polls GitHub for CI/reviews):  make agent-watcher [INTERVAL=30]
agent-watcher:
	@echo "── Starting Agent Watcher daemon ──"
	@$(PYTHON) scripts/conductor/agent_watcher.py --watch $(if $(INTERVAL),--interval $(INTERVAL),)

## One-shot check for pending reviews/CI:  make agent-watcher-check
agent-watcher-check:
	@$(PYTHON) scripts/conductor/agent_watcher.py --check

## Show agent watcher state:  make agent-watcher-status
agent-watcher-status:
	@$(PYTHON) scripts/conductor/agent_watcher.py --status

## Monitor agent sessions for completion:  make monitor-agents [REPO=x] [HOST=y]
monitor-agents:
	@if [ -n "$(HOST)" ]; then \
	  $(call ssh_cmd,$(HOST),$(PYTHON) $(CURDIR)/scripts/conductor/monitor_agents.py --watch $(if $(REPO),--repo $(REPO),)); \
	else \
	  $(PYTHON) scripts/conductor/monitor_agents.py --watch $(if $(REPO),--repo $(REPO),); \
	fi

## GitHub Issues adapter:  make github-issues REPO=x ORG=y [ACTION=list|to-tasks|from-tasks]
##   ACTION=list (default), to-tasks, from-tasks PATH=TASKS.md
github-issues:
	@if [ -z "$(REPO)" ] || [ -z "$(ORG)" ]; then echo "Usage: make github-issues REPO=x ORG=y [ACTION=list]"; exit 1; fi
	@GH_ACTION=$(or $(ACTION),list); \
	case $$GH_ACTION in \
	  list)       $(PYTHON) scripts/conductor/github_issues.py "$(ORG)/$(REPO)" --list ;; \
	  to-tasks)   $(PYTHON) scripts/conductor/github_issues.py "$(ORG)/$(REPO)" --to-tasks ;; \
	  from-tasks) $(PYTHON) scripts/conductor/github_issues.py "$(ORG)/$(REPO)" --from-tasks $(or $(PATH),$(BASE_DIR)/$(REPO)/TASKS.md) ;; \
	  *) echo "Unknown ACTION: $$GH_ACTION (use: list, to-tasks, from-tasks)"; exit 1 ;; \
	esac

## Install Symphony Elixir orchestrator:  make install-symphony
install-symphony:
	@INSTALL_ONLY=symphony bash scripts/install/tools.sh

## Install Gastown session manager:  make install-gastown
install-gastown:
	@INSTALL_ONLY=gastown bash scripts/install/tools.sh

## Show agent session history:  make agent-history REPO=x [HOST=y] [FORMAT=json|summary]
agent-history:
	@if [ -z "$(REPO)" ]; then echo "Usage: make agent-history REPO=<name> [HOST=y]"; exit 1; fi
	@if [ -n "$(HOST)" ]; then \
	  $(call ssh_cmd,$(HOST),$(PYTHON) $(CURDIR)/scripts/conductor/session_history.py $(BASE_DIR)/$(REPO) $(if $(filter json,$(FORMAT)),--json,) $(if $(filter summary,$(FORMAT)),--summary,)); \
	else \
	  $(PYTHON) scripts/conductor/session_history.py $(BASE_DIR)/$(REPO) $(if $(filter json,$(FORMAT)),--json,) $(if $(filter summary,$(FORMAT)),--summary,); \
	fi

## Full orchestrator loop:  make orchestrate REPO=x [CLI=claude] [HOST=y] [GH_REPO=org/repo] [IDS=5,12] [PATTERN=auth] [ONE_SHOT=1]
orchestrate:
	@if [ -z "$(REPO)" ]; then echo "Usage: make orchestrate REPO=<name> [CLI=claude] [HOST=y] [IDS=5] [PATTERN=auth] [ONE_SHOT=1]"; exit 1; fi
	@$(PYTHON) scripts/conductor/orchestrator.py \
	  --repo-dir $(BASE_DIR)/$(REPO) \
	  --cli $(or $(CLI),claude) \
	  $(if $(HOST),--host $(HOST),) \
	  $(if $(GH_REPO),--github-repo $(GH_REPO),) \
	  $(if $(IDS),--task-ids $(IDS),) \
	  $(if $(PATTERN),--pattern '$(PATTERN)',) \
	  $(if $(filter 1,$(ONE_SHOT)),--one-shot,--loop)

## Webhook listener for remote task dispatch:  make orchestrate-webhook [NTFY_TOPIC=x] [REPO=x]
orchestrate-webhook:
	@$(PYTHON) scripts/conductor/orchestrator.py \
	  --repo-dir $(or $(and $(REPO),$(BASE_DIR)/$(REPO)),$(PWD)) \
	  --ntfy-topic $(or $(NTFY_TOPIC),$${NTFY_TOPIC:-tenacious-orchestrator}) \
	  --webhook

## Delete tasks by ID list or title regex:  make task-delete IDS=1,2,3 | PATTERN="test.*ssh" [REPO=x] [HOST=y]
##   Options: DRY_RUN=1 (preview), FORCE=1 (skip confirmation), STATUS=active
task-delete:
	$(ensure_venv)
	@if [ -z "$(IDS)" ] && [ -z '$(PATTERN)' ]; then \
	  echo "Usage: make task-delete IDS=1,2,3 | PATTERN='regex' [REPO=x] [HOST=y] [DRY_RUN=1] [FORCE=1]"; exit 1; \
	fi; \
	if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  echo "── Deleting tasks on $${RESOLVED_NAME} ──"; \
	  ssh -p $${RESOLVED_SSH_PORT:-22} "$${RESOLVED_USER}@$${RESOLVED_IP}" \
	    "cd ~/$(INFRA_REPO) && make task-delete \
	      $(if $(IDS),IDS='$(IDS)',) \
	      $(if $(PATTERN),PATTERN='$(PATTERN)',) \
	      $(if $(REPO),REPO='$(REPO)',) \
	      $(if $(STATUS),STATUS='$(STATUS)',) \
	      $(if $(DRY_RUN),DRY_RUN='$(DRY_RUN)',) \
	      $(if $(FORCE),FORCE='$(FORCE)',)"; \
	else \
	  _ARGS=""; \
	  if [ -n "$(IDS)" ]; then _ARGS="$$_ARGS --ids $(IDS)"; fi; \
	  if [ -n '$(PATTERN)' ]; then _ARGS="$$_ARGS --pattern '$(PATTERN)'"; fi; \
	  if [ -n "$(REPO)" ]; then _ARGS="$$_ARGS --repo $(REPO)"; fi; \
	  if [ -n "$(STATUS)" ]; then _ARGS="$$_ARGS --status $(STATUS)"; fi; \
	  if [ "$(DRY_RUN)" = "1" ]; then _ARGS="$$_ARGS --dry-run"; fi; \
	  if [ "$(FORCE)" = "1" ]; then _ARGS="$$_ARGS --force"; fi; \
	  $(PYTHON) scripts/conductor/task_db.py delete $$_ARGS; \
	fi

## Sync task DB from a remote device:  make task-sync HOST=x
task-sync:
	@if [ -z "$(HOST)" ]; then echo "Usage: make task-sync HOST=<device>"; exit 1; fi
	@eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	 if [ "$${RESOLVED_USER}" = "root" ]; then REMOTE_HOME="/root"; else REMOTE_HOME="/home/$${RESOLVED_USER}"; fi; \
	 LOCAL_DIR="$(HOME)/.tenai/sync/$${RESOLVED_NAME}"; \
	 mkdir -p "$$LOCAL_DIR"; \
	 echo "── Syncing task DB from $${RESOLVED_NAME} ──"; \
	 scp -P $${RESOLVED_SSH_PORT:-22} \
	   "$${RESOLVED_USER}@$${RESOLVED_IP}:$${REMOTE_HOME}/.tenai/tenai.db" \
	   "$${RESOLVED_USER}@$${RESOLVED_IP}:$${REMOTE_HOME}/.tenai/tenai.db-wal" \
	   "$${RESOLVED_USER}@$${RESOLVED_IP}:$${REMOTE_HOME}/.tenai/tenai.db-shm" \
	   "$$LOCAL_DIR/" 2>/dev/null; \
	 echo "  ✓ Synced → $$LOCAL_DIR/tenai.db (+ WAL/SHM)" || \
	 echo "  ✗ No DB found on $${RESOLVED_NAME} (or SSH failed)"

# Helper: for READ operations — sync remote DB dir to local read-only copy
# Usage: $(call _resolve_db) && TENAI_DB_DIR=$$_DB_DIR $(PYTHON) ...
# NOTE: synced copies are READ-ONLY. Write operations use SSH to run on the device.
define _resolve_db
if [ -n "$(HOST)" ]; then \
  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
  if [ "$${RESOLVED_USER}" = "root" ]; then REMOTE_HOME="/root"; else REMOTE_HOME="/home/$${RESOLVED_USER}"; fi; \
  _DB_DIR="$(HOME)/.tenai/sync/$${RESOLVED_NAME}"; \
  mkdir -p "$$_DB_DIR/devices"; \
  scp -q -P $${RESOLVED_SSH_PORT:-22} \
    "$${RESOLVED_USER}@$${RESOLVED_IP}:$${REMOTE_HOME}/.tenai/tenai.db" \
    "$${RESOLVED_USER}@$${RESOLVED_IP}:$${REMOTE_HOME}/.tenai/tenai.db-wal" \
    "$${RESOLVED_USER}@$${RESOLVED_IP}:$${REMOTE_HOME}/.tenai/tenai.db-shm" \
    "$$_DB_DIR/" 2>/dev/null || true; \
  scp -q -r -P $${RESOLVED_SSH_PORT:-22} \
    "$${RESOLVED_USER}@$${RESOLVED_IP}:$${REMOTE_HOME}/.tenai/devices/" \
    "$$_DB_DIR/devices/" 2>/dev/null || true; \
  echo "  ↓ Synced DB from $${RESOLVED_NAME} (read-only)"; \
else \
  _DB_DIR="$(HOME)/.tenai"; \
fi
endef



## Add a task to the database:  make task-add REPO=x TITLE="..." [BRANCH=b] [HOST=y]
##   HOST = write executes on the remote device via SSH (device owns its DB)
task-add:
	$(ensure_venv)
	@if [ -z "$(REPO)" ] || [ -z "$(TITLE)" ]; then echo "Usage: make task-add REPO=<name> TITLE='...' [BRANCH=b] [HOST=y]"; exit 1; fi
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  echo "── Adding task on $${RESOLVED_NAME} ──"; \
	  ssh -p $${RESOLVED_SSH_PORT:-22} "$${RESOLVED_USER}@$${RESOLVED_IP}" \
	    "cd ~/$(INFRA_REPO) && make task-add \
	      REPO='$(REPO)' TITLE='$(TITLE)' \
	      $(if $(BRANCH),BRANCH='$(BRANCH)',) \
	      $(if $(ORG),ORG='$(ORG)',) \
	      $(if $(CONTEXT_TYPE),CONTEXT_TYPE='$(CONTEXT_TYPE)',) \
	      $(if $(CONTEXT_REF),CONTEXT_REF='$(CONTEXT_REF)',)" < /dev/null; \
	else \
	  $(PYTHON) scripts/conductor/task_db.py add \
	    --repo $(REPO) --title '$(TITLE)' \
	    $(if $(BRANCH),--branch $(BRANCH),) \
	    $(if $(ORG),--org $(ORG),) \
	    $(if $(CONTEXT_TYPE),--context-type $(CONTEXT_TYPE),) \
	    $(if $(CONTEXT_REF),--context-ref $(CONTEXT_REF),) \
	    --created-by manual --created-by-cli human; \
	fi

## List tasks from database:  make task-list REPO=x [STATUS=active] [PATTERN=x] [JSON=1] [HOST=y]
task-list:
	@if [ -z "$(REPO)" ]; then echo "Usage: make task-list REPO=<name> [STATUS=active] [PATTERN=x] [HOST=y]"; exit 1; fi
	@$(call _resolve_db) && \
	 TENAI_DB_DIR=$$_DB_DIR $(PYTHON) scripts/conductor/task_db.py $(if $(DEVICE),--device $(DEVICE),) list --repo $(REPO) \
	  $(if $(STATUS),--status $(STATUS),) \
	  $(if $(PATTERN),--pattern '$(PATTERN)',) \
	  $(if $(filter 1,$(JSON)),--json,)

## Render TASKS.md from database:  make tasks REPO=x [HOST=y]
tasks:
	@if [ -z "$(REPO)" ]; then echo "Usage: make tasks REPO=<name> [HOST=y]"; exit 1; fi
	@$(call _resolve_db) && \
	 TENAI_DB_DIR=$$_DB_DIR $(PYTHON) scripts/conductor/task_db.py $(if $(DEVICE),--device $(DEVICE),) render --repo $(REPO)

## Query tasks with rich filters:  make task-query [REPO=x] [STATUS=x] [PATTERN=x] [HOST=y] ...
task-query:
	@$(call _resolve_db) && \
	 TENAI_DB_DIR=$$_DB_DIR $(PYTHON) scripts/conductor/task_db.py $(if $(DEVICE),--device $(DEVICE),) query \
	  $(if $(REPO),--repo $(REPO),) \
	  $(if $(STATUS),--status $(STATUS),) \
	  $(if $(PATTERN),--pattern '$(PATTERN)',) \
	  $(if $(CONTEXT_TYPE),--context-type $(CONTEXT_TYPE),) \
	  $(if $(CREATED_BY),--created-by '$(CREATED_BY)',) \
	  $(if $(SINCE),--since $(SINCE),) \
	  $(if $(UNTIL),--until $(UNTIL),) \
	  $(if $(filter 1,$(JSON)),--json,)

## Register a task (standardized entry):  make task-register REPO=x TITLE="..." [HOST=y] [CLI=claude]
##   HOST = write executes on the remote device via SSH
task-register:
	$(ensure_venv)
	@if [ -z "$(REPO)" ] || [ -z "$(TITLE)" ]; then echo "Usage: make task-register REPO=<name> TITLE='...' [BRANCH=b] [CLI=claude] [HOST=y]"; exit 1; fi
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  echo "── Registering task on $${RESOLVED_NAME} ──"; \
	  ssh -p $${RESOLVED_SSH_PORT:-22} "$${RESOLVED_USER}@$${RESOLVED_IP}" \
	    "cd ~/$(INFRA_REPO) && make task-register \
	      REPO='$(REPO)' TITLE='$(TITLE)' \
	      $(if $(BRANCH),BRANCH='$(BRANCH)',) \
	      $(if $(CLI),CLI='$(CLI)',) \
	      $(if $(MODEL),MODEL='$(MODEL)',) \
	      $(if $(CONTEXT_REF),CONTEXT_REF='$(CONTEXT_REF)',) \
	      $(if $(CONDUCTOR_TRACK),CONDUCTOR_TRACK='$(CONDUCTOR_TRACK)',) \
	      $(if $(DESCRIPTION),DESCRIPTION='$(DESCRIPTION)',) \
	      $(if $(VERIFICATION),VERIFICATION='$(VERIFICATION)',)" < /dev/null; \
	else \
	  $(PYTHON) scripts/conductor/task_db.py register \
	    --repo $(REPO) --title '$(TITLE)' \
	    $(if $(BRANCH),--branch $(BRANCH),) \
	    $(if $(CLI),--cli $(CLI),) \
	    $(if $(MODEL),--model $(MODEL),) \
	    $(if $(CONTEXT_REF),--context-ref '$(CONTEXT_REF)',) \
	    $(if $(CONDUCTOR_TRACK),--conductor-track $(CONDUCTOR_TRACK),) \
	    $(if $(DESCRIPTION),--description '$(DESCRIPTION)',) \
	    $(if $(VERIFICATION),--verification '$(VERIFICATION)',); \
	fi

## Import TASKS.md into database:  make task-import REPO=x [REPO_FILE=TASKS.md] [FILE=/abs/path] [HOST=y] [ORG=z] [FORCE=1] [UPDATE=1]
##   HOST = import executes on the remote device via SSH (file is already there)
##   ORG  = required for org-scoped repos when using HOST (remote resolves BASE_DIR/ORG/REPO)
##   FILE = absolute path, local only
##   FORCE=1 = always create new (ignore duplicates), UPDATE=1 = update existing tasks
task-import:
	$(ensure_venv)
	@if [ -z "$(REPO)" ]; then echo "Usage: make task-import REPO=<name> [REPO_FILE=TASKS.md] [FILE=path] [HOST=y] [FORCE=1] [UPDATE=1]"; exit 1; fi
	@_REPO_FILE="$(or $(REPO_FILE),TASKS.md)"; \
	 if [ -n "$(HOST)" ]; then \
	   eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	   echo "── Importing tasks on $${RESOLVED_NAME} ──"; \
	   ssh -p $${RESOLVED_SSH_PORT:-22} "$${RESOLVED_USER}@$${RESOLVED_IP}" \
	     "cd ~/$(INFRA_REPO) && make task-import \
	       REPO='$(REPO)' \
	       REPO_FILE='$$_REPO_FILE' \
	       $(if $(ORG),ORG='$(ORG)',) \
	       $(if $(filter 1,$(FORCE)),FORCE=1,) \
	       $(if $(filter 1,$(UPDATE)),UPDATE=1,)" < /dev/null; \
	 elif [ -n "$(FILE)" ]; then \
	   _IMPORT_FLAGS="$(if $(filter 1,$(FORCE)),--force,) $(if $(filter 1,$(UPDATE)),--update,) $(if $(ORG),--org=$(ORG),)"; \
	   if [ ! -f "$(FILE)" ]; then echo "  ✗ Not found: $(FILE)"; exit 1; fi; \
	   $(PYTHON) scripts/conductor/task_db.py import --repo $(REPO) $$_IMPORT_FLAGS "$(FILE)"; \
	 else \
	   _IMPORT_FLAGS="$(if $(filter 1,$(FORCE)),--force,) $(if $(filter 1,$(UPDATE)),--update,) $(if $(ORG),--org=$(ORG),)"; \
	   TASKS_FILE="$(BASE_DIR)/$(if $(ORG),$(ORG)/)$(REPO)/$$_REPO_FILE"; \
	   if [ ! -f "$$TASKS_FILE" ]; then echo "  ✗ Not found: $$TASKS_FILE"; exit 1; fi; \
	   $(PYTHON) scripts/conductor/task_db.py import --repo $(REPO) $$_IMPORT_FLAGS "$$TASKS_FILE"; \
	 fi

## Import from conductor track:  make task-import-track REPO=x [TRACK=y] [HOST=z] [ORG=o]
##   TRACK = specific track ID. If omitted, imports ALL tracks from conductor/tracks/
##   HOST = import executes on the remote device via SSH (track dir is already there)
task-import-track:
	$(ensure_venv)
	@if [ -z "$(REPO)" ]; then echo "Usage: make task-import-track REPO=<name> [TRACK=<track_id>] [HOST=y] [ORG=z]"; exit 1; fi
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  echo "── Importing tracks on $${RESOLVED_NAME} ──"; \
	  ssh -p $${RESOLVED_SSH_PORT:-22} "$${RESOLVED_USER}@$${RESOLVED_IP}" \
	    "cd ~/$(INFRA_REPO) && make task-import-track \
	      REPO='$(REPO)' \
	      $(if $(TRACK),TRACK='$(TRACK)',) \
	      $(if $(ORG),ORG='$(ORG)',)" < /dev/null; \
	else \
	  TRACKS_BASE="$(BASE_DIR)/$(if $(ORG),$(ORG)/)$(REPO)/conductor/tracks"; \
	  if [ -n "$(TRACK)" ]; then \
	    TRACK_DIR="$$TRACKS_BASE/$(TRACK)"; \
	    if [ ! -f "$$TRACK_DIR/plan.md" ]; then echo "  ✗ No plan.md in $$TRACK_DIR"; exit 1; fi; \
	    $(PYTHON) scripts/conductor/task_db.py import-track --repo $(REPO) "$$TRACK_DIR"; \
	  else \
	    if [ ! -d "$$TRACKS_BASE" ]; then echo "  ✗ No conductor/tracks/ dir in $$TRACKS_BASE"; exit 0; fi; \
	    _count=0; \
	    for _track_dir in $$TRACKS_BASE/*/; do \
	      if [ -f "$$_track_dir/plan.md" ]; then \
	        echo "  → Importing track $$(basename $$_track_dir)"; \
	        $(PYTHON) scripts/conductor/task_db.py import-track --repo $(REPO) "$$_track_dir" || true; \
	        _count=$$((_count + 1)); \
	      fi; \
	    done; \
	    if [ "$$_count" -eq 0 ]; then echo "  ✗ No tracks with plan.md found in $$TRACKS_BASE"; fi; \
	  fi; \
	fi

# ══════════════════════════════════════════════════════════════════════════════
# WEB CONTROL APP
# ══════════════════════════════════════════════════════════════════════════════

## Install webapp Python deps (included in standard install-deps)
webapp-install:
	$(ensure_venv)
	@echo "✓ Webapp deps installed"

## Start the browser control panel (local)
webapp: webapp-install
	@echo "── Starting Tenacious Control Plane ──"
	@echo "   URL: http://localhost:$(or $(WEBAPP_PORT),7700)"
	@PYTHONPATH=webapp BASE_DIR=$(BASE_DIR) WEBAPP_PORT=$(or $(WEBAPP_PORT),7700) $(PYTHON) webapp/server.py

## Start webapp in tmux session (detached)
webapp-bg:
	@tmux new-session -d -s tenai-webapp -c $(PWD) \
	  "PYTHONPATH=webapp BASE_DIR=$(BASE_DIR) WEBAPP_PORT=$(or $(WEBAPP_PORT),7700) $(CURDIR)/$(VENV)/bin/python3 webapp/server.py" 2>/dev/null || \
	 echo "Session 'tenai-webapp' already running"
	@echo "✓ Webapp running in tmux session: tenai-webapp"
	@echo "  URL: http://localhost:$(or $(WEBAPP_PORT),7700)"

## Start webapp in Docker
webapp-docker:
	@mkdir -p ~/.tenai && chmod 700 ~/.tenai 2>/dev/null || true
	@if [ -d .env ]; then echo "⚠ .env is a directory — removing"; rm -rf .env; fi
	@[ -f .env ] || touch .env
	@docker compose up -d --build webapp
	@echo "✓ Webapp running in Docker at http://localhost:$${WEBAPP_PORT:-7700}"

## Stop Docker webapp
webapp-docker-stop:
	@docker compose down

## Rebuild Docker image
webapp-docker-build:
	@docker compose build webapp

## Docker webapp logs
webapp-docker-logs:
	@docker compose logs -f webapp

# ══════════════════════════════════════════════════════════════════════════════
# SYSTEM UTILITIES
# ══════════════════════════════════════════════════════════════════════════════
status: ## Show mesh + tmux + repo overview [HOST=x]
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  echo "── Status for $$RESOLVED_NAME ($$RESOLVED_USER@$$RESOLVED_IP) ──"; \
	  ssh -p $${RESOLVED_SSH_PORT:-22} -o ConnectTimeout=10 $$RESOLVED_USER@$$RESOLVED_IP " \
	    echo '── Tailscale ──'; \
	    tailscale status 2>/dev/null || echo 'tailscale not running'; \
	    echo '── tmux sessions ──'; \
	    tmux list-sessions 2>/dev/null || echo '(none)'; \
	    echo '── Disk ──'; \
	    df -h / 2>/dev/null | tail -1; \
	    echo '── Uptime ──'; \
	    uptime 2>/dev/null; \
	    echo '── Docker ──'; \
	    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || echo '(no docker)'; \
	  "; \
	else \
	  echo "── Tailscale ──"; \
	  tailscale status 2>/dev/null || echo "tailscale not running"; \
	  echo "── tmux sessions ──"; \
	  tmux list-sessions 2>/dev/null || echo "(none)"; \
	  echo "── Repos ──"; \
	  BASE_DIR=$(BASE_DIR) ACTION=list bash scripts/repos/manage.sh 2>/dev/null || true; \
	fi

check: ## Verify tools installed [HOST=x]
	@if [ -n "$(HOST)" ]; then \
	  eval $$($(PYTHON) scripts/configure/resolve_host.py $(HOST)); \
	  echo "── Environment check for $$RESOLVED_NAME ($$RESOLVED_USER@$$RESOLVED_IP) ──"; \
	  ssh -p $${RESOLVED_SSH_PORT:-22} -o ConnectTimeout=10 $$RESOLVED_USER@$$RESOLVED_IP " \
	    for tool in tailscale mosh tmux claude gemini node python3 git jq curl; do \
	      if command -v \$$tool >/dev/null 2>&1; then \
	        printf '✓ %-12s %s\n' \$$tool \"\$$(\$$tool --version 2>&1 | head -1)\"; \
	      else \
	        printf '✗ %-12s not found\n' \$$tool; \
	      fi; \
	    done; \
	  "; \
	else \
	  echo "── Environment check ──"; \
	  command -v tailscale && tailscale version || echo "✗ tailscale"; \
	  command -v mosh      && mosh --version 2>&1 | head -1 || echo "✗ mosh"; \
	  command -v tmux      && tmux -V || echo "✗ tmux"; \
	  command -v claude    && claude --version 2>/dev/null || echo "✗ claude-code"; \
	  command -v gemini    && gemini --version 2>/dev/null || echo "✗ gemini-cli"; \
	  command -v node      && node --version || echo "✗ node"; \
	  command -v python3   && python3 --version || echo "✗ python3"; \
	  command -v git       && git --version || echo "✗ git"; \
	  command -v jq        && jq --version || echo "✗ jq"; \
	  command -v curl      && echo "✓ curl" || echo "✗ curl"; \
	fi

clean:
	@rm -rf outputs/ .hydra/ __pycache__/ *.pyc
	@find . -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

# ============================================================
# Shell Completion Setup
# ============================================================
.PHONY: setup-completion
setup-completion: ## Install make tab-completion to your shell rc file
	@COMPLETION_SCRIPT="$(CURDIR)/scripts/utilities/make_completion.sh"; \
	SOURCE_LINE="source \"$$COMPLETION_SCRIPT\"  # tenai make completion"; \
	RC_FILE=""; \
	if [ -n "$$ZSH_VERSION" ] || [ "$$SHELL" = "/bin/zsh" ]; then \
		RC_FILE="$$HOME/.zshrc"; \
	elif [ -n "$$BASH_VERSION" ] || [ "$$SHELL" = "bash" ]; then \
		RC_FILE="$$HOME/.bashrc"; \
	else \
		RC_FILE="$$HOME/.bashrc"; \
	fi; \
	if [ ! -f "$$COMPLETION_SCRIPT" ]; then \
		echo -e "$(RED)Error: Completion script not found: $$COMPLETION_SCRIPT$(NC)"; \
		exit 1; \
	fi; \
	if grep -q "tenai make completion" "$$RC_FILE" 2>/dev/null; then \
		echo -e "$(YELLOW)✓ Already installed in $$RC_FILE$(NC)"; \
	else \
		echo "" >> "$$RC_FILE"; \
		echo "# tenai make completion" >> "$$RC_FILE"; \
		echo "$$SOURCE_LINE" >> "$$RC_FILE"; \
		echo -e "$(GREEN)✓ Added to $$RC_FILE$(NC)"; \
		echo -e "$(BLUE)Run 'source $$RC_FILE' or restart your shell to enable$(NC)"; \
	fi


# ══════════════════════════════════════════════════════════════════════════════
# HELP
# ══════════════════════════════════════════════════════════════════════════════
help:
	@echo ""
	@echo "Tenacious Infra v2 — Available targets"
	@echo "════════════════════════════════════════════════════════"
	@echo ""
	@echo "SETUP (add HOST=<device> to run on a remote device)"
	@echo "  make all                          Full install + configure (local)"
	@echo "  make install [HOST=mydevice]       Install all tools (local or remote)"
	@echo "  make tools [HOST=mydevice]         Install tools only (local or remote)"
	@echo "  make gemini                        Install Gemini CLI"
	@echo "  make configure                     Configure aliases + SSH (local)"
	@echo "  make push-aliases HOST=mydevice    Generate + push aliases to remote device"
	@echo "  make list-tools [HOST=mydevice]     Show all available tools (with skip info)"
	@echo "  make check-tools [HOST=mydevice]    Check which tools are actually installed"
	@echo "  make check                         Verify all tools installed"
	@echo "  make onboard [TYPE=...] [NAME=x]  Guided device onboarding wizard"
	@echo "  make new-server HOST=mydevice      Bootstrap remote device (config-driven)"
	@echo "  make sync HOST=myserver            Sync code to remote (rsync from local)"
	@echo "  make sync HOST=myserver GIT_PULL=1 Sync code to remote (git pull on remote)"
	@echo "  make sync-all                     Sync to all remote devices"
	@echo "  make distribute-keys [HOST=x]     Distribute SSH keys across devices"
	@echo "  make git-ssh [HOST=x] [ORG=y]     Set up GitHub SSH keys (per-org)"
	@echo "  make new-project DIR=/path NAME=n  Scaffold CLAUDE.md + GEMINI.md"
	@echo ""
	@echo "REPOS"
	@echo "  make repos                        List all managed repos"
	@echo "  make clone REPO=git@github.com:…  Clone and scaffold a repo"
	@echo "  make pull REPO=<name>             Pull a specific repo"
	@echo "  make pull-all                     Pull all repos"
	@echo "  make repo-status                  Full git status across all repos"
	@echo ""
	@echo "CONDUCTOR (Gemini task generation — add HOST=<device> for remote)"
	@echo "  make conductor REPO=x [HOST=y]         Start Gemini Conductor for repo"
	@echo "  make conductor-all                     Start conductors for all repos"
	@echo "  make conductor-list [HOST=y]            List active conductor sessions"
	@echo "  make conductor-send REPO=x PROMPT='…'  Send prompt to conductor"
	@echo "  make tasks REPO=x [HOST=y]              Show TASKS.md for repo"
	@echo "  make parse-tasks REPO=x [HOST=y]        Parse TASKS.md (structured view)"
	@echo "  make validate-tasks REPO=x [HOST=y]     Check ATC compliance"
	@echo "  make dispatch-tasks REPO=x [HOST=y]     Auto-dispatch all Active tasks"
	@echo ""
	@echo "WORKTREES & AGENT DISPATCH (add HOST=<device> for remote)"
	@echo "  make worktree REPO=x BRANCH=feat/y [HOST=z]      Create isolated worktree"
	@echo "  make tmux-worktree TASK='...' [CLI=claude]         Local worktree + agent (alias for dispatch)"
	@echo "  make dispatch REPO=x BRANCH=y [HOST=z] [CLI=gemini]  Dispatch agent"
	@echo "  make list-worktrees REPO=x [HOST=y]               List worktrees"
	@echo "  make clean-worktrees REPO=<name>        Remove merged worktrees"
	@echo "  make clean-artifacts REPO=<name>        Clean build artifacts"
	@echo ""
	@echo "MERGE SAFETY (add HOST=<device> for remote)"
	@echo "  make validate-worktrees REPO=x [HOST=y]  Validate all worktrees"
	@echo "  make check-conflicts REPO=x [HOST=y]     Check for file overlap"
	@echo "  make integration-test REPO=x [HOST=y]    Merge all → test branch → validate"
	@echo "  make merge-sequential REPO=x [HOST=y]    Merge one-by-one with validation"
	@echo ""
	@echo "LINT & TEST (tenai-infra)"
	@echo "  make lint                         Run ruff linter on Python code"
	@echo "  make test                         Run pytest suite (unit + integration)"
	@echo ""
	@echo "CI VALIDATION (target repos — add HOST=<device> for remote)"
	@echo "  make validate [REPO=x] [HOST=y]   Run lint + test suite"
	@echo "  make ci-workflow [REPO=\<name\>]    Generate GitHub Actions workflow"
	@echo "  make ci-daemon                    Start webhook listener daemon"
	@echo "  make ci-history                   Show recent CI run log"
	@echo ""
	@echo "AGENT MONITORING & GITHUB INTEGRATION"
	@echo "  make monitor-agents [REPO=x] [HOST=y]    Watch agents, notify on completion"
	@echo "  make github-issues REPO=x ORG=y [ACTION=list]  GitHub Issues ↔ TASKS.md"
	@echo "  make install-symphony             Install Symphony Elixir orchestrator"
	@echo "  make install-gastown              Install Gastown session manager"
	@echo "  make agent-history REPO=x [HOST=y] [FORMAT=json|summary]  Session history"
	@echo "  make orchestrate REPO=x [CLI=claude] [HOST=y]  Full orchestrator loop"
	@echo "  make orchestrate-webhook [NTFY_TOPIC=x]    Listen for ntfy triggers"
	@echo "  make task-add REPO=x TITLE='...'             Add task to database"
	@echo "  make task-list REPO=x [STATUS=x] [JSON=1] [HOST=y]  List tasks"
	@echo "  make task-query [REPO=x] [PATTERN=x] [HOST=y]  Rich query (filters)"
	@echo "  make task-register REPO=x TITLE='...' [HOST=y]  Register (standardized)"
	@echo "  make task-import REPO=x [REPO_FILE=x] [HOST=y]    Import TASKS.md into DB"
	@echo "  make task-import-track REPO=x [TRACK=y] [HOST=z]  Import conductor track(s)"
	@echo "  make task-sync HOST=x                          Sync remote DB to local"
	@echo "  make tasks REPO=x [HOST=y]                     Render TASKS.md from DB"
	@echo ""
	@echo "WEB CONTROL APP"
	@echo "  make webapp                       Start browser control panel (local)"
	@echo "  make webapp-bg                    Start webapp in tmux (background)"
	@echo "  make webapp-docker                Start webapp in Docker container"
	@echo "  make webapp-docker-stop           Stop Docker webapp"
	@echo "  make webapp-docker-build          Rebuild Docker image"
	@echo "  make webapp-docker-logs           Follow Docker webapp logs"
	@echo "  make vt-server [HOST=x] [PORT=4020]  Start VibeTunnel server (tmux)"
	@echo ""
	@echo "CLI CONFIGURATION (config/cli/)"
	@echo "  make cli-setup [HOST=x|all] [CLI=gemini|claude]             Install all CLI config"
	@echo "  make cli-extensions [HOST=x|all] [CLI=gemini|claude]        Install extensions"
	@echo "  make cli-mcp [HOST=x|all] [CLI=claude]                      Install MCP servers"
	@echo "  make cli-plugins [HOST=x|all] [CLI=claude]                  Install plugins"
	@echo "  make cli-skills [HOST=x|all] [CLI=gemini|claude]            Copy local skill files"
	@echo "  make cli-vercel-skills [HOST=x|all] [CLI=gemini|claude]     Install Vercel skills (cross-CLI)"
	@echo "  make cli-settings [HOST=x|all] [CLI=gemini|claude]          Merge settings.json"
	@echo "  make cli-rules [HOST=x|all] [CLI=gemini|claude]             Copy global rules"
	@echo "  make cli-list [HOST=x] [CLI=gemini|claude]                  List installed assets"
	@echo "  make cli-install CLI=x TYPE=y EXT=z [HOST=x]               Install single asset"
	@echo ""
	@echo "TMUX SESSIONS"
	@echo "  make tmux-list [HOST=x|all]        List all tmux sessions"
	@echo "  make tmux-clean [HOST=x|all]       Kill stale sessions (keeps 'main')"
	@echo "  make tmux-kill-all [HOST=x|all]    Kill ALL tmux sessions (nuclear)"
	@echo ""
	@echo "SYSTEM"
	@echo "  make status                       Tailscale + tmux + repo overview"
	@echo "  make clean                        Remove build artifacts"
	@echo ""
	@echo "Override BASE_DIR:  make repos BASE_DIR=/custom/path"
	@echo "Override any config:  python setup.py tailscale.devices.myserver.ip=x.x.x.x"
	@echo ""
