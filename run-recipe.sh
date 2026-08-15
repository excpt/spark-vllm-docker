#!/bin/bash
#
# run-recipe.sh - Wrapper for run-recipe.py
#
# Ensures Python dependencies are available and runs the recipe runner.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECIPE_SCRIPT="$SCRIPT_DIR/run-recipe.py"

# Pick the first interpreter that actually RUNS. `command -v python3` is not enough on
# Windows: WindowsApps ships a python3 stub that resolves fine and then refuses to execute.
# A local .venv wins so we use the checkout's deps, not the system's.
for p in "$SCRIPT_DIR/.venv/bin/python" "$SCRIPT_DIR/.venv/Scripts/python.exe" python3 python; do
    "$p" -c '' 2>/dev/null && { PYTHON=$p; break; }
done
if [ -z "$PYTHON" ]; then
    echo "Error: Python 3 not found. Please install Python 3.10 or later."
    exit 1
fi

# Verify version
PY_VERSION=$($PYTHON -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PY_MAJOR=$($PYTHON -c 'import sys; print(sys.version_info.major)')
PY_MINOR=$($PYTHON -c 'import sys; print(sys.version_info.minor)')

if [[ "$PY_MAJOR" -lt 3 ]] || [[ "$PY_MAJOR" -eq 3 && "$PY_MINOR" -lt 10 ]]; then
    echo "Error: Python 3.10+ required, found $PY_VERSION"
    exit 1
fi

# Check for PyYAML and install if missing
if ! $PYTHON -c "import yaml" 2>/dev/null; then
    echo "Installing PyYAML..."
    $PYTHON -m pip install --quiet pyyaml
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to install PyYAML. Try: pip install pyyaml"
        exit 1
    fi
fi

# Run the recipe script
exec $PYTHON "$RECIPE_SCRIPT" "$@"
