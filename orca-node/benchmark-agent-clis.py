#!/usr/bin/env python3
"""Benchmark local resource use for OpenCode, Pi, Copilot CLI, and Moltis."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import resource
import shutil
import signal
import subprocess
import time
from dataclasses import dataclass


PROMPT = (
    "Fix the bug in math_utils.py so every test in test_math_utils.py passes. "
    "Work only in this repository, do not modify the tests, run "
    "`python3 -m unittest discover -q`, and stop when the tests pass."
)

MATH_UTILS = """\
def clamp(value, lower, upper):
    return max(lower, min(lower, value))
"""

TEST_MATH_UTILS = """\
import unittest

from math_utils import clamp


class ClampTests(unittest.TestCase):
    def test_value_inside_range(self):
        self.assertEqual(clamp(5, 0, 10), 5)

    def test_value_below_range(self):
        self.assertEqual(clamp(-2, 0, 10), 0)

    def test_value_above_range(self):
        self.assertEqual(clamp(12, 0, 10), 10)


if __name__ == "__main__":
    unittest.main()
"""


@dataclass(frozen=True)
class Tool:
    name: str
    binary: pathlib.Path
    model: str
    command: list[str]
    env: dict[str, str]
    install_root: pathlib.Path


def parse_args() -> argparse.Namespace:
    home = pathlib.Path.home()
    default_root = home / ".local/share/cli-benchmark"
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--install-root", type=pathlib.Path, default=default_root)
    parser.add_argument(
        "--opencode-auth-root",
        type=pathlib.Path,
        default=pathlib.Path(".cli-benchmark-auth"),
    )
    parser.add_argument(
        "--pi-auth-dir",
        type=pathlib.Path,
        default=pathlib.Path(".pi-benchmark"),
    )
    parser.add_argument(
        "--moltis-data-dir",
        type=pathlib.Path,
        default=pathlib.Path(".moltis-benchmark/data"),
    )
    parser.add_argument(
        "--only",
        action="append",
        choices=("opencode", "pi", "copilot", "moltis"),
        help="benchmark only the named CLI; repeat to select more than one",
    )
    parser.add_argument("--pi-provider", default="github-copilot")
    parser.add_argument("--pi-model", default="gpt-5-mini")
    parser.add_argument("--moltis-provider", default="github-copilot")
    parser.add_argument("--moltis-model", default="gpt-5-mini")
    return parser.parse_args()


def process_group_usage(process_group: int) -> tuple[int, float, float]:
    page_size = os.sysconf("SC_PAGE_SIZE")
    ticks = os.sysconf("SC_CLK_TCK")
    rss = 0
    user = 0
    system = 0
    for entry in pathlib.Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            _, separator, suffix = (entry / "stat").read_text().rpartition(")")
            if not separator:
                continue
            fields = suffix.split()
            if int(fields[2]) != process_group:
                continue
            rss += int(fields[21]) * page_size
            user += int(fields[11])
            system += int(fields[12])
        except (
            FileNotFoundError,
            PermissionError,
            ProcessLookupError,
            IndexError,
            ValueError,
        ):
            continue
    return rss, user / ticks, system / ticks


def run_measured(
    command: list[str | os.PathLike[str]],
    cwd: pathlib.Path,
    env: dict[str, str],
    output_base: pathlib.Path,
    timeout: float,
) -> dict[str, object]:
    stdout_path = output_base.with_suffix(".stdout")
    stderr_path = output_base.with_suffix(".stderr")
    started = time.monotonic()
    peak_rss = 0
    peak_tree_user = 0.0
    peak_tree_system = 0.0
    timed_out = False

    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        normalized_command = [os.fspath(part) for part in command]
        process = subprocess.Popen(
            normalized_command,
            cwd=cwd,
            env=env,
            stdout=stdout,
            stderr=stderr,
            start_new_session=True,
        )
        usage = None
        while usage is None:
            current_rss, current_user, current_system = process_group_usage(process.pid)
            peak_rss = max(peak_rss, current_rss)
            peak_tree_user = max(peak_tree_user, current_user)
            peak_tree_system = max(peak_tree_system, current_system)
            waited_pid, status, waited_usage = os.wait4(process.pid, os.WNOHANG)
            if waited_pid:
                process.returncode = os.waitstatus_to_exitcode(status)
                usage = waited_usage
                break
            if time.monotonic() - started > timeout:
                timed_out = True
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                time.sleep(1)
                waited_pid, status, waited_usage = os.wait4(process.pid, os.WNOHANG)
                if not waited_pid:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    waited_pid, status, waited_usage = os.wait4(process.pid, 0)
                process.returncode = os.waitstatus_to_exitcode(status)
                usage = waited_usage
                break
            time.sleep(0.02)

    assert usage is not None
    return {
        "command": normalized_command,
        "exit_code": process.returncode,
        "timed_out": timed_out,
        "wall_seconds": time.monotonic() - started,
        "user_cpu_seconds": usage.ru_utime,
        "system_cpu_seconds": usage.ru_stime,
        "peak_rss_bytes": max(peak_rss, usage.ru_maxrss * 1024),
        "peak_sampled_tree_user_seconds": peak_tree_user,
        "peak_sampled_tree_system_seconds": peak_tree_system,
        "stdout_bytes": stdout_path.stat().st_size,
        "stderr_bytes": stderr_path.stat().st_size,
        "stdout_file": stdout_path.name,
        "stderr_file": stderr_path.name,
    }


def prepare_fixture(path: pathlib.Path) -> None:
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True)
    (path / "math_utils.py").write_text(MATH_UTILS)
    (path / "test_math_utils.py").write_text(TEST_MATH_UTILS)
    subprocess.run(
        ["git", "init", "-q"],
        cwd=path,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def prepare_moltis_config(
    path: pathlib.Path,
    workspace: pathlib.Path,
    provider: str,
    model: str,
) -> None:
    path.mkdir()
    quoted_provider = json.dumps(provider)
    (path / "moltis.toml").write_text(
        f"""\
