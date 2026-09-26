r"""
Ingest SharePoint documents into an Azure AI Search index (a SHARED INDEXED COPY).

STANDALONE — part of the knowledge-base toolkit, not Lab Builder. Step 2 of the runbook.

What it does (idempotent):
  1. Resolves a SharePoint document-library folder URL to a Microsoft Graph site + drive.
  2. Lists the files in that folder and downloads each supported document.
  3. Extracts plain text (.docx via python-docx; .txt/.md as-is).
  4. Creates (or updates) the Azure AI Search index and (re)uploads one document per file.

Authentication:
  * Microsoft Graph — a delegated token is taken from the Azure CLI
    (`az account get-access-token --resource https://graph.microsoft.com`). Run `az login`
    first as a user who can read the SharePoint site.
  * Azure AI Search — the ADMIN key from kb.state.json (written by provision-search.ps1).

Usage:
  python ingest_docs.py --state ..\kb.state.json \
      --folder-url "https://<tenant>.sharepoint.com/sites/<site>/Shared%20Documents/Forms/AllItems.aspx"

  Optional: --extensions docx,pdf   (default: docx)
            --site-id / --drive-id  (skip URL resolution if you already have Graph ids)
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path

import requests

GRAPH = "https://graph.microsoft.com/v1.0"


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------
def graph_token() -> str:
    """Microsoft Graph token.

    App-only (client credentials) when KB_GRAPH_TENANT_ID/CLIENT_ID/CLIENT_SECRET are set —
    recommended, because an app with Sites.Read.All gets a pre-authenticated file download URL.
    Otherwise a delegated token from the signed-in Azure CLI user.
    """
    import os

    tid = os.environ.get("KB_GRAPH_TENANT_ID")
    cid = os.environ.get("KB_GRAPH_CLIENT_ID")
    secret = os.environ.get("KB_GRAPH_CLIENT_SECRET")
    if tid and cid and secret:
        r = requests.post(
            f"https://login.microsoftonline.com/{tid}/oauth2/v2.0/token",
            data={"grant_type": "client_credentials", "client_id": cid, "client_secret": secret,
                  "scope": "https://graph.microsoft.com/.default"},
            timeout=30,
        )
        r.raise_for_status()
        return r.json()["access_token"]
    return _az_token("https://graph.microsoft.com")


def app_only() -> bool:
    import os
    return all(os.environ.get(v) for v in ("KB_GRAPH_TENANT_ID", "KB_GRAPH_CLIENT_ID", "KB_GRAPH_CLIENT_SECRET"))


def sharepoint_token(hostname: str) -> str:
    """Delegated SharePoint-audience token for downloading file content from <hostname>."""
    return _az_token(f"https://{hostname}")


def _az_token(resource: str) -> str:
    out = subprocess.run(
        ["az", "account", "get-access-token", "--resource", resource,
         "--query", "accessToken", "-o", "tsv"],
        capture_output=True, text=True, shell=(sys.platform == "win32"),
    )
    if out.returncode != 0 or not out.stdout.strip():
        raise SystemExit(f"Failed to get a token for {resource} via 'az' — run 'az login'.\n{out.stderr}")
    return out.stdout.strip()


def graph_get(url: str, token: str) -> dict:
    r = requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=30)
    r.raise_for_status()
    return r.json()


# ---------------------------------------------------------------------------
# SharePoint resolution
# ---------------------------------------------------------------------------
def resolve_site_and_drive(folder_url: str, token: str) -> tuple[str, str]:
    """Resolve a SharePoint folder URL to (siteId, driveId) for the default document library."""
    parsed = urllib.parse.urlparse(folder_url)
    hostname = parsed.netloc
    # Path looks like /sites/<site>/Shared%20Documents/...; the site path is /sites/<site>.
    segments = [s for s in parsed.path.split("/") if s]
    if "sites" in segments:
        i = segments.index("sites")
        site_path = "/" + "/".join(segments[i:i + 2])  # /sites/<site>
    else:
        site_path = "/"
    site = graph_get(f"{GRAPH}/sites/{hostname}:{site_path}?$select=id,displayName,webUrl", token)
    site_id = site["id"]
    drives = graph_get(f"{GRAPH}/sites/{site_id}/drives?$select=id,name,driveType", token)["value"]
    # Prefer the library named 'Documents' (Shared Documents); fall back to the first documentLibrary.
    drive = next((d for d in drives if d.get("name") == "Documents"), None) \
        or next((d for d in drives if d.get("driveType") == "documentLibrary"), None) \
        or (drives[0] if drives else None)
    if not drive:
        raise SystemExit(f"No document library found on site {site_path}.")
    print(f"  Site : {site['displayName']} ({site_id})")
    print(f"  Drive: {drive['name']} ({drive['id']})")
    return site_id, drive["id"]


def list_files(drive_id: str, token: str, extensions: set[str]) -> list[dict]:
    """List files in the drive root whose extension is in `extensions`."""
    items = graph_get(
        f"{GRAPH}/drives/{drive_id}/root/children"
        f"?$select=id,name,size,file,webUrl,lastModifiedDateTime&$top=200",
        token,
    )["value"]
    files = []
    for it in items:
        if "file" not in it:
            continue
        ext = it["name"].rsplit(".", 1)[-1].lower() if "." in it["name"] else ""
        if ext in extensions:
            files.append(it)
    return files


def download_item(drive_id: str, item_id: str, token: str, dest: Path, sp_token: str | None = None) -> None:
    # A plain item GET (no $select — $select drops the annotations) returns the download
    # annotations. In app-only mode with Sites.Read.All, @microsoft.graph.downloadUrl is
    # pre-authenticated (fetch with NO header). Try candidates in order until one returns 200.
    meta = graph_get(f"{GRAPH}/drives/{drive_id}/items/{item_id}", token)
    du = meta.get("@microsoft.graph.downloadUrl")
    na = meta.get("@microsoft.graph.downloadUrlNoAuth")
    bearer = {"Authorization": f"Bearer {sp_token or token}"}
    candidates = [
        (du, None),          # pre-authenticated in app-only mode
        (du, bearer),        # delegated privileged token
        (na, None),          # some tenants pre-sign this one
        (f"{GRAPH}/drives/{drive_id}/items/{item_id}/content", {"Authorization": f"Bearer {token}"}),
    ]
    last = None
    for url, hdr in candidates:
        if not url:
            continue
        r = requests.get(url, headers=hdr or {}, timeout=120)
        if r.ok and not _is_html(r.content):
            dest.write_bytes(r.content)
            return
        last = r
    if last is not None:
        last.raise_for_status()
    raise RuntimeError(f"No valid download for item {item_id}")


def _is_html(data: bytes) -> bool:
    """Reject a 200 response that is actually an HTML error/sign-in page."""
    head = data[:256].lstrip().lower()
    return head.startswith(b"<!doctype html") or head.startswith(b"<html") or head.startswith(b"<head")


def download_pdf(drive_id: str, item_id: str, token: str, dest: Path) -> bool:
    """Download a PDF rendition of an Office file via Graph (server-side conversion)."""
    r = requests.get(
        f"{GRAPH}/drives/{drive_id}/items/{item_id}/content?format=pdf",
        headers={"Authorization": f"Bearer {token}"}, timeout=180,
    )
    if r.ok and r.content[:5] == b"%PDF-":
        dest.write_bytes(r.content)
        return True
    return False


# ---------------------------------------------------------------------------
# Text extraction
# ---------------------------------------------------------------------------
def _is_encrypted_ooxml(path: Path) -> bool:
    """An encrypted OOXML file is an OLE2 compound file containing an EncryptedPackage stream."""
    try:
        data = path.read_bytes()
    except Exception:
        return False
    return data[:8] == bytes.fromhex("d0cf11e0a1b11ae1") and b"E\x00n\x00c\x00r\x00y\x00p\x00t\x00e\x00d\x00P\x00a\x00c\x00k\x00a\x00g\x00e" in data


def decrypt_ooxml(src: Path, dest: Path, password: str) -> bool:
    """Decrypt a password-encrypted OOXML file to dest. Returns True on success."""
    try:
        import msoffcrypto
        with src.open("rb") as fh, dest.open("wb") as out:
            office = msoffcrypto.OfficeFile(fh)
            office.load_key(password=password)
            office.decrypt(out)
        return dest.stat().st_size > 0 and dest.read_bytes()[:2] == b"PK"
    except Exception as exc:
        print(f"    ! Decryption failed: {exc}", file=sys.stderr)
        return False


def extract_text(path: Path) -> str:
    ext = path.suffix.lower()
    if ext == ".pdf":
        from pypdf import PdfReader
        reader = PdfReader(str(path))
        return "\n".join((page.extract_text() or "") for page in reader.pages)
    if ext == ".docx":
        from docx import Document  # python-docx
        doc = Document(str(path))
        parts = [p.text for p in doc.paragraphs if p.text and p.text.strip()]
        for table in doc.tables:
            for row in table.rows:
                cells = [c.text.strip() for c in row.cells if c.text and c.text.strip()]
                if cells:
                    parts.append(" | ".join(cells))
        return "\n".join(parts)
    if ext in (".txt", ".md"):
        return path.read_text(encoding="utf-8", errors="replace")
    raise ValueError(f"Unsupported extension for text extraction: {ext}")


# ---------------------------------------------------------------------------
# Azure AI Search
# ---------------------------------------------------------------------------
def ensure_index(endpoint: str, admin_key: str, index_name: str) -> None:
    from azure.core.credentials import AzureKeyCredential
    from azure.search.documents.indexes import SearchIndexClient
    from azure.search.documents.indexes.models import (
        SearchIndex, SimpleField, SearchableField, SearchFieldDataType,
        SemanticConfiguration, SemanticPrioritizedFields, SemanticField, SemanticSearch,
    )

    client = SearchIndexClient(endpoint, AzureKeyCredential(admin_key))
    fields = [
        SimpleField(name="id", type=SearchFieldDataType.String, key=True),
        SearchableField(name="title", type=SearchFieldDataType.String),
        SearchableField(name="content", type=SearchFieldDataType.String),
        SimpleField(name="sourceUrl", type=SearchFieldDataType.String, filterable=False),
        SimpleField(name="lastModified", type=SearchFieldDataType.String, filterable=True, sortable=True),
    ]
    semantic = SemanticSearch(configurations=[
        SemanticConfiguration(
            name="default",
            prioritized_fields=SemanticPrioritizedFields(
                title_field=SemanticField(field_name="title"),
                content_fields=[SemanticField(field_name="content")],
            ),
        )
    ])
    index = SearchIndex(name=index_name, fields=fields, semantic_search=semantic)
    client.create_or_update_index(index)  # idempotent
    print(f"  Index '{index_name}' created or updated.")


def upload_documents(endpoint: str, admin_key: str, index_name: str, docs: list[dict]) -> None:
    from azure.core.credentials import AzureKeyCredential
    from azure.search.documents import SearchClient

    client = SearchClient(endpoint, index_name, AzureKeyCredential(admin_key))
    result = client.merge_or_upload_documents(documents=docs)
    ok = sum(1 for r in result if r.succeeded)
    print(f"  Uploaded {ok}/{len(docs)} documents to '{index_name}'.")
    if ok != len(docs):
        for r in result:
            if not r.succeeded:
                print(f"    ! {r.key}: {r.error_message}", file=sys.stderr)


def safe_key(name: str) -> str:
    """Azure AI Search keys allow letters, digits, _, -, =; encode anything else."""
    return "".join(c if (c.isalnum() or c in "_-=") else "_" for c in name)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    ap = argparse.ArgumentParser(description="Ingest SharePoint documents into an Azure AI Search index.")
    ap.add_argument("--state", required=True, help="Path to kb.state.json from provision-search.ps1.")
    ap.add_argument("--folder-url", help="SharePoint document-library folder URL.")
    ap.add_argument("--site-id", help="Graph site id (skips URL resolution).")
    ap.add_argument("--drive-id", help="Graph drive id (skips URL resolution).")
    ap.add_argument("--extensions", default="docx", help="Comma-separated extensions to ingest (default: docx).")
    ap.add_argument("--doc-password", default=os.environ.get("KB_DOC_PASSWORD"),
                    help="Password for encrypted OOXML files (or set KB_DOC_PASSWORD). Applied to any encrypted file.")
    args = ap.parse_args()

    state_path = Path(args.state).resolve()
    state = json.loads(state_path.read_text(encoding="utf-8"))
    endpoint = state["searchEndpoint"]
    admin_key = state["adminKey"]
    index_name = state["indexName"]
    extensions = {e.strip().lstrip(".").lower() for e in args.extensions.split(",") if e.strip()}

    token = graph_token()
    if args.site_id and args.drive_id:
        drive_id = args.drive_id
    elif args.folder_url:
        _, drive_id = resolve_site_and_drive(args.folder_url, token)
    else:
        raise SystemExit("Provide --folder-url, or both --site-id and --drive-id.")

    # SharePoint-audience token for content downloads (host derived from the folder URL).
    # Not needed in app-only mode (the app-only downloadUrl is pre-authenticated).
    sp_token = None
    if args.folder_url and not app_only():
        host = urllib.parse.urlparse(args.folder_url).netloc
        if host:
            sp_token = sharepoint_token(host)

    files = list_files(drive_id, token, extensions)
    if not files:
        raise SystemExit(f"No files with extensions {sorted(extensions)} found in the folder.")
    print(f"  Found {len(files)} file(s) to ingest.")

    ensure_index(endpoint, admin_key, index_name)

    docs = []
    with tempfile.TemporaryDirectory() as tmp:
        for it in files:
            dest = Path(tmp) / it["name"]
            download_item(drive_id, it["id"], token, dest, sp_token=sp_token)
            try:
                text = extract_text(dest)
            except Exception as exc:
                text = None
                # 1) Encrypted OOXML -> decrypt with the supplied password.
                if _is_encrypted_ooxml(dest):
                    if args.doc_password:
                        dec = dest.with_name(dest.stem + "_dec.docx")
                        if decrypt_ooxml(dest, dec, args.doc_password):
                            try:
                                text = extract_text(dec)
                            except Exception as exc2:
                                print(f"    ! Skipped {it['name']}: {exc2}", file=sys.stderr)
                                continue
                    if text is None:
                        print(f"    ! Skipped {it['name']}: encrypted (set KB_DOC_PASSWORD / --doc-password).", file=sys.stderr)
                        continue
                else:
                    # 2) Otherwise fall back to a Graph-rendered PDF (handles odd Office states).
                    pdf = dest.with_suffix(".pdf")
                    if download_pdf(drive_id, it["id"], token, pdf):
                        try:
                            text = extract_text(pdf)
                        except Exception as exc2:
                            print(f"    ! Skipped {it['name']}: {exc2}", file=sys.stderr)
                            continue
                    else:
                        print(f"    ! Skipped {it['name']}: {exc}", file=sys.stderr)
                        continue
            docs.append({
                "id": safe_key(it["id"]),
                "title": it["name"],
                "content": text,
                "sourceUrl": it.get("webUrl", ""),
                "lastModified": it.get("lastModifiedDateTime", ""),
            })
            print(f"    + {it['name']} ({len(text)} chars)")

    if not docs:
        raise SystemExit("No documents could be extracted.")
    upload_documents(endpoint, admin_key, index_name, docs)
    print("\nIngestion complete. Next: deploy-kb-mcp.ps1")


if __name__ == "__main__":
    main()
