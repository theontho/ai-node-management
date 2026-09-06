#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/ai-node-inventory-validate.XXXXXX")
trap 'find "$work" -depth -delete' EXIT

if python3 --version >/dev/null 2>&1; then
  PYTHON=python3
elif python --version >/dev/null 2>&1; then
  PYTHON=python
else
  echo "Python 3 is required." >&2
  exit 1
fi

PYTHONPYCACHEPREFIX="$work/pycache" "$PYTHON" -m py_compile "$SCRIPT_DIR/collect.py"
"$PYTHON" "$SCRIPT_DIR/collect.py" --fixture --output "$work/report" >/dev/null

"$PYTHON" - "$work/report" "$SCRIPT_DIR/collect.py" "$work/scan-root" <<'PY'
import importlib.util
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
collector_path = Path(sys.argv[2])
scan_root = Path(sys.argv[3])
data = json.loads((root / "inventory.json").read_text())
assert data["schemaVersion"] == 1
assert data["node"]["hostname"] == "example-ai-node"
assert data["cpu"][0]["cores"] == 8
assert data["memory"]["totalBytes"] == 64 * 1024**3
assert len(data["memory"]["modules"]) == 2
assert data["volumes"][0]["mount"] == "/"
assert data["accounts"][0]["name"] == "node-admin"
assert data["network"][0]["macAddress"] == "02:00:00:00:00:01"
assert data["physicalStorage"][0]["serial"] == "EXAMPLE-DISK-001"
assert data["storageScan"]["volumes"][0]["largestDirectories"][0]["path"] == "/srv/models"
assert data["storageScan"]["volumes"][0]["largestTopLevelItems"][0]["kind"] == "directory"
assert data["storageScan"]["volumes"][0]["largestTopLevelItems"][0]["significantSubdirectories"][0]["path"] == "/srv/models"
assert "credentials and authentication secrets" in data["dataHandling"]["omitted"]

page = (root / "index.html").read_text()
assert "inventory-data.js" in page
assert "SYSTEM_INVENTORY" in page
assert "['B','KiB','MiB','GiB','TiB','PiB']" in page
assert (root / "favicon.svg").is_file()
assert (root / "inventory-data.js").read_text().startswith("window.SYSTEM_INVENTORY = ")

(scan_root / "small").mkdir(parents=True)
(scan_root / "large" / "nested").mkdir(parents=True)
(scan_root / "small" / "one.bin").write_bytes(b"x" * 10)
(scan_root / "large" / "two.bin").write_bytes(b"x" * 20)
(scan_root / "large" / "nested" / "three.bin").write_bytes(b"x" * 30)
spec = importlib.util.spec_from_file_location("inventory_collector", collector_path)
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)
scan = collector.scan_volume(
    {"mount": str(scan_root), "capacityBytes": 1024**3},
    top_limit=10,
    file_limit=10,
    significant_min_bytes=1,
)
assert scan["filesScanned"] == 3
assert scan["bytesScanned"] == 60
assert scan["largestDirectories"][0]["path"].endswith("large")
assert scan["largestDirectories"][0]["bytes"] == 50
assert scan["largestTopLevelItems"][0]["bytes"] == 50
assert scan["largestTopLevelItems"][0]["kind"] == "directory"
assert scan["largestTopLevelItems"][0]["significantSubdirectories"][0]["path"].endswith("nested")
assert scan["largestFiles"][0]["bytes"] == 30
PY

if command -v node >/dev/null 2>&1; then
  "$PYTHON" - "$SCRIPT_DIR/index.html" "$work/dashboard.js" <<'PY'
from pathlib import Path
import re
import sys

page = Path(sys.argv[1]).read_text()
scripts = re.findall(r"<script>(.*?)</script>", page, re.DOTALL)
assert len(scripts) == 1
Path(sys.argv[2]).write_text(scripts[0])
PY
  node --check "$work/dashboard.js" >/dev/null
fi

echo "System inventory validation passed."
