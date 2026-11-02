from __future__ import annotations

import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import sys
from typing import Any
import webbrowser


JsonObject = dict[str, Any]
REPO_ROOT = Path(__file__).resolve().parents[4]
PRIVATE_ROOT = Path.home() / ".copilot" / "google-ai-manager"
REQUIREMENTS = Path(__file__).with_name("requirements.txt")
PACKAGES = (
    "google-adk", "google-auth", "httpx", "requests", "a2a-sdk", "mcp",
    "google-cloud-agentidentitycredentials", "google-cloud-iamconnectorcredentials",
)


class WorkflowError(Exception):
    def __init__(
        self, code: str, message: str, *, details: JsonObject | None = None
    ) -> None:
        super().__init__(message)
        self.code = code
        self.details = details or {}


def private_path(path: Path) -> Path:
    resolved = path.expanduser().resolve()
    if resolved.is_relative_to(REPO_ROOT):
        relative = resolved.relative_to(REPO_ROOT)
        if ".google-ai-private" not in relative.parts:
            raise WorkflowError(
                "UNSAFE_PRIVATE_PATH",
                "Keep private files outside the checkout or inside an ignored .google-ai-private directory.",
            )
    return resolved


def reject_shared_google_store(path: Path) -> None:
    roots = [Path.home() / ".config" / "gcloud"]
    if os.environ.get("APPDATA"):
        roots.append(Path(os.environ["APPDATA"]) / "gcloud")
    for root in roots:
        if path.is_relative_to(root.resolve()):
            raise WorkflowError(
                "UNSAFE_AUTH_PATH",
                "Use a dedicated session location, not the shared default Google credential store.",
            )


def executable_path(explicit: Path | None, candidates: list[Path]) -> Path | None:
    if explicit is not None:
        path = explicit.expanduser().resolve()
        if not path.is_file():
            raise WorkflowError("MISSING_TOOL", "The explicitly selected executable does not exist.")
        return path
    return next((path.resolve() for path in candidates if path.is_file()), None)


def find_gcloud(explicit: Path | None = None) -> Path | None:
    found = shutil.which("gcloud")
    candidates = [Path(found)] if found else []
    for variable in ("LOCALAPPDATA", "ProgramFiles", "ProgramFiles(x86)"):
        if os.environ.get(variable):
            root = Path(os.environ[variable])
            candidates.append(root / "Google" / "Cloud SDK" / "google-cloud-sdk" / "bin" / "gcloud.cmd")
    if os.environ.get("LOCALAPPDATA"):
        candidates.append(
            Path(os.environ["LOCALAPPDATA"]) / "google-ai-manager" / "tools"
            / "google-cloud-sdk" / "bin" / "gcloud.cmd"
        )
    return executable_path(explicit, candidates)


def find_edge(explicit: Path | None = None) -> Path | None:
    found = shutil.which("msedge")
    candidates = [Path(found)] if found else []
    for variable in ("ProgramFiles(x86)", "ProgramFiles", "LOCALAPPDATA"):
        if os.environ.get(variable):
            candidates.append(
                Path(os.environ[variable]) / "Microsoft" / "Edge" / "Application" / "msedge.exe"
            )
    return executable_path(explicit, candidates)


def edge_profile(directory: str) -> Path:
    if not directory or directory in (".", "..") or re.search(r'[\\/:*?"<>|]', directory):
        raise WorkflowError("INVALID_EDGE_PROFILE", "Use an approved existing Edge profile-directory name.")
    local = os.environ.get("LOCALAPPDATA")
    if not local:
        raise WorkflowError("UNSUPPORTED_BROWSER_ENVIRONMENT", "The Edge Work browser flow requires Windows.")
    profile = Path(local) / "Microsoft" / "Edge" / "User Data" / directory
    if not profile.is_dir():
        raise WorkflowError("MISSING_EDGE_PROFILE", "The approved existing Edge Work profile is missing.")
    return profile


def installed_version(package: str) -> str | None:
    try:
        return importlib.metadata.version(package)
    except importlib.metadata.PackageNotFoundError:
        return None


