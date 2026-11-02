"""Local prerequisites and isolated AWS console authentication."""

from __future__ import annotations

import argparse
import configparser
from contextlib import contextmanager
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Iterator


ROOT = Path(__file__).resolve().parents[4]
PROFILE = "aws-ai-manager"
MARKER = ".aws-ai-manager-private"
MINIMUM_CLI = (2, 32, 0)
MINIMUM_BOTO3 = (1, 43, 118)


def private_directory(value: str | Path) -> Path:
    path = Path(value).expanduser().resolve()
    home = Path.home().resolve()
    if path == home or path == Path(path.anchor) or path in home.parents:
        raise ValueError("A dedicated private subdirectory is required, not a home or root directory.")
    if path == ROOT or ROOT in path.parents:
        raise ValueError("Keep credentials, journals and responses outside the repository.")
    shared = home / ".aws"
    if path == shared or shared in path.parents:
        raise ValueError("The shared AWS configuration and cache directory must not be used.")
    if path.exists() and not (path / MARKER).exists() and any(path.iterdir()):
        raise ValueError("Refusing to change an existing directory not owned by AWS AI Manager.")
    path.mkdir(parents=True, exist_ok=True)
    if os.name == "nt":
        sid = subprocess.check_output(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
             "[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value"],
            text=True,
        ).strip()
        if not re.fullmatch(r"S-\d(?:-\d+)+", sid):
            raise ValueError("Unable to resolve the current Windows user SID.")
        subprocess.run(
            ["icacls.exe", str(path), "/inheritance:r", "/grant:r",
             f"*{sid}:(OI)(CI)F", "*S-1-5-18:(OI)(CI)F"],
            check=True, capture_output=True, text=True,
        )
    else:
        path.chmod(0o700)
    (path / MARKER).touch(mode=0o600, exist_ok=True)
    return path


def write_json(path: Path, value: object) -> None:
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, prefix=".write-", delete=False
    ) as stream:
        temporary = Path(stream.name)
        try:
            if os.name != "nt":
                temporary.chmod(0o600)
            json.dump(value, stream, ensure_ascii=True, indent=2, default=str)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        except (OSError, TypeError, ValueError):
            temporary.unlink(missing_ok=True)
            raise
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict):
        raise ValueError(f"Expected a JSON object in {path.name}.")
    return value


def isolated_environment(auth_dir: Path, region: str) -> dict[str, str]:
    environment = {
        key: value for key, value in os.environ.items()
        if not key.upper().startswith("AWS_") and key.upper() not in {"BOTO_CONFIG"}
    }
    environment.update({
        "AWS_CONFIG_FILE": str(auth_dir / "config"),
        "AWS_SHARED_CREDENTIALS_FILE": str(auth_dir / "credentials"),
        "AWS_LOGIN_CACHE_DIRECTORY": str(auth_dir / "login-cache"),
        "AWS_PROFILE": PROFILE,
        "AWS_DEFAULT_PROFILE": PROFILE,
        "AWS_REGION": region,
        "AWS_DEFAULT_REGION": region,
        "AWS_EC2_METADATA_DISABLED": "true",
        "AWS_CLI_AUTO_PROMPT": "off",
        "AWS_PAGER": "",
        "BOTO_CONFIG": str(auth_dir / "boto.cfg"),
    })
    return environment


@contextmanager
def process_environment(environment: dict[str, str]) -> Iterator[None]:
    original = os.environ.copy()
    os.environ.clear()
    os.environ.update(environment)
    try:
        yield
    finally:
        os.environ.clear()
        os.environ.update(original)


