#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Keye3Tuido
"""Rewrite bundled dylib dependencies; reject accidental external links."""
from pathlib import Path
import subprocess
import sys

engine = Path(sys.argv[1])
frameworks = engine / "Contents/Frameworks"
libraries = {p.name: p for p in frameworks.glob("*.dylib")}
executables = [engine / "Contents/Helpers" / name for name in ("scrcpy", "adb")]
for binary in [*executables, *libraries.values()]:
    if binary not in executables:
        subprocess.run(["install_name_tool", "-id", "@loader_path/" + binary.name, str(binary)], check=True)
    links = subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()[1:]
    for line in links:
        dependency = line.strip().split(" (", 1)[0]
        name = Path(dependency).name
        if name in libraries:
            replacement = "@loader_path/" + ("../Frameworks/" if binary in executables else "") + name
            if dependency != replacement:
                subprocess.run(["install_name_tool", "-change", dependency, replacement, str(binary)], check=True)
        elif not dependency.startswith(("/usr/lib/", "/System/Library/")):
            raise SystemExit("Unbundled dependency: " + dependency)

    commands = subprocess.check_output(["otool", "-l", str(binary)], text=True).splitlines()
    for i, line in enumerate(commands):
        if line.strip() == "cmd LC_RPATH":
            rpath = commands[i + 2].strip().removeprefix("path ").split(" (offset", 1)[0]
            if rpath.startswith(("/opt/", "/Users/", "/private/", "/tmp/")):
                subprocess.run(["install_name_tool", "-delete_rpath", rpath, str(binary)], check=True)
