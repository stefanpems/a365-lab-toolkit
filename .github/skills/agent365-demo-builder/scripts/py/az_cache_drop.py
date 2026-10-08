"""Drop cached ACCESS tokens of a lab-private Azure CLI profile (AZURE_CONFIG_DIR) so that az mints new ones from its
refresh token. Needed after a Continuous Access Evaluation revocation (TokenIssuedBeforeRevocationTimestamp): az keeps
returning its cached 24 h CAE token even after a new 'az login'. Refresh tokens and accounts are kept (no new sign-in).
Refuses to touch the machine-wide profile (the default ~/.azure): other sessions use it.
Usage: python az_cache_drop.py --config-dir <AZURE_CONFIG_DIR> [--resource graph.microsoft.com]
Prints one line; exit 0 = done (also when nothing matched), 2 = refused or cache not readable.
"""
import argparse
import json
import os
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config-dir", required=True)
    ap.add_argument("--resource", default="graph.microsoft.com", help="substring of the token target; '' = every access token")
    a = ap.parse_args()
    cfg = os.path.abspath(a.config_dir)
    default = os.path.abspath(os.path.join(os.path.expanduser("~"), ".azure"))
    if os.path.normcase(cfg) == os.path.normcase(default):
        print("refused: the machine-wide az profile is never modified", file=sys.stderr)
        return 2
    path = os.path.join(cfg, "msal_token_cache.bin")
    if not os.path.exists(path):
        print("no token cache in this profile: nothing to drop")
        return 0
    try:
        if os.name == "nt":
            from msal_extensions import FilePersistenceWithDataProtection as P
        else:
            from msal_extensions import FilePersistence as P
        per = P(path)
        data = json.loads(per.load() or "{}")
    except Exception as exc:  # unreadable (other user, other machine) or msal-extensions missing
        print(f"token cache not readable: {exc}", file=sys.stderr)
        return 2
    ats = data.get("AccessToken", {})
    res = a.resource.lower()
    drop = [k for k, v in ats.items() if res in str(v.get("target", "")).lower()]
    for k in drop:
        del ats[k]
    if drop:
        per.save(json.dumps(data))
    print(f"dropped {len(drop)} cached access token(s) for '{a.resource or '*'}'; refresh tokens kept: {len(data.get('RefreshToken', {}))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
