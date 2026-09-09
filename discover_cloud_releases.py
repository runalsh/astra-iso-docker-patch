#!/usr/bin/env python3
import os
import sys
import json
import re
import argparse
import subprocess
import urllib.request
import urllib.parse

def mask_secret(val):
    if not val:
        return
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::add-mask::{val}", flush=True)

def extract_public_key(url_or_key):
    if not url_or_key:
        return None
    url_or_key = url_or_key.strip()
    m = re.search(r'public/([^/]+/[^/]+)', url_or_key)
    if m:
        return m.group(1)
    parts = [p for p in url_or_key.split('/') if p]
    if len(parts) >= 2:
        return f"{parts[-2]}/{parts[-1]}"
    return url_or_key

def fetch_folder_items(public_key):
    api_url = f"https://cloud.mail.ru/api/v2/folder?weblink={urllib.parse.quote(public_key)}"
    req = urllib.request.Request(api_url, headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = json.loads(resp.read().decode('utf-8'))
    return data.get("body", {}).get("list", [])

def fetch_download_dispatcher():
    api_url = "https://cloud.mail.ru/api/v2/dispatcher"
    req = urllib.request.Request(api_url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read().decode('utf-8'))
    weblink_gets = data.get("body", {}).get("weblink_get", [])
    if weblink_gets:
        return weblink_gets[0].get("url")
    return None

def parse_astra_releases(items):
    pattern = re.compile(r'^astra[- _]installation[- _]([0-9]+(\.[0-9]+)+)', re.IGNORECASE)
    releases = []
    for it in items:
        name = it.get("name", "")
        if not name.lower().startswith("astra") or not name.endswith(".iso"):
            continue
        m = pattern.match(name)
        if m:
            full_ver = m.group(1)
            parts = full_ver.split('.')
            if len(parts) >= 3:
                tag = '.'.join(parts[:3])
            else:
                tag = full_ver
            releases.append({
                "tag": tag,
                "full_ver": full_ver,
                "name": name,
                "size": it.get("size", 0),
                "weblink": it.get("weblink", "")
            })
    # Sort by semantic version
    def sort_key(x):
        try:
            return [int(p) for p in re.findall(r'\d+', x['tag'])]
        except Exception:
            return [0]
    releases.sort(key=sort_key)
    return releases

def main():
    parser = argparse.ArgumentParser(description="Cloud Mail.ru Astra ISO Discovery and Secure Downloader")
    parser.add_argument("--url", default=os.environ.get("ASTRA_CLOUD_URL") or os.environ.get("MAILRU_PUBLIC_URL"),
                        help="Public Cloud Mail.ru URL or key (or set ASTRA_CLOUD_URL env)")
    parser.add_argument("--list", action="store_true", help="List discovered Astra ISO releases")
    parser.add_argument("--populate-releases", metavar="FILE", nargs="?", const="releases.txt",
                        help="Write discovered tags and filenames to releases.txt")
    parser.add_argument("--download", metavar="TAG_OR_NAME", help="Download specific ISO by tag or filename")
    parser.add_argument("--output", metavar="PATH", default=".", help="Output directory or file path for download")
    args = parser.parse_args()

    if not args.url:
        print("[ERROR] Cloud URL not provided! Pass --url or set ASTRA_CLOUD_URL environment variable.", file=sys.stderr)
        sys.exit(1)

    mask_secret(args.url)
    public_key = extract_public_key(args.url)
    if not public_key:
        print("[ERROR] Could not parse public key from provided URL!", file=sys.stderr)
        sys.exit(1)
    mask_secret(public_key)

    try:
        items = fetch_folder_items(public_key)
    except Exception as e:
        print(f"[ERROR] Failed to query Cloud Mail.ru API: {e}", file=sys.stderr)
        sys.exit(1)

    releases = parse_astra_releases(items)

    if args.list:
        print(f"Discovered {len(releases)} Astra Linux ISO images in cloud storage:")
        print("-" * 80)
        print(f"{'Tag':<10} {'Full Version':<16} {'Size (GB)':<12} {'Filename'}")
        print("-" * 80)
        for r in releases:
            size_gb = r['size'] / (1024 ** 3)
            print(f"{r['tag']:<10} {r['full_ver']:<16} {size_gb:>6.2f} GB     {r['name']}")
        print("-" * 80)
        return

    if args.populate_releases:
        out_file = args.populate_releases
        with open(out_file, "w", encoding="utf-8") as f:
            f.write("# Astra Linux ISO Releases from Cloud Storage\n")
            f.write("# Format: <tag> <iso_filename>\n")
            for r in releases:
                f.write(f"{r['tag']} {r['name']}\n")
        print(f"[SUCCESS] Wrote {len(releases)} releases to {out_file} (no sensitive URLs exposed).")
        return

    if args.download:
        target = args.download.strip()
        matched = None
        for r in releases:
            if r['tag'] == target or r['full_ver'] == target or r['name'] == target:
                matched = r
                break
        if not matched:
            print(f"[ERROR] No release matching '{target}' found in cloud storage!", file=sys.stderr)
            sys.exit(1)

        disp_url = fetch_download_dispatcher()
        if not disp_url:
            print("[ERROR] Failed to obtain download server dispatcher URL!", file=sys.stderr)
            sys.exit(1)

        # Build download URL
        # e.g.: https://clocloXX.cloud.mail.ru/public/aQUv.../d3GU/39tfw3DVG/astra...iso
        raw_weblink = matched['weblink'] or f"{public_key}/{matched['name']}"
        encoded_weblink = urllib.parse.quote(raw_weblink)
        download_url = f"{disp_url.rstrip('/')}/{encoded_weblink}"
        mask_secret(download_url)

        # Determine target file path
        if os.path.isdir(args.output):
            out_path = os.path.join(args.output, matched['name'])
        else:
            out_path = args.output

        size_gb = matched['size'] / (1024 ** 3)
        print(f"[INFO] Target ISO: '{matched['name']}' (Tag: {matched['tag']}, Size: {size_gb:.2f} GB)")
        print(f"[INFO] Destination: {out_path}")
        print("[INFO] Starting download (direct URLs are masked and hidden)...")

        cmd = [
            "curl",
            "-fLC", "-",
            "--progress-bar",
            "-sS",
            "--show-error",
            "-o", out_path,
            download_url
        ]

        # Execute curl securely without echoing the command with URL
        proc = subprocess.run(cmd)
        if proc.returncode != 0:
            print(f"\n[ERROR] Download failed with exit code {proc.returncode}!", file=sys.stderr)
            sys.exit(proc.returncode)

        actual_size = os.path.getsize(out_path) if os.path.exists(out_path) else 0
        actual_gb = actual_size / (1024 ** 3)
        print(f"\n[SUCCESS] Download complete! Saved to {out_path} ({actual_gb:.2f} GB).")
        return

    # Default action: list
    print(f"Found {len(releases)} Astra Linux releases. Use --list, --populate-releases, or --download <tag>.")

if __name__ == "__main__":
    main()
