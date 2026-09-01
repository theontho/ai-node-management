#!/usr/bin/env bash
set -Eeuo pipefail

workspace=/workspaces/scratch
harness="$workspace/benchmark-agent-clis.py"
acp_client="$workspace/moltis-acp-client.py"
output="$workspace/benchmark-results-luna-medium-serial"
report="$output/benchmark-report.md"
opencode_auth="$workspace/.opencode-serial-auth-$$"

for required in "$harness" "$acp_client"; do
  if [[ ! -f "$required" ]]; then
    echo "Missing required benchmark file: $required" >&2
    exit 1
  fi
done

cleanup_credentials() {
  rm -rf -- "$opencode_auth"
}
trap cleanup_credentials EXIT

echo "Stopping stale benchmark-owned processes..."
python3 - <<'PY'
import os
import pathlib
import signal
import time

own = {os.getpid()}
pid = os.getppid()
while pid > 1:
    own.add(pid)
    try:
        fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
        pid = int(fields[3])
    except (FileNotFoundError, IndexError, ValueError):
        break

prompt = "Fix the bug in math_utils.py so every test in test_math_utils.py passes."


def benchmark_pids() -> list[int]:
    found = []
    for entry in pathlib.Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        candidate = int(entry.name)
        if candidate in own:
            continue
        try:
            command = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode(
                errors="replace"
            )
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        if (
            "/workspaces/scratch/benchmark-agent-clis.py" in command
            or "/workspaces/scratch/moltis-acp-client.py" in command
            or prompt in command
        ):
            found.append(candidate)
    return sorted(found)


stale = benchmark_pids()
for candidate in stale:
    try:
        os.kill(candidate, signal.SIGTERM)
    except ProcessLookupError:
        pass

deadline = time.monotonic() + 5
while time.monotonic() < deadline and benchmark_pids():
    time.sleep(0.1)

remaining = benchmark_pids()
for candidate in remaining:
    try:
        os.kill(candidate, signal.SIGKILL)
    except ProcessLookupError:
        pass

print(f"Stopped {len(stale)} stale process(es); forced {len(remaining)}.")
PY

rm -rf "$output"
install -d -m 0700 "$opencode_auth/config" "$opencode_auth/data/opencode"
install -m 0600 \
  "$HOME/.local/share/opencode/auth.json" \
  "$opencode_auth/data/opencode/auth.json"

echo "Waiting for process cleanup to settle..."
sleep 5
echo "Starting serial benchmark at $(date --iso-8601=seconds)"
echo "Output directory: $output"

python3 "$harness" \
  --runs 3 \
  --timeout 300 \
  --output "$output" \
  --install-root "$HOME/.local/share/cli-benchmark" \
  --opencode-auth-root "$opencode_auth" \
  --opencode-model gpt-5.6-luna \
  --opencode-variant medium \
  --opencode-model-override \
  --pi-auth-dir "$workspace/.pi-benchmark" \
  --pi-model gpt-5.6-luna \
  --pi-thinking medium \
  --copilot-model gpt-5.6-luna \
  --copilot-reasoning-effort medium \
  --moltis-auth-config-dir "$workspace/.moltis-benchmark/config" \
  --moltis-data-dir "$output/moltis-data" \
  --moltis-model gpt-5.6-luna \
  --moltis-thinking medium

python3 - "$output/results.json" "$report" <<'PY'
import json
import pathlib
import statistics
import sys

results_path = pathlib.Path(sys.argv[1])
report_path = pathlib.Path(sys.argv[2])
results = json.loads(results_path.read_text())

labels = {
    "opencode": "OpenCode",
    "pi": "Pi",
    "copilot": "Copilot CLI",
    "moltis": "Moltis",
}

rows = []
for name, result in results["tools"].items():
    tasks = result["task"]
    startups = result["startup"]
    if len(tasks) != 3 or not all(task.get("fixture_passed") for task in tasks):
        raise SystemExit(f"{name} did not pass all three measured task runs")
    rows.append(
        (
            statistics.median(task["wall_seconds"] for task in tasks),
            "| {} {} | {:.1f} MiB | {:.3f} s | {:.1f} MiB | {:.3f} s | "
            "{:.3f} s | {:.1f} MiB | 3/3 |".format(
                labels[name],
                result["version"],
                result["install_bytes"] / 1024 / 1024,
                statistics.median(run["wall_seconds"] for run in startups),
                statistics.median(run["peak_rss_bytes"] for run in startups)
                / 1024
                / 1024,
                statistics.median(task["wall_seconds"] for task in tasks),
                statistics.median(
                    task["user_cpu_seconds"] + task["system_cpu_seconds"]
                    for task in tasks
                ),
                statistics.median(task["peak_rss_bytes"] for task in tasks)
                / 1024
                / 1024,
            ),
        )
    )

rows.sort()
lines = [
    "# GPT-5.6 Luna medium agent CLI benchmark",
    "",
    "## Task",
    "",
    "Each client receives a fresh two-file Git repository. `math_utils.py` starts",
    "with a deliberately broken `clamp(value, lower, upper)` implementation:",
    "",
    "```python",
    "return max(lower, min(lower, value))",
    "```",
    "",
    "The client must modify only `math_utils.py`, leave `test_math_utils.py`",
    "unchanged, run `python3 -m unittest discover -q`, and stop after all tests",
    "pass. The three tests cover a value below the lower bound, a value within",
    "the range, and a value above the upper bound. The harness independently",
    "reruns the tests and rejects any run that changed the test file.",
    "",
    "All four clients use GitHub Copilot GPT-5.6 Luna with medium reasoning. Each",
    "client runs after the previous client exits, with one unmeasured warm-up and",
    "three measured repetitions. Times and memory values below are medians of",
    "those three measured runs. Model/network latency is included in wall time.",
    "",
    "## Results",
    "",
    "| Client | Installed | Startup | Startup RSS | Task wall | Task CPU | Task peak RSS | Passed |",
    "|---|---:|---:|---:|---:|---:|---:|---:|",
    *(row for _, row in rows),
    "",
    f"Raw measurements: `{results_path}`",
    "",
]
text = "\n".join(lines)
report_path.write_text(text)
print()
print(text)
print(f"Saved report: {report_path}")
PY
