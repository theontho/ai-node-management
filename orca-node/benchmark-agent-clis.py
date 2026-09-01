#!/usr/bin/env python3
"""Benchmark local resource use across headless coding-agent CLIs."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass

from benchmark_tasks import BenchmarkTask, TASKS, TASKS_BY_NAME


@dataclass(frozen=True)
class Tool:
    name: str
    binary: pathlib.Path
    model: str
    command: list[str]
    env: dict[str, str]
    install_root: pathlib.Path
    default_enabled: bool = True


def parse_args() -> argparse.Namespace:
    home = pathlib.Path.home()
    default_root = home / ".local/share/cli-benchmark"
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument(
        "--task",
        action="append",
        choices=tuple(TASKS_BY_NAME),
        help="benchmark only the named task; repeat to select more than one",
    )
    parser.add_argument(
        "--skip-warmup",
        action="store_true",
        help="skip each tool/task warm-up run",
    )
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
        "--copilot-home",
        type=pathlib.Path,
        default=pathlib.Path(".copilot-benchmark"),
    )
    parser.add_argument(
        "--moltis-data-dir",
        type=pathlib.Path,
        default=pathlib.Path(".moltis-benchmark/data"),
    )
    parser.add_argument(
        "--moltis-auth-config-dir",
        type=pathlib.Path,
        default=pathlib.Path(".moltis-benchmark/config"),
    )
    parser.add_argument(
        "--hermes-home",
        type=pathlib.Path,
        default=pathlib.Path(".hermes-benchmark"),
    )
    parser.add_argument(
        "--crush-config-dir",
        type=pathlib.Path,
        default=pathlib.Path(".crush-benchmark/config"),
    )
    parser.add_argument(
        "--crush-data-dir",
        type=pathlib.Path,
        default=pathlib.Path(".crush-benchmark/data"),
    )
    parser.add_argument(
        "--codex-home",
        type=pathlib.Path,
        default=pathlib.Path(".codex-benchmark"),
    )
    parser.add_argument(
        "--claude-config-dir",
        type=pathlib.Path,
        default=pathlib.Path(".claude-benchmark"),
    )
    parser.add_argument(
        "--openclaw-state-dir",
        type=pathlib.Path,
        default=pathlib.Path(".openclaw-benchmark"),
    )
    parser.add_argument(
        "--only",
        action="append",
        choices=(
            "opencode",
            "pi",
            "copilot",
            "moltis",
            "hermes",
            "crush",
            "codex",
            "claude",
            "openclaw",
        ),
        help="benchmark only the named CLI; repeat to select more than one",
    )
    parser.add_argument("--opencode-model", default="gpt-5-mini")
    parser.add_argument("--opencode-variant")
    parser.add_argument(
        "--opencode-model-override",
        action="store_true",
        help="add the selected model when OpenCode's models.dev catalog lacks it",
    )
    parser.add_argument("--pi-provider", default="github-copilot")
    parser.add_argument("--pi-model", default="gpt-5-mini")
    parser.add_argument("--pi-thinking", default="off")
    parser.add_argument("--copilot-model", default="gpt-5-mini")
    parser.add_argument("--copilot-reasoning-effort")
    parser.add_argument("--moltis-provider", default="github-copilot")
    parser.add_argument("--moltis-model", default="gpt-5-mini")
    parser.add_argument("--moltis-thinking")
    parser.add_argument("--hermes-provider", default="copilot")
    parser.add_argument("--hermes-model", default="gpt-5-mini")
    parser.add_argument("--hermes-reasoning", default="none")
    parser.add_argument("--crush-model", default="copilot/gpt-5-mini")
    parser.add_argument("--codex-model", default="gpt-5.4")
    parser.add_argument("--claude-model", default="sonnet")
    parser.add_argument("--claude-effort", default="medium")
    parser.add_argument(
        "--openclaw-model",
        default="github-copilot/gpt-5-mini",
    )
    parser.add_argument("--openclaw-thinking", default="off")
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


def terminate_benchmark_children(run_id: str) -> None:
    own_uid = os.getuid()
    marker = f"AGENT_CLI_BENCHMARK={run_id}".encode()
    candidates = []
    for entry in pathlib.Path("/proc").iterdir():
        if not entry.name.isdigit() or int(entry.name) == os.getpid():
            continue
        try:
            if entry.stat().st_uid != own_uid:
                continue
            environment = (entry / "environ").read_bytes().split(b"\0")
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        if marker in environment:
            candidates.append(int(entry.name))

    for pid in candidates:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    if candidates:
        time.sleep(0.2)
    for pid in candidates:
        try:
            os.kill(pid, 0)
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


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
    terminate_benchmark_children(env["AGENT_CLI_BENCHMARK"])
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


def prepare_fixture(path: pathlib.Path, task: BenchmarkTask) -> None:
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True)
    for relative_path, content in task.files.items():
        destination = path / relative_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content)
    subprocess.run(
        ["git", "init", "-q"],
        cwd=path,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["git", "add", "--all"],
        cwd=path,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=Agent CLI Benchmark",
            "-c",
            "user.email=benchmark@example.invalid",
            "commit",
            "-qm",
            "Initial benchmark fixture",
        ],
        cwd=path,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def command_passes(
    command: tuple[str, ...], path: pathlib.Path, timeout: float = 60
) -> bool:
    process = subprocess.Popen(
        command,
        cwd=path,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        return process.wait(timeout=timeout) == 0
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=1)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        return False


def changed_fixture_files(
    path: pathlib.Path, task: BenchmarkTask
) -> tuple[list[str], list[str]]:
    changed = []
    for relative_path, original in task.files.items():
        candidate = path / relative_path
        if not candidate.is_file() or candidate.read_bytes() != original.encode():
            changed.append(relative_path)

    ignored_parts = {".git", "__pycache__", "node_modules"}
    generated_suffixes = {".pyc", ".pyo"}
    extras = []
    for candidate in path.rglob("*"):
        if not candidate.is_file():
            continue
        relative = candidate.relative_to(path)
        if any(part in ignored_parts for part in relative.parts):
            continue
        if candidate.suffix in generated_suffixes:
            continue
        relative_name = relative.as_posix()
        if relative_name not in task.files:
            extras.append(relative_name)
    return sorted(changed), sorted(extras)


def grade_fixture(path: pathlib.Path, task: BenchmarkTask) -> dict[str, object]:
    changed, extras = changed_fixture_files(path, task)
    protected_unchanged = not (set(changed) & task.protected_files)
    scope_passed = set(changed) <= task.allowed_changes and not extras
    visible_tests_passed = command_passes(task.test_command, path)
    hidden_tests_passed = command_passes(task.hidden_command, path)
    return {
        "changed_files": changed,
        "unexpected_files": extras,
        "protected_files_unchanged": protected_unchanged,
        "scope_passed": scope_passed,
        "visible_tests_passed": visible_tests_passed,
        "hidden_tests_passed": hidden_tests_passed,
        "fixture_passed": (
            protected_unchanged
            and scope_passed
            and visible_tests_passed
            and hidden_tests_passed
        ),
    }


def prepare_moltis_config(
    path: pathlib.Path,
    workspace: pathlib.Path,
    provider: str,
    model: str,
    auth_config_dir: pathlib.Path,
) -> None:
    path.mkdir(parents=True, exist_ok=True)
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
agent_max_iterations = 100
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
    for name in ("defaults.toml", "oauth_tokens.json"):
        source = auth_config_dir / name
        if not source.exists():
            continue
        shutil.copy2(source, path / name)


def allocated_size(path: pathlib.Path) -> int:
    result = subprocess.run(
        ["du", "-sk", path],
        check=True,
        capture_output=True,
        text=True,
    )
    return int(result.stdout.split()[0]) * 1024


def moltis_model_with_reasoning(args: argparse.Namespace) -> str:
    if args.moltis_thinking:
        return f"{args.moltis_model}@reasoning-{args.moltis_thinking}"
    return args.moltis_model


def tools(args: argparse.Namespace) -> list[Tool]:
    root = args.install_root.expanduser().resolve()
    auth_root = args.opencode_auth_root.resolve()
    shared_env = os.environ.copy()
    shared_env["AGENT_CLI_BENCHMARK"] = os.environ.get(
        "AGENT_CLI_BENCHMARK",
        f"direct-{os.getpid()}-{time.time_ns()}",
    )

    def resolve_binary(relative_path: str, command: str) -> pathlib.Path:
        installed = root / relative_path
        if installed.is_file() and os.access(installed, os.X_OK):
            return installed
        discovered = shutil.which(command)
        return pathlib.Path(discovered).resolve() if discovered else installed

    opencode_binary = resolve_binary(
        "opencode/node_modules/.bin/opencode", "opencode"
    )
    pi_binary = resolve_binary("pi-current/node_modules/.bin/pi", "pi")
    copilot_binary = resolve_binary(
        "copilot/node_modules/.bin/copilot", "copilot"
    )
    moltis_binary = resolve_binary("moltis/moltis", "moltis")
    hermes_binary = resolve_binary("hermes/venv/bin/hermes", "hermes")
    crush_binary = resolve_binary("crush/node_modules/.bin/crush", "crush")
    codex_binary = resolve_binary("codex/node_modules/.bin/codex", "codex")
    claude_binary = resolve_binary(
        "claude/node_modules/.bin/claude", "claude"
    )
    openclaw_binary = resolve_binary(
        "openclaw/node_modules/.bin/openclaw", "openclaw"
    )
    moltis_acp_client = pathlib.Path(__file__).resolve().with_name(
        "moltis-acp-client.py"
    )

    opencode_env = shared_env.copy()
    opencode_env["XDG_CONFIG_HOME"] = str(auth_root / "config")
    opencode_env["XDG_DATA_HOME"] = str(auth_root / "data")
    if args.opencode_model_override:
        qualified_model = f"github-copilot/{args.opencode_model}"
        opencode_env["OPENCODE_CONFIG_CONTENT"] = json.dumps(
            {
                "small_model": qualified_model,
                "provider": {
                    "github-copilot": {
                        "models": {
                            args.opencode_model: {
                                "name": args.opencode_model,
                                "reasoning": True,
                                "tool_call": True,
                                "limit": {
                                    "context": 128000,
                                    "output": 32768,
                                },
                            }
                        }
                    }
                },
            }
        )

    pi_env = shared_env.copy()
    pi_env["PI_SKIP_VERSION_CHECK"] = "1"
    pi_env["PI_TELEMETRY"] = "0"
    pi_env["PI_CODING_AGENT_DIR"] = str(args.pi_auth_dir.resolve())

    copilot_env = shared_env.copy()
    copilot_env["COPILOT_HOME"] = str(args.copilot_home.resolve())

    moltis_env = shared_env.copy()
    moltis_library = root / "moltis/deps/usr/lib/x86_64-linux-gnu"
    existing_library_path = moltis_env.get("LD_LIBRARY_PATH")
    if moltis_library.is_dir():
        moltis_env["LD_LIBRARY_PATH"] = (
            f"{moltis_library}:{existing_library_path}"
            if existing_library_path
            else str(moltis_library)
        )

    hermes_env = shared_env.copy()
    hermes_env["HERMES_HOME"] = str(args.hermes_home.resolve())

    crush_env = shared_env.copy()
    crush_env["CRUSH_GLOBAL_CONFIG"] = str(args.crush_config_dir.resolve())
    crush_env["CRUSH_GLOBAL_DATA"] = str(args.crush_data_dir.resolve())
    crush_env["CRUSH_DISABLE_PROVIDER_AUTO_UPDATE"] = "1"
    crush_env["CRUSH_DISABLE_METRICS"] = "1"

    codex_env = shared_env.copy()
    codex_env["CODEX_HOME"] = str(args.codex_home.resolve())

    claude_env = shared_env.copy()
    claude_env["CLAUDE_CONFIG_DIR"] = str(args.claude_config_dir.resolve())

    openclaw_state_dir = args.openclaw_state_dir.resolve()
    openclaw_env = shared_env.copy()
    openclaw_env["OPENCLAW_STATE_DIR"] = str(openclaw_state_dir)
    openclaw_env["OPENCLAW_CONFIG_PATH"] = str(
        openclaw_state_dir / "openclaw.json"
    )

    opencode_command = [
        str(opencode_binary),
        "run",
        "--auto",
        "--dir",
        "{cwd}",
        "--model",
        f"github-copilot/{args.opencode_model}",
    ]
    if args.opencode_variant:
        opencode_command.extend(["--variant", args.opencode_variant])
    opencode_command.append("{prompt}")

    copilot_command = [
        str(copilot_binary),
        "--prompt",
        "{prompt}",
        "--model",
        args.copilot_model,
        "--allow-all",
        "--disable-builtin-mcps",
        "--no-custom-instructions",
        "--no-ask-user",
        "--no-auto-update",
    ]
    if args.copilot_reasoning_effort:
        copilot_command.extend(
            ["--reasoning-effort", args.copilot_reasoning_effort]
        )

    moltis_model = moltis_model_with_reasoning(args)
    moltis_command = [
        sys.executable,
        str(moltis_acp_client),
        "--moltis-binary",
        str(moltis_binary),
        "--config-dir",
        "{config}",
        "--data-dir",
        str(args.moltis_data_dir.resolve()),
        "--cwd",
        "{cwd}",
        "--prompt",
        "{prompt}",
    ]

    return [
        Tool(
            "opencode",
            opencode_binary,
            f"github-copilot/{args.opencode_model}",
            opencode_command,
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
                args.pi_thinking,
                "{prompt}",
            ],
            pi_env,
            root / "pi-current",
        ),
        Tool(
            "copilot",
            copilot_binary,
            f"github-copilot/{args.copilot_model}",
            copilot_command,
            copilot_env,
            root / "copilot",
        ),
        Tool(
            "moltis",
            moltis_binary,
            f"{args.moltis_provider}/{moltis_model}",
            moltis_command,
            moltis_env,
            root / "moltis",
        ),
        Tool(
            "hermes",
            hermes_binary,
            f"{args.hermes_provider}/{args.hermes_model}",
            [
                str(hermes_binary),
                "--ignore-user-config",
                "--ignore-rules",
                "--reasoning",
                args.hermes_reasoning,
                "--provider",
                args.hermes_provider,
                "--model",
                args.hermes_model,
                "--toolsets",
                "terminal,file",
                "--oneshot",
                "{prompt}",
            ],
            hermes_env,
            root / "hermes",
        ),
        Tool(
            "crush",
            crush_binary,
            args.crush_model,
            [
                str(crush_binary),
                "run",
                "--cwd",
                "{cwd}",
                "--data-dir",
                str(args.crush_data_dir.resolve()),
                "--quiet",
                "--model",
                args.crush_model,
                "{prompt}",
            ],
            crush_env,
            root / "crush",
        ),
        Tool(
            "codex",
            codex_binary,
            f"openai/{args.codex_model}",
            [
                str(codex_binary),
                "exec",
                "--cd",
                "{cwd}",
                "--model",
                args.codex_model,
                "--sandbox",
                "workspace-write",
                "--ephemeral",
                "--ignore-user-config",
                "--ignore-rules",
                "--color",
                "never",
                "--config",
                'model_reasoning_effort="medium"',
                "{prompt}",
            ],
            codex_env,
            root / "codex",
            default_enabled=False,
        ),
        Tool(
            "claude",
            claude_binary,
            f"anthropic/{args.claude_model}",
            [
                str(claude_binary),
                "--print",
                "--bare",
                "--dangerously-skip-permissions",
                "--model",
                args.claude_model,
                "--effort",
                args.claude_effort,
                "--output-format",
                "json",
                "--no-session-persistence",
                "{prompt}",
            ],
            claude_env,
            root / "claude",
            default_enabled=False,
        ),
        Tool(
            "openclaw",
            openclaw_binary,
            args.openclaw_model,
            [
                str(openclaw_binary),
                "--no-color",
                "--log-level",
                "error",
                "agent",
                "exec",
                "--isolated",
                "--state-dir",
                str(openclaw_state_dir),
                "--model",
                args.openclaw_model,
                "--thinking",
                args.openclaw_thinking,
                "--cwd",
                "{cwd}",
                "--timeout",
                str(int(args.timeout)),
                "--json",
                "{prompt}",
            ],
            openclaw_env,
            root / "openclaw",
        ),
    ]


def main() -> int:
    args = parse_args()
    if args.runs < 1:
        raise SystemExit("--runs must be at least 1")

    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    benchmark_tools = tools(args)
    benchmark_tasks = list(TASKS)
    if args.only:
        selected = set(args.only)
        benchmark_tools = [tool for tool in benchmark_tools if tool.name in selected]
    else:
        benchmark_tools = [tool for tool in benchmark_tools if tool.default_enabled]
    if args.task:
        selected_tasks = set(args.task)
        benchmark_tasks = [
            task for task in benchmark_tasks if task.name in selected_tasks
        ]

    results: dict[str, object] = {
        "runs": args.runs,
        "skip_warmup": args.skip_warmup,
        "sample_interval_seconds": 0.02,
        "task_suite": [
            {
                "name": task.name,
                "language": task.language,
                "difficulty": task.difficulty,
                "summary": task.summary,
                "allowed_changes": sorted(task.allowed_changes),
                "protected_files": sorted(task.protected_files),
                "test_command": list(task.test_command),
            }
            for task in benchmark_tasks
        ],
        "tools": {},
    }

    tool_entries: dict[str, dict[str, object]] = {}
    tool_outputs: dict[str, pathlib.Path] = {}
    runnable_tools: list[Tool] = []
    for tool in benchmark_tools:
        tool_output = args.output / tool.name
        tool_output.mkdir()
        tool_outputs[tool.name] = tool_output
        available = tool.binary.is_file() and os.access(tool.binary, os.X_OK)
        entry: dict[str, object] = {
            "available": available,
            "version": "not installed",
            "model": tool.model,
            "install_bytes": 0,
            "startup": [],
            "tasks": {},
        }
        results["tools"][tool.name] = entry
        tool_entries[tool.name] = entry

        task_results = entry["tasks"]
        assert isinstance(task_results, dict)
        for benchmark_task in benchmark_tasks:
            task_output = tool_output / benchmark_task.name
            task_output.mkdir()
            task_results[benchmark_task.name] = {
                "language": benchmark_task.language,
                "difficulty": benchmark_task.difficulty,
                "summary": benchmark_task.summary,
                "runs": [],
            }

        if not available:
            entry["skip_reason"] = (
                f"{tool.binary.name} is not installed or executable"
            )
            continue

        runnable_tools.append(tool)
        version = subprocess.run(
            [tool.binary, "--version"],
            check=False,
            capture_output=True,
            text=True,
            env=tool.env,
        )
        entry["version"] = (version.stdout + version.stderr).strip()
        measured_install = (
            tool.install_root if tool.install_root.exists() else tool.binary
        )
        entry["install_bytes"] = allocated_size(measured_install)

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

    benchmark_tools = runnable_tools

    first_run = 1 if args.skip_warmup else 0
    for task_index, benchmark_task in enumerate(benchmark_tasks):
        for run_number in range(first_run, args.runs + 1):
            if not benchmark_tools:
                continue
            offset = (task_index + run_number) % len(benchmark_tools)
            ordered_tools = benchmark_tools[offset:] + benchmark_tools[:offset]
            for execution_position, tool in enumerate(ordered_tools):
                entry = tool_entries[tool.name]
                task_results = entry["tasks"]
                assert isinstance(task_results, dict)
                task_entry = task_results[benchmark_task.name]
                assert isinstance(task_entry, dict)
                task_output = tool_outputs[tool.name] / benchmark_task.name
                fixture = task_output / f"workspace-{run_number}"
                prepare_fixture(fixture, benchmark_task)
                if tool.name == "moltis":
                    with tempfile.TemporaryDirectory(
                        prefix="agent-cli-benchmark-moltis-"
                    ) as temporary_config:
                        config = pathlib.Path(temporary_config)
                        prepare_moltis_config(
                            config,
                            fixture,
                            args.moltis_provider,
                            moltis_model_with_reasoning(args),
                            args.moltis_auth_config_dir.resolve(),
                        )
                        placeholders = {
                            "{cwd}": str(fixture),
                            "{config}": str(config),
                            "{prompt}": benchmark_task.prompt,
                        }
                        measured = run_measured(
                            [
                                placeholders.get(part, part)
                                for part in tool.command
                            ],
                            fixture,
                            tool.env,
                            task_output / f"task-{run_number}",
                            args.timeout,
                        )
                else:
                    placeholders = {
                        "{cwd}": str(fixture),
                        "{config}": "",
                        "{prompt}": benchmark_task.prompt,
                    }
                    measured = run_measured(
                        [placeholders.get(part, part) for part in tool.command],
                        fixture,
                        tool.env,
                        task_output / f"task-{run_number}",
                        args.timeout,
                    )
                measured["execution_position"] = execution_position
                measured.update(grade_fixture(fixture, benchmark_task))
                if run_number == 0:
                    task_entry["warmup"] = measured
                else:
                    runs = task_entry["runs"]
                    assert isinstance(runs, list)
                    runs.append(measured)

    (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