def dedicated_credentials(path: str | Path, profile: str) -> dict[str, str]:
    resolved = Path(path).expanduser().resolve(strict=True)
    shared = Path.home().resolve() / ".aws"
    if shared == resolved or shared in resolved.parents or ROOT in resolved.parents:
        raise ValueError("Use a dedicated temporary-credentials file outside shared stores and the repository.")
    parser = configparser.ConfigParser(interpolation=None)
    parser.read_string(resolved.read_text(encoding="utf-8-sig"))
    if parser.defaults() or not parser.has_section(profile):
        raise ValueError(f"The dedicated credentials file must contain an explicit [{profile}] section.")
    section = dict(parser[profile])
    required = {"aws_access_key_id", "aws_secret_access_key", "aws_session_token"}
    if not required.issubset(section) or any(not section[key].strip() for key in required):
        raise ValueError("Temporary credentials with an access key, secret key and session token are required.")
    if set(section) - required - {"expiration"}:
        raise ValueError("Credential-process, role, SSO and other provider settings are not accepted in file mode.")
    if "expiration" in section:
        expires = datetime.fromisoformat(section["expiration"].replace("Z", "+00:00"))
        if expires.tzinfo is None or expires <= datetime.now(timezone.utc):
            raise ValueError("The temporary credentials are expired or have no timezone.")
    return {key: section[key] for key in required}


def cli_version(executable: str) -> tuple[int, int, int]:
    result = subprocess.run(
        [executable, "--version"], check=True, capture_output=True, text=True, timeout=30
    )
    match = re.search(r"aws-cli/(\d+)\.(\d+)\.(\d+)", result.stdout + result.stderr)
    if not match:
        raise ValueError("Unable to determine the AWS CLI version.")
    return tuple(int(part) for part in match.groups())


def edge_profile(profile: str, email: str) -> Path:
    if not re.fullmatch(r"Default|Profile \d+", profile):
        raise ValueError("Specify the confirmed existing Edge Work profile directory.")
    candidates = [
        Path(os.environ.get("PROGRAMFILES(X86)", r"C:\Program Files (x86)"))
        / "Microsoft" / "Edge" / "Application" / "msedge.exe",
        Path(os.environ.get("PROGRAMFILES", r"C:\Program Files"))
        / "Microsoft" / "Edge" / "Application" / "msedge.exe",
        Path(os.environ.get("LOCALAPPDATA", "")) / "Microsoft" / "Edge"
        / "Application" / "msedge.exe",
    ]
    executable = next((path for path in candidates if path.is_file()), None)
    if executable is None:
        raise ValueError("Microsoft Edge is missing. No alternate browser will be used.")
    preferences = (
        Path(os.environ.get("LOCALAPPDATA", "")) / "Microsoft" / "Edge"
        / "User Data" / profile / "Preferences"
    )
    values = read_json(preferences)
    accounts = values.get("account_info", [])
    if not email or not isinstance(accounts, list) or not any(
        isinstance(account, dict)
        and str(account.get("email", "")).casefold() == email.casefold()
        for account in accounts
    ):
        raise ValueError("The requested work account was not found in the confirmed Edge profile.")
    return executable


def environment_report() -> dict:
    executable = shutil.which("aws")
    version = cli_version(executable) if executable else None
    sdk = None
    if importlib.util.find_spec("boto3"):
        from importlib.metadata import version as package_version
        sdk = package_version("boto3")
    sdk_ready = sdk is not None and tuple(int(part) for part in sdk.split(".")) >= MINIMUM_BOTO3
    return {
        "python": sys.version.split()[0],
        "python_ready": sys.version_info >= (3, 10),
        "boto3": sdk,
        "sdk_ready": sdk_ready,
        "aws_cli": executable,
        "aws_cli_version": ".".join(map(str, version)) if version else None,
        "browser_auth_ready": version is not None and version >= MINIMUM_CLI,
        "file_auth_ready": sdk_ready and sys.version_info >= (3, 10),
        "notes": [
            "AWS CLI 2.32.0 or later is needed only for browser authentication.",
            "Browser sign-in also checks the explicitly confirmed existing Edge Work profile.",
            "No shared credentials, profiles, token caches or cloud resources were accessed.",
        ],
    }


