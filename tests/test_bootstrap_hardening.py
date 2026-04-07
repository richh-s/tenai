# tests/test_bootstrap_hardening.py
"""
Regression tests for venv bootstrap hardening.
These tests enforce that no Makefile recipe or entrypoint script
invokes system python3 or bare uv.
"""
import re
from pathlib import Path

MAKEFILE = Path("Makefile")
RESET_DEVICE = Path("scripts/entrypoints/reset_device.sh")
ONBOARD = Path("scripts/entrypoints/onboard.sh")

# Lines known to legitimately reference python3 (not recipe invocations):
# - PYTHON_VERSION = python3.12  (variable definition)
# - for tool in ... python3 ...  (make check diagnostic probe)
# - command -v python3 &>/dev/null (android/ios install-deps branch)
# - apk add python3               (ios_ish install-deps branch)
# - pkg install -y python         (android install-deps branch)
_ALLOWED_PYTHON3_PATTERNS = re.compile(
    r'PYTHON_VERSION\s*=\s*python3'      # variable def
    r'|for tool in.*python3'             # make check diagnostic
    r'|command -v python3'               # android/ios presence check
    r'|apk add python3'                  # ios_ish apk install
    r'|pkg install.*python'              # android pkg install
    r'|pip3? install'                    # android/ios pip installs
    r'|pip install'
)


def _makefile_recipe_lines():
    """Yield (line_number, line_text) for Makefile recipe lines only."""
    lines = MAKEFILE.read_text().splitlines()
    for i, line in enumerate(lines, 1):
        stripped = line.lstrip()
        # Recipe lines start with a tab in source; after lstrip they are the command
        if line.startswith('\t') and not stripped.startswith('#'):
            yield i, line


def test_no_bare_python3_recipe_invocations():
    """No Makefile recipe should directly invoke system python3 to run scripts or -c code."""
    violations = []
    for lineno, line in _makefile_recipe_lines():
        # Check for python3 used as an interpreter (not just mentioned)
        if re.search(r'\bpython3\s+(-c|scripts/)', line):
            if not _ALLOWED_PYTHON3_PATTERNS.search(line):
                violations.append(f"L{lineno}: {line.rstrip()}")
    assert violations == [], (
        "Bare python3 invocations found in Makefile recipes:\n" +
        "\n".join(violations)
    )


def test_no_bare_uv_in_makefile_recipes():
    """No Makefile recipe should call bare 'uv' — must use $$_UV or $(UV)."""
    violations = []
    for lineno, line in _makefile_recipe_lines():
        # bare 'uv venv' or 'uv pip' not inside a variable reference
        if re.search(r'(?<!\$)\buv\s+(venv|pip)', line):
            violations.append(f"L{lineno}: {line.rstrip()}")
    assert violations == [], (
        "Bare uv calls found in Makefile recipes:\n" +
        "\n".join(violations)
    )


def test_ensure_venv_macro_defined():
    """Makefile must define the ensure_venv macro."""
    content = MAKEFILE.read_text()
    assert "define ensure_venv" in content, "ensure_venv macro not found in Makefile"


def test_deps_installed_sentinel_in_ensure_venv():
    """ensure_venv must use a .deps-installed sentinel for idempotency."""
    content = MAKEFILE.read_text()
    assert ".deps-installed" in content, ".deps-installed sentinel not found"


def test_task_delete_in_phony():
    """task-delete must be declared in .PHONY."""
    content = MAKEFILE.read_text()
    # .PHONY spans multiple continuation lines — collect them all
    phony_block = re.search(r'\.PHONY:(.+?)(?=\n\n|\Z)', content, re.DOTALL)
    assert phony_block is not None, ".PHONY block not found"
    assert "task-delete" in phony_block.group(), "task-delete not in .PHONY"


def test_no_system_python_fallback_in_reset_device():
    """reset_device.sh must not fall back to system python3."""
    content = RESET_DEVICE.read_text()
    assert 'PYTHON="$(command -v python3)"' not in content, (
        "System python3 fallback still present in reset_device.sh"
    )


def test_no_system_python_fallback_in_onboard():
    """onboard.sh must not fall back to system python3."""
    content = ONBOARD.read_text()
    assert 'PYTHON="$(command -v python3)"' not in content, (
        "System python3 fallback still present in onboard.sh"
    )


def test_reset_device_installs_deps_before_python_use():
    """reset_device.sh must call make install-deps before first Python invocation."""
    content = RESET_DEVICE.read_text()
    first_python_use = content.find('"$PYTHON"')
    # install-deps call must appear before first $PYTHON use
    install_pos = content.find("install-deps")
    assert install_pos != -1, "install-deps call not found in reset_device.sh"
    assert install_pos < first_python_use, (
        f"install-deps (pos {install_pos}) must appear before first "
        f'"$PYTHON" use (pos {first_python_use}) in reset_device.sh'
    )


def test_onboard_installs_deps_before_python_use():
    """onboard.sh must call make install-deps before first Python invocation."""
    content = ONBOARD.read_text()
    first_python_use = content.find('"$PYTHON"')
    install_pos = content.find("install-deps")
    assert install_pos != -1, "install-deps call not found in onboard.sh"
    assert install_pos < first_python_use, (
        f"install-deps (pos {install_pos}) must appear before first "
        f'"$PYTHON" use (pos {first_python_use}) in onboard.sh'
    )
