import os
import json
from pathlib import Path
import re
import subprocess
import sys
import sysconfig
from typing import List, Union

FILENAME = Path(sys.argv[0]).parent / "build-test.json"
PLATFORM = sysconfig.get_platform()
IS_MINGW = PLATFORM.startswith("mingw")
IS_LINUX = PLATFORM.startswith("linux")
IS_MACOS = PLATFORM.startswith("macos")
IS_WINDOWS = sys.platform == "win32" and not IS_MINGW
if IS_WINDOWS:
    PLATFORM = sys.platform
IS_FINAL_VERSION = sys.version_info.releaselevel == "final"

RE_PYTHON_VERSION = re.compile(r"\s*(\d+)\.*(\d*)\.*(\d*)")

if len(sys.argv) != 3:
    sys.exit(1)

func = sys.argv[2]
TEST_DIR = Path(sys.argv[1])
TEST_SAMPLE = TEST_DIR.name
test_data = json.loads(FILENAME.read_text()).get(TEST_SAMPLE, {})
IS_PIPENV = TEST_DIR.joinpath("Pipfile").is_file()
IS_CONDA = Path(sys.prefix, "conda-meta").is_dir()
CONDA_EXE = os.environ.get("CONDA_EXE", "conda")
PIP_UPGRADE = os.environ.get("PIP_UPGRADE", False)


def is_supported_platform(platform: Union[str, List[str]]) -> bool:
    if isinstance(platform, str):
        platform = platform.split(",")
    if IS_MINGW:
        platform_in_use = "mingw"
    else:
        platform_in_use = sys.platform
    platform_support = {"darwin", "linux", "mingw", "win32"}
    platform_yes = {plat for plat in platform if not plat.startswith("!")}
    if platform_yes:
        platform_support = platform_yes
    platform_not = {plat[1:] for plat in platform if plat.startswith("!")}
    if platform_not:
        platform_support -= platform_not
    return platform_in_use in platform_support


def is_supported_python(python_version: str) -> bool:
    python_version_in_use = sys.version_info[:3]
    numbers = RE_PYTHON_VERSION.split(python_version)
    operator = numbers[0]
    python_version_required = tuple(int(num) for num in numbers[1:] if num)
    return eval(f"{python_version_in_use}{operator}{python_version_required}")