def browser_authenticate(auth_dir: str | Path, region: str, profile: str, email: str) -> dict:
    executable = shutil.which("aws")
    if not executable or cli_version(executable) < MINIMUM_CLI:
        raise ValueError("Install AWS CLI v2.32.0 or later before interactive console sign-in.")
    edge = edge_profile(profile, email)
    private = private_directory(auth_dir)
    environment = isolated_environment(private, region)
    environment["BROWSER"] = f'"{edge}" --profile-directory="{profile}" %s'
    config = private / "config"
    if not config.exists():
        config.write_text(f"[profile {PROFILE}]\nregion = {region}\noutput = json\n", encoding="utf-8")
    else:
        parser = configparser.ConfigParser(interpolation=None)
        parser.read_string(config.read_text(encoding="utf-8"))
        if set(parser.sections()) != {f"profile {PROFILE}"} or parser.defaults():
            raise ValueError("The isolated config contains an unexpected profile.")
        if set(parser[f"profile {PROFILE}"]) - {"region", "output", "login_session"}:
            raise ValueError("The isolated config contains an unexpected credential provider.")
        if parser[f"profile {PROFILE}"].get("region") != region:
            raise ValueError("Use a new private auth directory to sign in to a different region.")
    subprocess.run(
        [executable, "login", "--profile", PROFILE, "--region", region,
         "--no-cli-pager", "--no-cli-auto-prompt"],
        env=environment, check=True, timeout=900, stdout=sys.stderr, stderr=sys.stderr,
    )
    metadata = {"method": "browser", "region": region, "profile": PROFILE}
    write_json(private / "authentication.json", metadata)
    return {"authenticated": True, "auth_dir": str(private), **metadata, "isolated": True}


def load_credentials(
    auth_dir: Path, region: str, credentials_file: str | None, credentials_profile: str
) -> dict[str, str]:
    if credentials_file:
        return dedicated_credentials(credentials_file, credentials_profile)
    metadata = read_json(auth_dir / "authentication.json")
    if metadata != {"method": "browser", "region": region, "profile": PROFILE}:
        raise ValueError("Browser authentication does not match the requested isolated region/profile.")
    executable = shutil.which("aws")
    if not executable or cli_version(executable) < MINIMUM_CLI:
        raise ValueError("AWS CLI 2.32.0 or later is required to export browser credentials.")
    result = subprocess.run(
        [executable, "configure", "export-credentials", "--profile", PROFILE,
         "--format", "process", "--no-cli-pager"],
        env=isolated_environment(auth_dir, region),
        check=True, capture_output=True, text=True, timeout=60,
    )
    exported = json.loads(result.stdout)
    fields = {
        "aws_access_key_id": "AccessKeyId",
        "aws_secret_access_key": "SecretAccessKey",
        "aws_session_token": "SessionToken",
    }
    if not isinstance(exported, dict) or any(not exported.get(key) for key in fields.values()):
        raise ValueError("The isolated AWS CLI did not return complete temporary credentials.")
    return {key: exported[source] for key, source in fields.items()}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("check", help="Check local prerequisites without signing in.")
    browser = commands.add_parser("browser", help="Sign in in external Edge using a private AWS store.")
    browser.add_argument("--auth-dir", required=True)
    browser.add_argument("--region", required=True)
    browser.add_argument("--edge-profile", required=True)
    browser.add_argument("--work-email", required=True)
    args = parser.parse_args(argv)
    try:
        if args.action == "check":
            result = environment_report()
            print(json.dumps(result, indent=2))
            return 0 if result["file_auth_ready"] else 1
        if not re.fullmatch(r"[a-z]{2}(?:-[a-z]+)+-\d", args.region):
            raise ValueError("Specify an AWS region identifier, for example eu-north-1.")
        result = browser_authenticate(
            args.auth_dir, args.region, args.edge_profile, args.work_email
        )
        print(json.dumps(result, indent=2))
        return 0
    except (ValueError, OSError, configparser.Error, subprocess.SubprocessError) as error:
        print(json.dumps({"ok": False, "error": str(error)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