def environment_report(
    auth_mode: str = "either", *, gcloud_path: Path | None = None,
    edge_path: Path | None = None, profile_directory: str | None = None,
) -> JsonObject:
    packages = {name: installed_version(name) for name in PACKAGES}
    missing = [name for name, version in packages.items() if version is None]
    if sys.version_info < (3, 11):
        missing.insert(0, "Python >=3.11 (3.12 recommended)")
    if packages["google-adk"] not in (None, "2.12.0"):
        missing.append("google-adk==2.12.0")
    bounds = {"google-auth": ((2, 47), (3,)), "httpx": ((0, 28), (1,)), "requests": ((2, 32), (3,))}
    for name, (lower, upper) in bounds.items():
        value = packages[name]
        if value is not None:
            match = re.match(r"^(\d+)\.(\d+)", value)
            if not match or not lower <= (int(match[1]), int(match[2])) < upper:
                missing.append(f"{name}: incompatible installed version")
    gcloud = find_gcloud(gcloud_path)
    edge = find_edge(edge_path)
    browser_missing = []
    if gcloud is None:
        browser_missing.append("Google Cloud CLI (Google Cloud SDK)")
    elif not (gcloud.parent.parent / "lib" / "gcloud.py").is_file():
        browser_missing.append("Google Cloud SDK Python launcher")
    if edge is None:
        browser_missing.append("Microsoft Edge")
    if profile_directory:
        edge_profile(profile_directory)
    selected_missing = missing + (browser_missing if auth_mode == "browser" else [])
    return {
        "status": "installation_required" if selected_missing else "ready",
        "auth_mode": auth_mode, "python": sys.executable,
        "python_version": ".".join(map(str, sys.version_info[:3])),
        "packages": packages, "missing": selected_missing,
        "browser_additional_missing": browser_missing,
        "gcloud_path": str(gcloud) if gcloud else None,
        "edge_path": str(edge) if edge else None,
        "requirements_file": str(REQUIREMENTS),
        "installation_policy": "Explain missing installations and obtain approval before installing. This check never installs or authenticates.",
        "installation_help": {
            "python": "https://www.python.org/downloads/windows/",
            "google_cloud_cli": "https://cloud.google.com/sdk/docs/install",
            "edge": "https://www.microsoft.com/edge/download",
            "python_packages": f'Use a dedicated environment, then its Python with -m pip install -r "{REQUIREMENTS}".',
        },
    }