def install_requirements(requires: Union[str, List[str]]) -> List[str]:
    if isinstance(requires, str):
        requires = requires.split(",")
    if IS_MINGW:
        HOST_GNU_TYPE = sysconfig.get_config_var("HOST_GNU_TYPE").split("-")
        host_type = HOST_GNU_TYPE[0]  # i686,x86_64
        mingw_w64_hosttype = f"mingw-{HOST_GNU_TYPE[1]}-"  # mingw-w64-
        basic_platform = f"mingw_{host_type}"  # mingw_x86_64
        if len(PLATFORM) > len(basic_platform):
            msys_variant = PLATFORM[len(basic_platform) + 1 :]
            mingw_w64_hosttype += msys_variant + "-"  # clang,ucrt
        mingw_w64_hosttype += host_type
    pip_args = (sys.executable, "-m", "pip", "install")
    pacman_args = ("pacman", "--noconfirm", "-S")
    conda_args = (
        CONDA_EXE,
        "install",
        "-p",
        sys.prefix,
        "-c",
        "conda-forge",
        "-y",
    )
    installed_packages = []
    pip_pkgs = []
    for req in requires:
        alias_for_conda = None
        alias_for_mingw = None
        find_links = None
        no_deps = False
        platform = None
        python_version = None
        prefer_binary = False
        require = None
        for req_data in req.split(" "):
            if req_data.startswith("--conda="):
                alias_for_conda = req_data.split("=")[1]
            elif req_data.startswith("--mingw="):
                alias_for_mingw = req_data.split("=")[1]
            elif req_data.startswith("--find-links="):
                find_links = req_data.split("=")[1]
            elif req_data == "--no-deps":
                no_deps = True
            elif req_data.startswith("--platform="):
                platform = req_data.split("=")[1]
            elif req_data.startswith("--python-version"):
                python_version = req_data[len("--python-version") :]
            elif req_data == "--prefer-binary":
                prefer_binary = True
            else:
                require = req_data
        if require is None:
            # raise
            continue
        elif platform and not is_supported_platform(platform):
            continue
        elif python_version and not is_supported_python(python_version):
            continue
        elif IS_CONDA:
            # minimal support for conda
            if alias_for_conda:
                require = alias_for_conda
            process = subprocess.run(list(conda_args) + [require])
            if process.returncode == 0:
                installed_packages.append(require)
                installed = True
                continue
        elif IS_MINGW:
            # create a list of possible names of the package, because in
            # MSYS2 some packages are mapped to python-package or
            # lowercased, etc, for instance:
            # Cython is not mapped
            # cx_Logging is python-cx-logging
            # Pillow is python-Pillow
            # and so on.
            # TODO: emulate find_links support
            # TODO: emulate no_deps support only for python packages
            # TODO: use regex
            if alias_for_mingw:
                require = alias_for_mingw
            package = require.split(";")[0].split("<")[0].split("=")[0]
            packages = [f"python-{package}", package]
            if package != package.lower():
                packages.append(f"python-{package.lower()}")
                packages.append(package.lower())
            installed = False
            for package in packages:
                package = f"{mingw_w64_hosttype}-{package}"
                args = list(pacman_args[:-1]) + ["-Ss", package]
                process = subprocess.run(
                    args, stdout=subprocess.PIPE, text=True
                )
                if process.returncode == 1:
                    continue  # does not exist with this name
                if process.returncode == 0 and "installed" in process.stdout:
                    installed_packages.append(package)
                    installed = True
                    break
                args = list(pacman_args) + [package]
                process = subprocess.run(args)
                if process.returncode == 0:
                    installed_packages.append(package)
                    installed = True
                    break
            if installed:
                continue
        # use pip
        args = []
        if find_links:
            args.extend(["--find-links", find_links])
        if no_deps:
            args.append("--no-deps")
        if prefer_binary:
            args.append("--prefer-binary")
        if args:
            if PIP_UPGRADE:
                args.append("--upgrade")
            args.append(require)
            if IS_PIPENV:
                args = ["pipenv", "run"] + list(pip_args[2:]) + args
            else:
                args = list(pip_args) + args
            process = subprocess.run(args, cwd=TEST_DIR)
            if process.returncode == 0:
                installed_packages.append(require)
                installed = True
            else:
                if not IS_FINAL_VERSION:
                    # in python preview, try a pre relase of the package too
                    args.append("--pre")
                    process = subprocess.run(args, cwd=TEST_DIR)
                    if process.returncode == 0:
                        installed_packages.append(require)
                        installed = True
                if not installed:
                    sys.exit(process.returncode)
        else:
            pip_pkgs.append(require)
    if pip_pkgs:
        if IS_PIPENV:
            args = ["pipenv", "install"] + pip_pkgs
        else:
            args = list(pip_args) + pip_pkgs
        if PIP_UPGRADE:
            args.append("--upgrade")
        process = subprocess.run(args, cwd=TEST_DIR)
        if process.returncode == 0:
            installed_packages.append(require)
        else:
            sys.exit(process.returncode)
    return installed_packages


# verify if platform to run is in use
platform = test_data.get("platform", [])
if platform and not is_supported_platform(platform):
    sys.exit()

# process requirements
if func == "req":
    if IS_PIPENV or IS_CONDA:
        basic_requirements = []
    else:
        basic_requirements = "pip,setuptools,wheel".split(",")
    if IS_CONDA and (IS_MACOS or IS_LINUX):
        basic_requirements.append("c-compiler")
        basic_requirements.append("libpython-static --python-version>=3.8")
    basic_requirements.append("importlib-metadata")
    installed_packages = install_requirements(basic_requirements)
    if IS_WINDOWS or IS_MINGW:
        installed_packages += install_requirements("cx_Logging>=3.0")
    requires = test_data.get("requirements", [])
    if requires:
        installed_packages += install_requirements(requires)
    if installed_packages:
        print("Requirements installed:", " ".join(installed_packages))
else:  # app number
    test_app = test_data.get("test_app", [f"test_{TEST_SAMPLE}"])
    if isinstance(test_app, str):
        test_app = [test_app]
    line = int(func or 0)
    # for app in test_app[:]:
    #    if IS_MINGW and app.startswith("gui:"):
    #        test_app.remove(app)
    if line < len(test_app):
        print(test_app[line])
