#!/usr/bin/env python3
"""Create Proxmox VMs from profile defaults and ISO discovery rules.

This script is intended to run on a Proxmox node where `qm` is available.
"""

from __future__ import annotations

import argparse
import fnmatch
import glob
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any


PROFILE_DIR = Path(__file__).parent / "profiles"


@dataclass
class VmConfig:
    vmid: int
    name: str
    memory: int
    cores: int
    sockets: int
    disk_gb: int
    disk_storage: str
    iso_storage: str
    iso_file: str
    bridge: str
    cpu: str
    machine: str
    bios: str
    scsi_hw: str
    enable_agent: bool
    onboot: bool
    tags: str | None = None


def run_cmd(cmd: list[str], dry_run: bool) -> str:
    pretty = " ".join(cmd)
    print(f"$ {pretty}")
    if dry_run:
        return ""
    result = subprocess.run(cmd, check=True, capture_output=True, text=True)
    if result.stdout.strip():
        print(result.stdout.strip())
    return result.stdout.strip()


def list_profiles() -> list[Path]:
    if not PROFILE_DIR.exists():
        return []
    return sorted(PROFILE_DIR.glob("*.json"))


def load_profile(profile_name: str) -> dict[str, Any]:
    profile_path = PROFILE_DIR / f"{profile_name}.json"
    if not profile_path.exists():
        raise ValueError(f"Profile '{profile_name}' not found at {profile_path}")
    with profile_path.open("r", encoding="utf-8") as f:
        return json.load(f)


def detect_os_from_iso(iso_name: str) -> str:
    n = iso_name.lower()
    if "ubuntu" in n:
        return "ubuntu"
    if "debian" in n:
        return "debian"
    if "rocky" in n:
        return "rocky"
    if "centos" in n:
        return "centos"
    if "fedora" in n:
        return "fedora"
    if "windows" in n or "win" in n:
        return "windows"
    return "unknown"


def resolve_latest_iso(iso_glob: str) -> str:
    matches = [m for m in glob.glob(iso_glob) if os.path.isfile(m)]
    if not matches:
        raise ValueError(f"No ISO files matched: {iso_glob}")
    matches.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return matches[0]


def resolve_latest_iso_from_storage(storage: str, iso_match: str) -> str:
    if shutil.which("pvesm") is None:
        raise ValueError("`pvesm` not found; cannot query ISO storage. Use --iso override.")

    result = subprocess.run(
        ["pvesm", "list", storage, "--content", "iso"],
        check=True,
        capture_output=True,
        text=True,
    )

    volids: list[str] = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line or line.lower().startswith("volid"):
            continue
        first_col = line.split()[0]
        if ":iso/" not in first_col:
            continue
        file_name = first_col.split(":iso/", 1)[1]
        if fnmatch.fnmatch(file_name, iso_match):
            volids.append(first_col)

    if not volids:
        raise ValueError(f"No ISO files in storage '{storage}' matched: {iso_match}")

    volids.sort(reverse=True)
    latest_volid = volids[0]
    return latest_volid.split(":iso/", 1)[1]


def get_next_vmid() -> int | None:
    if shutil.which("pvesh") is None:
        return None
    try:
        result = subprocess.run(
            ["pvesh", "get", "/cluster/nextid"],
            check=True,
            capture_output=True,
            text=True,
        )
        return int(result.stdout.strip())
    except Exception:
        return None


def prompt_value(prompt: str, default: str | None = None) -> str:
    text = f"{prompt}"
    if default is not None:
        text += f" [{default}]"
    text += ": "
    value = input(text).strip()
    return value if value else (default or "")


def bool_to_int(v: bool) -> str:
    return "1" if v else "0"