def browser_authenticate(
    project: str, auth_dir: Path, profile_directory: str, *,
    gcloud_path: Path | None = None, edge_path: Path | None = None,
) -> JsonObject:
    if not re.fullmatch(r"[a-z][a-z0-9-]{4,61}[a-z0-9]|\d{6,}", project):
        raise WorkflowError("INVALID_PROJECT", "Provide a Google project ID or number.")
    directory = private_path(auth_dir)
    reject_shared_google_store(directory)
    report = environment_report(
        "browser", gcloud_path=gcloud_path, edge_path=edge_path,
        profile_directory=profile_directory,
    )
    if report["status"] != "ready":
        raise WorkflowError(
            "INSTALLATION_REQUIRED", "Install the reported prerequisites before requesting sign-in.",
            details={"preflight": report},
        )
    edge_profile(profile_directory)
    credentials_file = directory / "application_default_credentials.json"
    if directory.exists():
        raise WorkflowError(
            "AUTH_DIRECTORY_IN_USE",
            "Use a new private authentication directory, or explicitly select an existing isolated credential file. No existing directory was modified.",
        )
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    gcloud = Path(report["gcloud_path"])
    launcher = gcloud.parent.parent / "lib" / "gcloud.py"
    edge = Path(report["edge_path"])
    os.environ["CLOUDSDK_CONFIG"] = str(directory)
    os.environ["CLOUDSDK_CORE_PROJECT"] = project
    os.environ["CLOUDSDK_CORE_DISABLE_USAGE_REPORTING"] = "true"
    os.environ["CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK"] = "true"
    os.environ["CLOUDSDK_PYTHON"] = sys.executable
    for name in (
        "GOOGLE_APPLICATION_CREDENTIALS", "CLOUDSDK_ACTIVE_CONFIG_NAME",
        "CLOUDSDK_CORE_ACCOUNT", "CLOUDSDK_AUTH_ACCESS_TOKEN_FILE",
        "CLOUDSDK_AUTH_ACCESS_TOKEN", "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE",
        "CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT", "CLOUDSDK_AUTH_LOGIN_CONFIG_FILE",
    ):
        os.environ.pop(name, None)

    controller = webbrowser.BackgroundBrowser(
        [str(edge), f"--profile-directory={profile_directory}", "%s"]
    )

    def open_edge(url: str, new: int = 0, autoraise: bool = True) -> bool:
        if not controller.open(url, new=new, autoraise=autoraise):
            raise WorkflowError("BROWSER_FAILED", "Edge Work could not be opened; no alternate browser or device-code flow was started.")
        return True

    webbrowser.open = open_edge
    os.environ["BROWSER"] = "edge-work"
    webbrowser.register("edge-work", None, controller, preferred=True)
    sys.path.insert(0, str(launcher.parent))
    sys.argv = [
        str(launcher), "auth", "application-default", "login",
        f"--project={project}", "--scopes=https://www.googleapis.com/auth/cloud-platform",
        "--browser", "--launch-browser",
    ]
    try:
        runpy.run_path(str(launcher), run_name="__main__")
    except SystemExit as error:
        if error.code not in (None, 0):
            raise WorkflowError("BROWSER_AUTH_FAILED", "Google browser authentication failed. Ask the user how to proceed; do not fall back to device code.") from error
    if not credentials_file.is_file():
        raise WorkflowError("BROWSER_AUTH_FAILED", "Google did not create the isolated credential file.")
    with credentials_file.open(encoding="utf-8") as handle:
        saved = json.load(handle)
    if not isinstance(saved, dict) or saved.get("type") != "authorized_user":
        raise WorkflowError("INVALID_CREDENTIALS", "The browser flow did not produce user OAuth credentials.")
    if saved.get("quota_project_id") != project:
        quota = subprocess.run(
            [
                sys.executable, str(launcher), "auth", "application-default",
                "set-quota-project", project, "--quiet",
            ],
            capture_output=True, text=True, timeout=120, check=False,
        )
        if quota.returncode != 0:
            raise WorkflowError(
                "QUOTA_PROJECT_FAILED", "Google could not authorize the selected quota project.",
                details={"auth_dir": str(directory), "google_error": quota.stderr.strip()},
            )
        with credentials_file.open(encoding="utf-8") as handle:
            if json.load(handle).get("quota_project_id") != project:
                raise WorkflowError("QUOTA_PROJECT_FAILED", "The isolated credential file has no matching quota project.")
    return {
        "status": "authenticated", "auth_mode": "browser",
        "project": project, "credentials_file": str(credentials_file),
        "auth_dir": str(directory),
        "isolation": "Dedicated credential directory; existing approved Edge Work profile. No shared CLI context was changed.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Non-installing prerequisite checks and explicit isolated Edge authentication.")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("check", "auth-browser"):
        item = commands.add_parser(name)
        item.add_argument("--gcloud-path", type=Path)
        item.add_argument("--edge-path", type=Path)
        item.add_argument("--edge-profile-directory", required=name == "auth-browser")
        if name == "check":
            item.add_argument("--auth-mode", choices=("either", "file", "browser"), default="either")
        else:
            item.add_argument("--project", required=True)
            item.add_argument("--auth-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "check":
            result = environment_report(
                args.auth_mode, gcloud_path=args.gcloud_path,
                edge_path=args.edge_path, profile_directory=args.edge_profile_directory,
            )
        else:
            result = browser_authenticate(
                args.project, args.auth_dir, args.edge_profile_directory,
                gcloud_path=args.gcloud_path, edge_path=args.edge_path,
            )
    except (WorkflowError, OSError, ValueError, subprocess.SubprocessError) as error:
        code = error.code if isinstance(error, WorkflowError) else type(error).__name__
        details = error.details if isinstance(error, WorkflowError) else {}
        print(json.dumps({"status": "error", "code": code, "message": str(error), **details}), file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=True))
    return 2 if result["status"] == "installation_required" else 0


if __name__ == "__main__":
    raise SystemExit(main())
