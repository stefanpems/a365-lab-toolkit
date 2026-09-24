"""Apply tuning fixes to the Dalonso AI-agent detection packs (CopilotStudio + Foundry_Agents), in place.

Usage: python patch_packs.py "<repo>/Use Cases Threat Hunting/Monitoring AI Agents" [--no-agent365-mail-mcp]

Fixes (idempotent - running twice changes nothing):
  F1  mv-apply + summarize without "by" returns an empty Markers set for non-matching rows, so the rule fires on
      every message -> add "| where array_length(Markers) > 0".
  F2  ThreatIntelIndicators.Revoked is empty (not false) for active Microsoft Defender TI indicators, so the TI
      match rule never fires -> use "Revoked != true".
  F3  gen_ai.input.messages / InputMessages are JSON strings with \\u escapes that hide Unicode-tag / zero-width
      smuggling, and they include the system prompt (which often contains guardrail words such as "exfiltrate")
      -> decode the JSON and drop the system-role message before matching.
  F4  The secrets-in-prompt rule does not know GitHub tokens -> add ghp_ / github_pat_ patterns.
  F5  Add the Agent 365 Work IQ Mail MCP connector (shared_a365outlookmailmcp) to the Copilot Studio trusted
      connectors watchlist (skip with --no-agent365-mail-mcp).
"""
import glob, os, re, sys

args = [a for a in sys.argv[1:] if not a.startswith("--")]
if len(args) != 1:
    sys.exit(__doc__)
ROOT = args[0]
PACKS = [os.path.join(ROOT, "CopilotStudio"), os.path.join(ROOT, "Foundry_Agents")]
DECODE = r"""replace_regex(tostring(todynamic(tostring({src}))), @'(?s)\{{"role":"system","parts":\[.*?\]\}},?', '')"""
GH = r'(ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{50,})'

stats = {k: 0 for k in ("F1", "F2", "F3", "F4", "F5")}
for pack in PACKS:
    for f in glob.glob(os.path.join(pack, "*", "*.yaml")):
        txt = open(f, encoding="utf-8").read()
        orig = txt
        txt, n = re.subn(r"(summarize Markers = make_set\(Marker\)\r?\n(\s*)\))(?!\r?\n\s*\| where array_length\(Markers\))",
                         lambda m: m.group(1) + "\n  | where array_length(Markers) > 0", txt)
        stats["F1"] += n
        txt, n = re.subn(r"Revoked == false", "Revoked != true", txt)
        stats["F2"] += n
        for src in ('Properties["gen_ai.input.messages"]', "InputMessages"):
            pat = "tostring(" + src + ")"
            if pat in txt and "replace_regex(tostring(todynamic(tostring(" + src not in txt:
                stats["F3"] += txt.count(pat)
                txt = txt.replace(pat, DECODE.format(src=src))
        if os.path.basename(f) == "CopilotStudioSecretsInUserMessage.yaml" and "GitHubToken" not in txt:
            txt = txt.replace('      AwsKey     = Prompt matches regex @"AKIA[0-9A-Z]{16}",',
                              '      AwsKey     = Prompt matches regex @"AKIA[0-9A-Z]{16}",\n'
                              f'      GitHubToken = Prompt matches regex @"{GH}",')
            txt = txt.replace("| where AwsKey or PrivateKey", "| where GitHubToken or AwsKey or PrivateKey")
            txt = txt.replace('      AwsKey,           "AwsAccessKey",', '      GitHubToken,      "GitHubToken",\n      AwsKey,           "AwsAccessKey",')
            stats["F4"] += 1
        if txt != orig:
            open(f, "w", encoding="utf-8", newline="").write(txt)

if "--no-agent365-mail-mcp" not in sys.argv:
    tc = os.path.join(ROOT, "CopilotStudio", "Watchlists", "CopilotStudioTrustedConnectors", "data.csv")
    body = open(tc, encoding="utf-8").read()
    if "shared_a365outlookmailmcp" not in body:
        with open(tc, "a", encoding="utf-8") as fh:
            fh.write(("" if body.endswith("\n") else "\n") +
                     "shared_a365outlookmailmcp,Work IQ Mail MCP,Agent 365 tool gateway Mail MCP\n")
        stats["F5"] += 1
print("Applied fixes:", stats)