[providers]
offered = [{json.dumps(provider)}]

[providers.{quoted_provider}]
enabled = true
models = [{json.dumps(model)}]
fetch_models = false

[tools]
agent_timeout_secs = 300
agent_max_iterations = 25
agent_max_auto_continues = 0

[tools.fs]
workspace_root = {json.dumps(str(workspace))}
allow_paths = [{json.dumps(str(workspace) + "/**")}]
require_approval = false
respect_gitignore = true

[tools.exec]
approval_mode = "never"
security_level = "permissive"

[tools.exec.sandbox]
mode = "off"

[tools.policy]
allow = ["Read", "Write", "Edit", "MultiEdit", "Glob", "Grep", "exec"]

[failover]
enabled = false
exact_model = true
fallback_models = []
"""
    )


def fixture_passes(path: pathlib.Path) -> bool:
    result = subprocess.run(
        ["python3", "-m", "unittest", "discover", "-q"],
        cwd=path,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0 and (path / "test_math_utils.py").read_text() == TEST_MATH_UTILS


def allocated_size(path: pathlib.Path) -> int:
    result = subprocess.run(
        ["du", "-sk", path],
        check=True,
        capture_output=True,
        text=True,
    )
    return int(result.stdout.split()[0]) * 1024


def tools(args: argparse.Namespace) -> list[Tool]:
    root = args.install_root.expanduser().resolve()
    auth_root = args.opencode_auth_root.resolve()
    shared_env = os.environ.copy()

    opencode_binary = root / "opencode/node_modules/.bin/opencode"
    pi_binary = root / "pi-current/node_modules/.bin/pi"
    copilot_binary = root / "copilot/node_modules/.bin/copilot"
    moltis_binary = root / "moltis/moltis"

    opencode_env = shared_env.copy()
    opencode_env["XDG_CONFIG_HOME"] = str(auth_root / "config")
    opencode_env["XDG_DATA_HOME"] = str(auth_root / "data")

    pi_env = shared_env.copy()
    pi_env["PI_SKIP_VERSION_CHECK"] = "1"
    pi_env["PI_TELEMETRY"] = "0"
    pi_env["PI_CODING_AGENT_DIR"] = str(args.pi_auth_dir.resolve())

    moltis_env = shared_env.copy()
    moltis_library = root / "moltis/deps/usr/lib/x86_64-linux-gnu"
    existing_library_path = moltis_env.get("LD_LIBRARY_PATH")
    moltis_env["LD_LIBRARY_PATH"] = (
        f"{moltis_library}:{existing_library_path}"
        if existing_library_path
        else str(moltis_library)
    )

    return [
        Tool(
            "opencode",
            opencode_binary,
            "github-copilot/gpt-5-mini",
            [
                str(opencode_binary),
                "run",
                "--auto",
                "--dir",
                "{cwd}",
                "--model",
                "github-copilot/gpt-5-mini",
                PROMPT,
            ],
            opencode_env,
            root / "opencode",
        ),
        Tool(
            "pi",
            pi_binary,
            f"{args.pi_provider}/{args.pi_model}",
            [
                str(pi_binary),
                "--print",
                "--no-session",
                "--approve",
                "--no-extensions",
                "--no-skills",
                "--no-prompt-templates",
                "--no-context-files",
                "--provider",
                args.pi_provider,
                "--model",
                args.pi_model,
                "--thinking",
                "off",
                PROMPT,
            ],
            pi_env,
            root / "pi-current",
        ),
        Tool(
            "copilot",
            copilot_binary,
            "github-copilot/gpt-5-mini",
            [
                str(copilot_binary),
                "--prompt",
                PROMPT,
                "--model",
                "gpt-5-mini",
                "--allow-all",
            ],
            shared_env,
            root / "copilot",
        ),
        Tool(
            "moltis",
            moltis_binary,
            f"{args.moltis_provider}/{args.moltis_model}",
            [
                str(moltis_binary),
                "agent",
                "--message",
                PROMPT,
                "--config-dir",
                "{config}",
                "--data-dir",
                str(args.moltis_data_dir.resolve()),
                "--bind",
                "127.0.0.1",
                "--no-tls",
            ],
            moltis_env,
            root / "moltis",
        ),
    ]


def main() -> int:
    args = parse_args()
    if args.runs < 1:
        raise SystemExit("--runs must be at least 1")

    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    benchmark_tools = tools(args)
    if args.only:
        selected = set(args.only)
        benchmark_tools = [tool for tool in benchmark_tools if tool.name in selected]

    results: dict[str, object] = {
        "runs": args.runs,
        "sample_interval_seconds": 0.02,
        "tools": {},
    }

    for tool in benchmark_tools:
        if not tool.binary.exists():
            raise SystemExit(f"missing {tool.binary}")
        tool_output = args.output / tool.name
        tool_output.mkdir()
        version = subprocess.run(
            [tool.binary, "--version"],
            check=False,
            capture_output=True,
            text=True,
            env=tool.env,
        )
        entry: dict[str, object] = {
            "version": (version.stdout + version.stderr).strip(),
            "model": tool.model,
            "install_bytes": allocated_size(tool.install_root),
            "startup": [],
            "task": [],
        }
        results["tools"][tool.name] = entry

        startup = entry["startup"]
        assert isinstance(startup, list)
        for run_number in range(1, args.runs + 1):
            startup.append(
                run_measured(
                    [tool.binary, "--help"],
                    pathlib.Path.cwd(),
                    tool.env,
                    tool_output / f"startup-{run_number}",
                    args.timeout,
                )
            )

        task = entry["task"]
        assert isinstance(task, list)
        for run_number in range(0, args.runs + 1):
            fixture = tool_output / f"workspace-{run_number}"
            prepare_fixture(fixture)
            config = fixture / ".moltis-config"
            if tool.name == "moltis":
                prepare_moltis_config(
                    config,
                    fixture,
                    args.moltis_provider,
                    args.moltis_model,
                )
            placeholders = {
                "{cwd}": str(fixture),
                "{config}": str(config),
            }
            measured = run_measured(
                [placeholders.get(part, part) for part in tool.command],
                fixture,
                tool.env,
                tool_output / f"task-{run_number}",
                args.timeout,
            )
            measured["fixture_passed"] = fixture_passes(fixture)
            if run_number == 0:
                entry["warmup"] = measured
            else:
                task.append(measured)

    (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
