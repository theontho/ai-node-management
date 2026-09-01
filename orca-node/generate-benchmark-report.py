#!/usr/bin/env python3
"""Generate a Markdown report from expanded agent CLI benchmark results."""

from __future__ import annotations

import argparse
import json
import pathlib
import statistics


LABELS = {
    "opencode": "OpenCode",
    "pi": "Pi",
    "copilot": "Copilot CLI",
    "moltis": "Moltis",
    "hermes": "Hermes",
    "crush": "Crush",
    "codex": "Codex CLI",
    "claude": "Claude Code",
    "openclaw": "OpenClaw",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("results", type=pathlib.Path)
    parser.add_argument("report", type=pathlib.Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    results = json.loads(args.results.read_text())
    repetitions = results["runs"]

    rows = []
    task_rows = []
    for name, result in results["tools"].items():
        if not result.get("available", True):
            rows.append(
                (
                    1,
                    float("inf"),
                    "| {} | {} | SKIPPED | -- | -- | -- | -- | -- | -- | "
                    "0/0 | 0 |".format(
                        LABELS.get(name, name),
                        result["model"],
                    ),
                )
            )
            for task_name in result["tasks"]:
                task_rows.append(
                    (
                        task_name,
                        float("inf"),
                        f"| {task_name} | {LABELS.get(name, name)} | -- | "
                        "-- | SKIPPED |",
                    )
                )
            continue

        startups = result["startup"]
        task_medians = []
        cpu_medians = []
        rss_medians = []
        passed_runs = 0
        timed_out_runs = 0
        complete_task_metrics = True
        for task_name, task_result in result["tasks"].items():
            runs = task_result["runs"]
            if not runs:
                complete_task_metrics = False
                continue
            passing_runs = [run for run in runs if run.get("fixture_passed")]
            task_passed = sum(bool(run.get("fixture_passed")) for run in runs)
            timed_out_runs += sum(bool(run.get("timed_out")) for run in runs)
            if passing_runs:
                task_wall = statistics.median(
                    run["wall_seconds"] for run in passing_runs
                )
                task_medians.append(task_wall)
                cpu_medians.append(
                    statistics.median(
                        run["user_cpu_seconds"] + run["system_cpu_seconds"]
                        for run in passing_runs
                    )
                )
                rss_medians.append(
                    statistics.median(
                        run["peak_rss_bytes"] for run in passing_runs
                    )
                )
                wall_text = f"{task_wall:.3f} s"
            else:
                complete_task_metrics = False
                task_wall = float("inf")
                wall_text = "--"
            passed_runs += task_passed
            task_rows.append(
                (
                    task_name,
                    task_wall,
                    "| {} | {} | {} | {}/{} | {} |".format(
                        task_name,
                        LABELS.get(name, name),
                        wall_text,
                        task_passed,
                        len(runs),
                        "PASSED" if task_passed == len(runs) else "FAILED",
                    ),
                )
            )

        expected_runs = len(results["task_suite"]) * repetitions
        status = "PASSED" if passed_runs == expected_runs else "FAILED"
        suite_wall = sum(task_medians) if complete_task_metrics else float("inf")
        suite_wall_text = f"{suite_wall:.3f} s" if complete_task_metrics else "--"
        suite_cpu_text = (
            f"{sum(cpu_medians):.3f} s" if complete_task_metrics else "--"
        )
        peak_rss_text = (
            f"{max(rss_medians) / 1024 / 1024:.1f} MiB"
            if complete_task_metrics
            else "--"
        )
        version_lines = result["version"].splitlines()
        version = version_lines[0] if version_lines else "unknown version"
        rows.append(
            (
                -passed_runs,
                suite_wall,
                "| {} {} | {} | {} | {:.1f} MiB | {:.3f} s | {:.1f} MiB | {} | "
                "{} | {} | {}/{} | {} |".format(
                    LABELS.get(name, name),
                    version,
                    result["model"],
                    status,
                    result["install_bytes"] / 1024 / 1024,
                    statistics.median(
                        run["wall_seconds"] for run in startups
                    ),
                    statistics.median(
                        run["peak_rss_bytes"] for run in startups
                    )
                    / 1024
                    / 1024,
                    suite_wall_text,
                    suite_cpu_text,
                    peak_rss_text,
                    passed_runs,
                    expected_runs,
                    timed_out_runs,
                ),
            )
        )

    rows.sort()
    task_rows.sort()
    tool_count = len(results["tools"])
    warmup_text = (
        "one unmeasured warm-up and " if not results.get("skip_warmup") else ""
    )
    lines = [
        "# Agent CLI benchmark suite",
        "",
        "## Task suite",
        "",
        "Each client receives a fresh Git repository for every task. The harness",
        "independently runs visible and hidden checks, rejects protected-file changes,",
        "and rejects edits outside each task's allowed implementation files.",
        "",
        "| Task | Language | Difficulty | Focus |",
        "|---|---|---|---|",
        *(
            "| {} | {} | {} | {} |".format(
                task["name"],
                task["language"],
                task["difficulty"],
                task["summary"],
            )
            for task in results["task_suite"]
        ),
        "",
        f"{tool_count} client(s) requested with {warmup_text}{repetitions} "
        "measured repetition(s) per task. Available clients run serially; missing",
        "clients are skipped. Provider/model selections are shown below.",
        "Suite wall and CPU are sums of per-task medians; peak RSS is the largest",
        "per-task median. Model/network latency is included in wall time.",
        "",
        "## Aggregate results",
        "",
        "| Client | Model | Status | Installed | Startup | Startup RSS | Suite wall | Suite CPU | Task peak RSS | Passed | Timeouts |",
        "|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|",
        *(row for _, _, row in rows),
        "",
        "## Per-task results",
        "",
        "| Task | Client | Median wall | Passed | Status |",
        "|---|---|---:|---:|---|",
        *(row for _, _, row in task_rows),
        "",
        f"Raw measurements: `{args.results.resolve()}`",
        "",
    ]
    text = "\n".join(lines)
    args.report.write_text(text)
    print(text)
    print(f"Saved report: {args.report.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