def build_vm_config(
    args: argparse.Namespace,
    profile: dict[str, Any],
    vmid: int,
    name: str,
) -> VmConfig:
    defaults = profile.get("defaults", {})

    profile_iso_storage = profile.get("iso_storage", defaults.get("iso_storage", "local"))

    if args.iso:
        if ":iso/" in args.iso:
            storage_part, file_part = args.iso.split(":iso/", 1)
            iso_storage = storage_part
            iso_file = os.path.basename(file_part)
        else:
            iso_storage = profile_iso_storage
            iso_file = os.path.basename(args.iso)
    elif profile.get("iso_match"):
        iso_storage = profile_iso_storage
        iso_file = resolve_latest_iso_from_storage(iso_storage, profile["iso_match"])
    elif profile.get("iso_glob"):
        iso_storage = profile_iso_storage
        iso_path = resolve_latest_iso(profile["iso_glob"])
        iso_file = os.path.basename(iso_path)
    else:
        raise ValueError("Profile must include either 'iso_match' or 'iso_glob', or pass --iso")

    return VmConfig(
        vmid=vmid,
        name=name,
        memory=int(defaults.get("memory", 4096)),
        cores=int(defaults.get("cores", 2)),
        sockets=int(defaults.get("sockets", 1)),
        disk_gb=int(defaults.get("disk_gb", 32)),
        disk_storage=args.disk_storage or defaults.get("disk_storage", "local-lvm"),
        iso_storage=iso_storage,
        iso_file=iso_file,
        bridge=defaults.get("bridge", "vmbr0"),
        cpu=defaults.get("cpu", "host"),
        machine=defaults.get("machine", "q35"),
        bios=defaults.get("bios", "seabios"),
        scsi_hw=defaults.get("scsi_hw", "virtio-scsi-pci"),
        enable_agent=bool(defaults.get("enable_agent", True)),
        onboot=bool(defaults.get("onboot", True)),
        tags=defaults.get("tags"),
    )


def apply_profile_overrides(config: VmConfig, overrides: dict[str, Any]) -> VmConfig:
    allowed = {
        "memory",
        "cores",
        "sockets",
        "disk_gb",
        "disk_storage",
        "iso_storage",
        "bridge",
        "cpu",
        "machine",
        "bios",
        "scsi_hw",
        "enable_agent",
        "onboot",
        "tags",
    }
    safe_updates = {k: v for k, v in overrides.items() if k in allowed}
    if not safe_updates:
        return config
    return replace(config, **safe_updates)


def apply_os_tweaks(config: VmConfig, profile: dict[str, Any], os_family: str) -> VmConfig:
    os_overrides = profile.get("os_overrides", {})
    if os_family in os_overrides:
        config = apply_profile_overrides(config, os_overrides[os_family])

    if os_family in {"ubuntu", "debian"}:
        if not config.tags:
            config.tags = "linux;ubuntu"
    elif os_family == "windows":
        config.enable_agent = False
        if not config.tags:
            config.tags = "windows"
    return config


