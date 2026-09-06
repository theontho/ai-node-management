#!/usr/bin/env python3
"""Generate a local, credential-safe AI node inventory dashboard."""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import heapq
import json
import os
import pathlib
import platform
import re
import shutil
import socket
import subprocess
import sys
from typing import Any

if os.name != "nt":
    import pwd


ROOT = pathlib.Path(__file__).resolve().parent
DEFAULT_OUTPUT = ROOT / "output" / "latest"
TOOLS = {
    "Python": ([sys.executable, "--version"], r"Python\s+(.+)"),
    "Git": (["git", "--version"], r"git version\s+(.+)"),
    "GitHub CLI": (["gh", "--version"], r"gh version\s+([^\s]+)"),
    "Copilot CLI": (["copilot", "--version"], r"\b(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?)\b"),
    "Node.js": (["node", "--version"], r"v?(.+)"),
    "npm": (["npm", "--version"], r"(.+)"),
    "Go": (["go", "version"], r"go version go([^\s]+)"),
    "Rust": (["rustc", "--version"], r"rustc\s+([^\s]+)"),
    "Cargo": (["cargo", "--version"], r"cargo\s+([^\s]+)"),
    "Java": (["java", "-version"], r'version "([^"]+)"'),
    "Docker": (["docker", "--version"], r"Docker version\s+([^,\s]+)"),
    "Tailscale": (["tailscale", "version"], r"^([^\s]+)"),
    "Orca": (["orca", "--version"], r"\b(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?)\b"),
    "Claude Code": (["claude", "--version"], r"\b(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?)\b"),
    "Codex": (["codex", "--version"], r"\b(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?)\b"),
    "OpenCode": (["opencode", "--version"], r"\b(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?)\b"),
    "Moltis": (["moltis", "--version"], r"\b(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?)\b"),
}


def run(command: list[str] | str, timeout: int = 8) -> tuple[str | None, str | None]:
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            encoding="utf-8",
            errors="replace",
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        return None, str(exc)
    output = "\n".join(part.strip() for part in (result.stdout, result.stderr) if part.strip())
    if result.returncode:
        return None, output or f"exit status {result.returncode}"
    return output, None


