#!/usr/bin/env python3
"""
Fetch Windows dependencies for cross-compilation.

Downloads the Vulkan loader import library (vulkan-1.lib) and places it at
libs/windows/vulkan/lib/ so build.zig can link against it when targeting
x86_64-windows.

Usage:
    python3 scripts/fetch_windows_deps.py
    # or
    make setup-windows
"""

import os
import sys
import urllib.request
import zipfile
import tempfile
import shutil
import subprocess
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent
VULKAN_LIB_DIR = PROJECT_ROOT / "libs" / "windows" / "vulkan" / "lib"


def download_from_nuget() -> bool:
    """Download Vulkan loader from Silk.NET NuGet package."""
    url = "https://api.nuget.org/v3-flatcontainer/silk.net.vulkan.loader.native/2024.10.25/silk.net.vulkan.loader.native.2024.10.25.nupkg"

    print("Downloading from NuGet (Silk.NET.Vulkan.Loader.Native)...")
    print(f"  URL: {url}")

    VULKAN_LIB_DIR.mkdir(parents=True, exist_ok=True)

    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            nupkg_path = os.path.join(tmpdir, "vulkan-loader.nupkg")

            req = urllib.request.Request(url, headers={'User-Agent': 'notatlas/1.0'})
            with urllib.request.urlopen(req) as response:
                with open(nupkg_path, 'wb') as f:
                    f.write(response.read())
            print(f"  Downloaded: {os.path.getsize(nupkg_path) / 1024:.1f} KB")

            with zipfile.ZipFile(nupkg_path, 'r') as zf:
                lib_file = None
                for name in zf.namelist():
                    lower = name.lower()
                    if "win-x64" in lower or "win64" in lower:
                        if name.endswith("vulkan-1.lib"):
                            lib_file = name

                if lib_file:
                    print(f"  Extracting: {lib_file}")
                    zf.extract(lib_file, tmpdir)
                    src = os.path.join(tmpdir, lib_file)
                    dst = VULKAN_LIB_DIR / "vulkan-1.lib"
                    shutil.copy2(src, dst)
                    print(f"  Installed: {dst}")
                    print(f"  Size: {dst.stat().st_size / 1024:.1f} KB")
                    return True

                print("  vulkan-1.lib not found in package")
                print("  Available Windows files:")
                for name in zf.namelist():
                    if "win" in name.lower():
                        print(f"    {name}")
                return False

    except urllib.error.HTTPError as e:
        print(f"  HTTP Error: {e.code} {e.reason}")
        return False
    except Exception as e:
        print(f"  Error: {e}")
        import traceback
        traceback.print_exc()
        return False


def download_def_and_create_lib() -> bool:
    """
    Download the official vulkan-1.def from Khronos and create an import library.
    Linking against this lib still requires vulkan-1.dll at runtime on the
    Windows machine (shipped with the Vulkan Runtime / GPU drivers).
    """
    print("Downloading vulkan-1.def from Khronos...")

    VULKAN_LIB_DIR.mkdir(parents=True, exist_ok=True)

    def_url = "https://raw.githubusercontent.com/KhronosGroup/Vulkan-Loader/main/loader/vulkan-1.def"
    def_path = VULKAN_LIB_DIR / "vulkan-1.def"
    lib_path = VULKAN_LIB_DIR / "vulkan-1.lib"

    try:
        req = urllib.request.Request(def_url, headers={'User-Agent': 'notatlas/1.0'})
        with urllib.request.urlopen(req) as response:
            def_content = response.read().decode('utf-8')
            def_path.write_text(def_content)
        print(f"  Downloaded: {def_path.name} ({len(def_content)} bytes)")

        print("  Creating import library with zig dlltool...")
        result = subprocess.run(
            ["zig", "dlltool", "-m", "i386:x86-64", "-d", str(def_path), "-l", str(lib_path)],
            capture_output=True,
            text=True,
        )

        if result.returncode == 0 and lib_path.exists():
            print(f"  Created: {lib_path}")
            print(f"  Size: {lib_path.stat().st_size / 1024:.1f} KB")
            def_path.unlink()
            return True

        stderr = result.stderr.strip() if result.stderr else "(no output)"
        print(f"  zig dlltool failed: {stderr}")

        print("  Trying llvm-dlltool...")
        result2 = subprocess.run(
            ["llvm-dlltool", "-m", "i386:x86-64", "-d", str(def_path), "-l", str(lib_path)],
            capture_output=True,
            text=True,
        )
        if result2.returncode == 0 and lib_path.exists():
            print(f"  Created: {lib_path}")
            print(f"  Size: {lib_path.stat().st_size / 1024:.1f} KB")
            def_path.unlink()
            return True

        print("  llvm-dlltool also failed")
        print(f"  Kept {def_path} for manual import library creation")
        return False

    except urllib.error.HTTPError as e:
        print(f"  HTTP Error: {e.code} {e.reason}")
        return False
    except FileNotFoundError as e:
        print(f"  Tool not found: {e}")
        return False
    except Exception as e:
        print(f"  Error: {e}")
        return False


def main():
    print("=" * 60)
    print("notatlas - Windows Dependencies Setup")
    print("=" * 60)
    print()

    lib_path = VULKAN_LIB_DIR / "vulkan-1.lib"
    if lib_path.exists():
        print(f"vulkan-1.lib already exists ({lib_path.stat().st_size / 1024:.1f} KB)")
        if len(sys.argv) > 1 and sys.argv[1] == "--force":
            print("Force re-download requested.")
        else:
            print("Use --force to re-download.")
            return 0

    print()

    success = False

    print("Method 1: NuGet package")
    print("-" * 40)
    success = download_from_nuget()

    if not success:
        print()
        print("Method 2: Create import library from Khronos .def")
        print("-" * 40)
        success = download_def_and_create_lib()

    print()

    if success:
        print("=" * 60)
        print("SUCCESS! Windows dependencies are ready.")
        print()
        print("You can now cross-compile for Windows:")
        print("  make build-windows")
        print("  # or")
        print("  zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe")
        print()
        print("NOTE: The Windows executable needs vulkan-1.dll at runtime.")
        print("      Devs running the .exe should install the Vulkan Runtime:")
        print("      https://vulkan.lunarg.com/sdk/home")
        print("=" * 60)
        return 0
    else:
        print("=" * 60)
        print("FAILED to set up Windows dependencies.")
        print()
        print("Manual setup:")
        print("1. Download Vulkan SDK from https://vulkan.lunarg.com/sdk/home")
        print("2. Copy Lib/vulkan-1.lib to libs/windows/vulkan/lib/")
        print("=" * 60)
        return 1


if __name__ == "__main__":
    sys.exit(main())