def create_vm(config: VmConfig, dry_run: bool, start: bool) -> None:
    if shutil.which("qm") is None and not dry_run:
        raise RuntimeError("`qm` command not found. Run this on a Proxmox node or use --dry-run.")

    run_cmd(
        [
            "qm",
            "create",
            str(config.vmid),
            "--name",
            config.name,
            "--memory",
            str(config.memory),
            "--cores",
            str(config.cores),
            "--sockets",
            str(config.sockets),
            "--cpu",
            config.cpu,
            "--machine",
            config.machine,
            "--bios",
            config.bios,
            "--scsihw",
            config.scsi_hw,
        ],
        dry_run,
    )

    if config.tags:
        run_cmd(["qm", "set", str(config.vmid), "--tags", config.tags], dry_run)

    run_cmd(
        ["qm", "set", str(config.vmid), "--net0", f"virtio,bridge={config.bridge}"],
        dry_run,
    )
    run_cmd(
        ["qm", "set", str(config.vmid), "--scsi0", f"{config.disk_storage}:{config.disk_gb}"],
        dry_run,
    )
    run_cmd(
        ["qm", "set", str(config.vmid), "--ide2", f"{config.iso_storage}:iso/{config.iso_file},media=cdrom"],
        dry_run,
    )
    run_cmd(["qm", "set", str(config.vmid), "--boot", "order=ide2;scsi0"], dry_run)
    run_cmd(["qm", "set", str(config.vmid), "--agent", f"enabled={bool_to_int(config.enable_agent)}"], dry_run)
    run_cmd(["qm", "set", str(config.vmid), "--onboot", bool_to_int(config.onboot)], dry_run)

    if start:
        run_cmd(["qm", "start", str(config.vmid)], dry_run)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create Proxmox VMs from an ISO profile")
    parser.add_argument("--profile", help="Profile name in profiles/<name>.json")
    parser.add_argument("--name", help="VM name; if --count > 1 this is the base name")
    parser.add_argument("--vmid", type=int, help="VM ID; if omitted, nextid is used")
    parser.add_argument("--count", type=int, default=1, help="Create N VMs")
    parser.add_argument("--iso", help="Override ISO file path")
    parser.add_argument("--disk-storage", help="Override disk storage target (e.g. local-lvm)")
    parser.add_argument("--start", action="store_true", help="Start the VM(s) after creation")
    parser.add_argument("--yes", action="store_true", help="Skip confirmation prompt")
    parser.add_argument("--non-interactive", action="store_true", help="Fail instead of prompting")
    parser.add_argument("--dry-run", action="store_true", help="Print commands without executing")
    parser.add_argument("--list-profiles", action="store_true", help="List available profiles and exit")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if args.dry_run:
        print("DRY RUN mode enabled: commands will be printed but no VM will be created.\n")

    if args.list_profiles:
        for p in list_profiles():
            print(p.stem)
        return 0

    if not args.profile:
        available = [p.stem for p in list_profiles()]
        if args.non_interactive:
            raise SystemExit("--profile is required in --non-interactive mode")
        print("Available profiles:")
        for item in available:
            print(f"- {item}")
        args.profile = prompt_value("Profile", available[0] if available else None)

    profile = load_profile(args.profile)
    name_base = args.name
    if not name_base:
        if args.non_interactive:
            raise SystemExit("--name is required in --non-interactive mode")
        name_base = prompt_value("Base VM name", args.profile)

    starting_vmid = args.vmid
    if starting_vmid is None:
        starting_vmid = get_next_vmid()
    if starting_vmid is None:
        if args.non_interactive:
            raise SystemExit("Unable to auto-detect next VMID. Pass --vmid.")
        entered = prompt_value("Starting VMID")
        starting_vmid = int(entered)

    count = max(1, args.count)
    plan: list[VmConfig] = []

    for i in range(count):
        vmid = starting_vmid + i
        name = name_base if count == 1 else f"{name_base}-{i + 1:02d}"
        cfg = build_vm_config(args, profile, vmid, name)
        os_family = profile.get("os_family") or detect_os_from_iso(cfg.iso_file)
        cfg = apply_os_tweaks(cfg, profile, os_family)
        plan.append(cfg)

    print("\nCreation plan:")
    for cfg in plan:
        print(
            f"- vmid={cfg.vmid} name={cfg.name} iso={cfg.iso_file} "
            f"disk={cfg.disk_storage}:{cfg.disk_gb}GB mem={cfg.memory}MB cores={cfg.cores}"
        )

    if not args.yes and not args.non_interactive:
        confirm = prompt_value("Proceed? (y/n)", "y").lower()
        if confirm not in {"y", "yes"}:
            print("Aborted.")
            return 1

    for cfg in plan:
        create_vm(cfg, dry_run=args.dry_run, start=args.start)

    if args.dry_run:
        print("\nDry run complete. No changes were made.")

    print("\nDone.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as exc:
        print(exc.stderr.strip() if exc.stderr else str(exc), file=sys.stderr)
        raise SystemExit(exc.returncode)
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        raise SystemExit(2)