def read_text(path: pathlib.Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except (OSError, PermissionError):
        return None


def parse_os_release() -> dict[str, str]:
    values: dict[str, str] = {}
    text = read_text(pathlib.Path("/etc/os-release")) or ""
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value.strip().strip('"')
    return values


def powershell_json(script: str) -> tuple[Any | None, str | None]:
    executable = shutil.which("pwsh") or shutil.which("powershell")
    if not executable:
        return None, "PowerShell is unavailable"
    output, error = run(
        [
            executable,
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            f"$ErrorActionPreference='Stop'; {script} | ConvertTo-Json -Depth 8 -Compress",
        ],
        timeout=30,
    )
    if error:
        return None, error
    try:
        return json.loads(output or "null"), None
    except json.JSONDecodeError as exc:
        return None, f"PowerShell returned invalid JSON: {exc}"


def collect_windows(warnings: list[str]) -> dict[str, Any]:
    script = r"""
$os = Get-CimInstance Win32_OperatingSystem
$system = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$board = Get-CimInstance Win32_BaseBoard
$cpu = @(Get-CimInstance Win32_Processor | ForEach-Object {
  [ordered]@{name=([string]$_.Name).Trim(); cores=[int]$_.NumberOfCores; threads=[int]$_.NumberOfLogicalProcessors; maxMhz=[int]$_.MaxClockSpeed}
})
$memoryModules = @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
  $memoryType = switch ($_.SMBIOSMemoryType) {26 {"DDR4"} 34 {"DDR5"} default {"SMBIOS $($_.SMBIOSMemoryType)"}}
  [ordered]@{capacityBytes=[long]$_.Capacity; speedMts=[int]$_.ConfiguredClockSpeed; type=$memoryType}
})
$gpu = @(Get-CimInstance Win32_VideoController | ForEach-Object {
  [ordered]@{name=$_.Name; memoryBytes=[long]$_.AdapterRAM; driver=$_.DriverVersion}
})
$physical = @(Get-CimInstance Win32_DiskDrive | ForEach-Object {
  [ordered]@{name=$_.Model; serial=([string]$_.SerialNumber).Trim(); type=$_.MediaType; bus=$_.InterfaceType; sizeBytes=[long]$_.Size; status=$_.Status}
})
$volumes = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
  [ordered]@{mount=$_.DeviceID; label=$_.VolumeName; fileSystem=$_.FileSystem; capacityBytes=[long]$_.Size; freeBytes=[long]$_.FreeSpace; usedBytes=[long]($_.Size-$_.FreeSpace)}
})
$network = @(Get-CimInstance Win32_NetworkAdapter | Where-Object PhysicalAdapter | ForEach-Object {
  $configuration = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "Index=$($_.Index)"
  [ordered]@{name=$_.Name; state=if ($_.NetEnabled) {"up"} else {"down"}; speedMbps=if ($_.NetEnabled -and $_.Speed -gt 0 -and $_.Speed -lt 1e12) {[math]::Round([double]$_.Speed/1e6)} else {$null}; macAddress=$_.MACAddress; ipAddresses=@($configuration.IPAddress | Where-Object { $_ })}
})
$accounts = @(Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" | ForEach-Object {
  [ordered]@{name=$_.Name; fullName=$_.FullName; disabled=[bool]$_.Disabled; locked=[bool]$_.Lockout; sid=$_.SID}
})
$services = @("sshd","Tailscale","docker","com.docker.service" | ForEach-Object {
  $service = Get-Service -Name $_ -ErrorAction SilentlyContinue
  if ($service) {[ordered]@{name=$service.DisplayName; state=$service.Status.ToString()}}
})
[ordered]@{
  system=[ordered]@{
    osName=$os.Caption; osVersion=$os.Version; osBuild=$os.BuildNumber
    architecture=$os.OSArchitecture; kernel=$os.Version
    uptimeSeconds=[long]((Get-Date)-$os.LastBootUpTime).TotalSeconds
    manufacturer=$system.Manufacturer; model=$system.Model
    firmware=("$($bios.Manufacturer) $($bios.SMBIOSBIOSVersion)").Trim()
    systemSerial=$bios.SerialNumber; boardSerial=$board.SerialNumber
    currentAccount=([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
  }
  cpu=$cpu; memory=[ordered]@{totalBytes=[long]$system.TotalPhysicalMemory; modules=$memoryModules}
  gpus=$gpu; physicalStorage=$physical; volumes=$volumes; network=$network; accounts=$accounts; services=$services
}
"""
    data, error = powershell_json(script)
    if error:
        warnings.append(f"Windows CIM inventory failed: {error}")
        return {}
    result = data or {}
    detected_gpus = nvidia_gpus()
    if detected_gpus:
        result["gpus"] = detected_gpus
    return result


def cpu_linux() -> list[dict[str, Any]]:
    text = read_text(pathlib.Path("/proc/cpuinfo")) or ""
    names = re.findall(r"^model name\s*:\s*(.+)$", text, re.MULTILINE)
    name = names[0] if names else platform.processor() or "Unknown"
    physical: set[tuple[str, str]] = set()
    current: dict[str, str] = {}
    for line in text.splitlines() + [""]:
        if ":" in line:
            key, value = line.split(":", 1)
            current[key.strip()] = value.strip()
        elif current:
            physical.add((current.get("physical id", "0"), current.get("core id", current.get("processor", "0"))))
            current = {}
    return [{"name": name, "cores": len(physical) or os.cpu_count(), "threads": os.cpu_count()}]


def memory_linux() -> dict[str, Any]:
    text = read_text(pathlib.Path("/proc/meminfo")) or ""
    match = re.search(r"^MemTotal:\s+(\d+)\s+kB", text, re.MULTILINE)
    return {"totalBytes": int(match.group(1)) * 1024 if match else None}


def nvidia_gpus() -> list[dict[str, Any]]:
    output, _ = run(
        ["nvidia-smi", "--query-gpu=name,memory.total,driver_version", "--format=csv,noheader,nounits"]
    )
    if output:
        result = []
        for line in output.splitlines():
            values = [value.strip() for value in line.split(",")]
            if len(values) == 3:
                result.append(
                    {"name": values[0], "memoryBytes": int(float(values[1]) * 1024 * 1024), "driver": values[2]}
                )
        return result
    return []


def gpu_linux() -> list[dict[str, Any]]:
    nvidia = nvidia_gpus()
    if nvidia:
        return nvidia
    output, _ = run(["lspci"])
    if not output:
        return []
    return [
        {"name": line.split(": ", 1)[-1], "memoryBytes": None, "driver": None}
        for line in output.splitlines()
        if re.search(r"(VGA|3D|Display) controller", line, re.IGNORECASE)
    ]


def storage_linux(warnings: list[str]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    fields = "NAME,MODEL,SERIAL,TRAN,TYPE,SIZE,FSTYPE,MOUNTPOINTS"
    output, error = run(["lsblk", "--json", "--bytes", "--output", fields])
    if error:
        warnings.append(f"Block-device inventory failed: {error}")
        return [], mounted_volumes()
    try:
        devices = json.loads(output or "{}").get("blockdevices", [])
    except json.JSONDecodeError as exc:
        warnings.append(f"Block-device inventory returned invalid JSON: {exc}")
        return [], mounted_volumes()
    physical = []
    for device in devices:
        if device.get("type") != "disk":
            continue
        physical.append(
            {
                "name": (device.get("model") or device.get("name") or "").strip(),
                "serial": device.get("serial"),
                "type": "disk",
                "bus": device.get("tran"),
                "sizeBytes": device.get("size"),
                "status": "available",
            }
        )
    return physical, mounted_volumes(devices)


def mounted_volumes(devices: list[dict[str, Any]] | None = None) -> list[dict[str, Any]]:
    candidates: dict[str, dict[str, Any]] = {}

    def walk(items: list[dict[str, Any]]) -> None:
        for item in items:
            points = item.get("mountpoints") or []
            if isinstance(points, str):
                points = [points]
            for mount in points:
                if mount and not str(mount).startswith(("/snap/", "/boot/efi")):
                    candidates[str(mount)] = item
            walk(item.get("children") or [])

    if devices:
        walk(devices)
    if not candidates:
        candidates["/"] = {}
    result = []
    for mount, device in sorted(candidates.items()):
        try:
            usage = shutil.disk_usage(mount)
        except OSError:
            continue
        result.append(
            {
                "mount": mount,
                "label": device.get("name"),
                "fileSystem": device.get("fstype"),
                "capacityBytes": usage.total,
                "usedBytes": usage.used,
                "freeBytes": usage.free,
            }
        )
    return result


def network_linux() -> list[dict[str, Any]]:
    root = pathlib.Path("/sys/class/net")
    result = []
    if not root.exists():
        return result
    address_data: dict[str, list[str]] = {}
    output, _ = run(["ip", "-json", "address", "show"])
    if output:
        try:
            for item in json.loads(output):
                address_data[item.get("ifname", "")] = [
                    address.get("local")
                    for address in item.get("addr_info", [])
                    if address.get("local")
                ]
        except json.JSONDecodeError:
            pass
    for interface in sorted(root.iterdir()):
        if interface.name == "lo":
            continue
        state = read_text(interface / "operstate") or "unknown"
        speed_text = read_text(interface / "speed")
        speed = int(speed_text) if speed_text and speed_text.isdigit() else None
        result.append(
            {
                "name": interface.name,
                "state": state,
                "speedMbps": speed,
                "macAddress": read_text(interface / "address"),
                "ipAddresses": address_data.get(interface.name, []),
            }
        )
    return result


def accounts_linux() -> list[dict[str, Any]]:
    return [
        {
            "name": account.pw_name,
            "fullName": account.pw_gecos.split(",", 1)[0],
            "uid": account.pw_uid,
            "home": account.pw_dir,
            "shell": account.pw_shell,
        }
        for account in pwd.getpwall()
    ]


def services_linux() -> list[dict[str, str]]:
    services = []
    for name in ("sshd", "ssh", "tailscaled", "docker", "orca-node"):
        output, error = run(["systemctl", "is-active", name], timeout=3)
        state = (output or error or "unknown").strip()
        if state in {"active", "inactive", "failed", "activating", "deactivating"}:
            services.append({"name": name, "state": state})
    return services


def collect_linux(warnings: list[str]) -> dict[str, Any]:
    release = parse_os_release()
    physical, volumes = storage_linux(warnings)
    uptime_text = read_text(pathlib.Path("/proc/uptime"))
    uptime = int(float(uptime_text.split()[0])) if uptime_text else None
    return {
        "system": {
            "osName": release.get("PRETTY_NAME", platform.system()),
            "osVersion": release.get("VERSION_ID", platform.release()),
            "osBuild": None,
            "architecture": platform.machine(),
            "kernel": platform.release(),
            "uptimeSeconds": uptime,
            "manufacturer": read_text(pathlib.Path("/sys/class/dmi/id/sys_vendor")),
            "model": read_text(pathlib.Path("/sys/class/dmi/id/product_name")),
            "firmware": read_text(pathlib.Path("/sys/class/dmi/id/bios_version")),
            "systemSerial": read_text(pathlib.Path("/sys/class/dmi/id/product_serial")),
            "boardSerial": read_text(pathlib.Path("/sys/class/dmi/id/board_serial")),
            "currentAccount": f"{pwd.getpwuid(os.getuid()).pw_name} (uid {os.getuid()})",
        },
        "cpu": cpu_linux(),
        "memory": memory_linux(),
        "gpus": gpu_linux(),
        "physicalStorage": physical,
        "volumes": volumes,
        "network": network_linux(),
        "accounts": accounts_linux(),
        "services": services_linux(),
    }


def scan_volume(
    volume: dict[str, Any],
    top_limit: int,
    file_limit: int,
    significant_min_bytes: int = 100 * 1024 * 1024,
) -> dict[str, Any]:
    mount = str(volume["mount"])
    root = pathlib.Path(f"{mount}\\") if os.name == "nt" and re.fullmatch(r"[A-Za-z]:", mount) else pathlib.Path(mount)
    largest_files: list[tuple[int, str]] = []
    largest_directories: list[tuple[int, str, int]] = []
    top_items: list[dict[str, Any]] = []
    files_scanned = 0
    bytes_scanned = 0
    errors = 0

    def new_frame(path: pathlib.Path, is_top: bool) -> dict[str, Any] | None:
        nonlocal errors
        try:
            entries = os.scandir(path)
        except OSError:
            errors += 1
            return None
        return {
            "path": path,
            "entries": entries,
            "bytes": 0,
            "files": 0,
            "isTop": is_top,
            "childDirectories": [],
        }

    first = new_frame(root, False)
    stack = [first] if first else []
    while stack:
        frame = stack[-1]
        try:
            entry = next(frame["entries"])
        except StopIteration:
            frame["entries"].close()
            stack.pop()
            if frame["path"] != root:
                directory_candidate = (frame["bytes"], str(frame["path"]), frame["files"])
                if len(largest_directories) < top_limit:
                    heapq.heappush(largest_directories, directory_candidate)
                elif directory_candidate > largest_directories[0]:
                    heapq.heapreplace(largest_directories, directory_candidate)
            if stack:
                stack[-1]["bytes"] += frame["bytes"]
                stack[-1]["files"] += frame["files"]
                child_candidate = (frame["bytes"], str(frame["path"]), frame["files"])
                child_directories = stack[-1]["childDirectories"]
                if len(child_directories) < top_limit:
                    heapq.heappush(child_directories, child_candidate)
                elif child_candidate > child_directories[0]:
                    heapq.heapreplace(child_directories, child_candidate)
            if frame["isTop"]:
                significant_threshold = max(significant_min_bytes, int(frame["bytes"] * 0.02))
                significant_subdirectories = [
                    {"path": path, "bytes": size, "files": files}
                    for size, path, files in sorted(frame["childDirectories"], reverse=True)
                    if size >= significant_threshold
                ]
                top_items.append(
                    {
                        "path": str(frame["path"]),
                        "kind": "directory",
                        "bytes": frame["bytes"],
                        "files": frame["files"],
                        "significantSubdirectories": significant_subdirectories,
                    }
                )
            continue
        except OSError:
            errors += 1
            continue

        if entry.is_symlink():
            continue
        try:
            if entry.is_dir(follow_symlinks=False):
                child = new_frame(pathlib.Path(entry.path), frame["path"] == root)
                if child:
                    stack.append(child)
                continue
            if not entry.is_file(follow_symlinks=False):
                continue
            file_size = entry.stat(follow_symlinks=False).st_size
        except OSError:
            errors += 1
            continue
        files_scanned += 1
        bytes_scanned += file_size
        frame["bytes"] += file_size
        frame["files"] += 1
        if frame["path"] == root:
            top_items.append({"path": entry.path, "kind": "file", "bytes": file_size, "files": 1})
        candidate = (file_size, entry.path)
        if len(largest_files) < file_limit:
            heapq.heappush(largest_files, candidate)
        elif candidate > largest_files[0]:
            heapq.heapreplace(largest_files, candidate)

    top_items.sort(key=lambda item: item["bytes"], reverse=True)
    files = [
        {"path": path, "bytes": size}
        for size, path in sorted(largest_files, reverse=True)
    ]
    directories = [
        {"path": path, "bytes": size, "files": files}
        for size, path, files in sorted(largest_directories, reverse=True)
    ]
    return {
        "mount": volume["mount"],
        "filesScanned": files_scanned,
        "bytesScanned": bytes_scanned,
        "errors": errors,
        "largestTopLevelItems": top_items[:top_limit],
        "largestDirectories": directories,
        "largestFiles": files,
    }


def scan_storage(volumes: list[dict[str, Any]], top_limit: int, file_limit: int) -> dict[str, Any]:
    eligible = [
        volume
        for volume in volumes
        if volume.get("mount") and int(volume.get("capacityBytes") or 0) >= 512 * 1024 * 1024
    ]
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(4, len(eligible) or 1)) as executor:
        scans = list(executor.map(lambda volume: scan_volume(volume, top_limit, file_limit), eligible))
    return {
        "generatedAt": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "method": "single-pass logical file sizes; symlinks and reparse points excluded",
        "volumes": scans,
    }


def collect_tools() -> list[dict[str, str]]:
    tools = []
    for name, (command, pattern) in TOOLS.items():
        resolved = command[0] if name == "Python" else shutil.which(command[0])
        if not resolved:
            continue
        invocation = [resolved, *command[1:]]
        if os.name == "nt" and pathlib.Path(resolved).suffix.lower() in {".bat", ".cmd"}:
            comspec = os.environ.get("COMSPEC", "cmd.exe")
            arguments = subprocess.list2cmdline(command[1:])
            invocation = f'"{comspec}" /d /s /c ""{resolved}" {arguments}"'
        output, error = run(invocation)
        if error or not output:
            continue
        output = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", output)
        match = re.search(pattern, output, re.MULTILINE | re.IGNORECASE)
        version = match.group(1).strip().rstrip(".,;") if match else "installed (version unavailable)"
        tools.append({"name": name, "version": version[:160]})
    return tools


def fixture() -> dict[str, Any]:
    gib = 1024**3
    return {
        "system": {
            "osName": "Example Linux 24.04",
            "osVersion": "24.04",
            "osBuild": None,
            "architecture": "x86_64",
            "kernel": "6.8.0-example",
            "uptimeSeconds": 93784,
            "manufacturer": "Example Systems",
            "model": "AI Node",
            "firmware": "1.2.3",
            "systemSerial": "EXAMPLE-SYSTEM-001",
            "boardSerial": "EXAMPLE-BOARD-001",
            "currentAccount": "node-admin (uid 1000)",
        },
        "cpu": [{"name": "Example 8-Core Processor", "cores": 8, "threads": 16}],
        "memory": {
            "totalBytes": 64 * gib,
            "modules": [
                {"capacityBytes": 32 * gib, "speedMts": 3200, "type": "DDR4"},
                {"capacityBytes": 32 * gib, "speedMts": 3200, "type": "DDR4"},
            ],
        },
        "gpus": [{"name": "Example Compute GPU", "memoryBytes": 24 * gib, "driver": "555.1"}],
        "physicalStorage": [
            {"name": "Example NVMe", "serial": "EXAMPLE-DISK-001", "type": "disk", "bus": "nvme", "sizeBytes": 2 * 1000**4, "status": "available"}
        ],
        "volumes": [
            {
                "mount": "/",
                "label": "root",
                "fileSystem": "ext4",
                "capacityBytes": 2 * 1000**4,
                "usedBytes": 750 * 1000**3,
                "freeBytes": 1250 * 1000**3,
            }
        ],
        "network": [{"name": "eth0", "state": "up", "speedMbps": 2500, "macAddress": "02:00:00:00:00:01", "ipAddresses": ["192.0.2.10"]}],
        "accounts": [{"name": "node-admin", "fullName": "Node Administrator", "uid": 1000, "home": "/home/node-admin", "shell": "/bin/bash"}],
        "services": [{"name": "sshd", "state": "active"}, {"name": "tailscaled", "state": "active"}],
    }


def payload(use_fixture: bool, include_storage_scan: bool, top_limit: int, file_limit: int) -> dict[str, Any]:
    warnings: list[str] = []
    collected = fixture() if use_fixture else (
        collect_windows(warnings) if os.name == "nt" else collect_linux(warnings)
    )
    generated = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    result = {
        "schemaVersion": 1,
        "generatedAt": generated,
        "node": {
            "hostname": "example-ai-node" if use_fixture else socket.gethostname(),
            "platform": "fixture" if use_fixture else platform.system().lower(),
        },
        **collected,
        "tools": (
            [{"name": "Python", "version": platform.python_version()}, {"name": "Git", "version": "2.50.0"}]
            if use_fixture
            else collect_tools()
        ),
        "warnings": warnings,
        "dataHandling": {
            "classification": "private",
            "warning": "Contains account names, addresses, serial numbers, and file paths. Do not publish without review.",
            "omitted": [
                "credentials and authentication secrets",
                "environment-variable values",
                "file contents",
            ],
        },
    }
    if include_storage_scan:
        if use_fixture:
            result["storageScan"] = {
                "generatedAt": generated,
                "method": "fixture",
                "volumes": [{
                    "mount": "/",
                    "filesScanned": 42,
                    "bytesScanned": 128 * 1024**3,
                    "errors": 0,
                    "largestTopLevelItems": [{
                        "path": "/srv",
                        "kind": "directory",
                        "bytes": 96 * 1024**3,
                        "files": 30,
                        "significantSubdirectories": [
                            {"path": "/srv/models", "bytes": 80 * 1024**3, "files": 12}
                        ],
                    }],
                    "largestDirectories": [{"path": "/srv/models", "bytes": 80 * 1024**3, "files": 12}],
                    "largestFiles": [{"path": "/srv/models/example.bin", "bytes": 24 * 1024**3}],
                }],
            }
        else:
            result["storageScan"] = scan_storage(result.get("volumes", []), top_limit, file_limit)
    return result


def write_report(data: dict[str, Any], output: pathlib.Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    template = (ROOT / "index.html").read_text(encoding="utf-8")
    favicon = (ROOT / "favicon.svg").read_text(encoding="utf-8")
    json_text = json.dumps(data, ensure_ascii=True, separators=(",", ":"))
    (output / "index.html").write_text(template, encoding="utf-8")
    (output / "favicon.svg").write_text(favicon, encoding="utf-8")
    (output / "inventory.json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    (output / "inventory-data.js").write_text(
        f"window.SYSTEM_INVENTORY = {json_text};\n", encoding="utf-8"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=DEFAULT_OUTPUT,
        help=f"report directory (default: {DEFAULT_OUTPUT})",
    )
    parser.add_argument(
        "--skip-storage-scan",
        action="store_true",
        help="skip recursive sizing and largest-file collection",
    )
    parser.add_argument("--top-items", type=int, default=20, help="top-level storage items per volume")
    parser.add_argument("--largest-files", type=int, default=50, help="largest files per volume")
    parser.add_argument("--fixture", action="store_true", help=argparse.SUPPRESS)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.top_items < 1 or args.largest_files < 1:
        raise SystemExit("--top-items and --largest-files must be positive")
    data = payload(args.fixture, not args.skip_storage_scan, args.top_items, args.largest_files)
    write_report(data, args.output.resolve())
    print(f"Wrote inventory for {data['node']['hostname']} to {args.output.resolve()}")
    if data["warnings"]:
        print(f"Completed with {len(data['warnings'])} collection warning(s).", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
