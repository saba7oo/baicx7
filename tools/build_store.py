#!/usr/bin/env python3
"""Regenerate store.json from the APKs actually published in a GitHub release.

WHY THIS EXISTS
    store.json used to be written by hand, and every field that also lives inside the APK was a
    chance to get it wrong. It went wrong twice in one evening: a stray filename and a misplaced
    entry each made the file invalid JSON (the in-app store then showed nothing at all, on the car
    and the emulator), and the Maps entry carried a package name and versionCode that belonged to
    no APK -- the file it points at is a GBox-wrapped build, so the store could never match the
    installed app or detect an update.

    So nothing that the APK already knows is ever typed again. `pkg`, `versionCode` and the default
    display name are READ FROM THE APK; apps-meta.json only carries what an APK cannot know
    (description, category, an optional name override, and `hidden` to drop one from the list).

USAGE
    python tools/build_store.py --repo saba7oo/baicx7 --tag apps            # rewrite store.json
    python tools/build_store.py --repo saba7oo/baicx7 --tag apps --check    # verify, change nothing

    --check exits non-zero when store.json does not match the release, which is what CI runs so a
    broken or stale manifest can never reach the car.

Needs `aapt` or `aapt2` on PATH (CI installs the `aapt` package; the Android SDK build-tools ship
aapt2). GITHUB_TOKEN is optional -- it only raises the API rate limit.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

CATEGORY_ORDER = ["Navigation", "Media", "Tools"]


def api(url, token=None):
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                               "User-Agent": "build-store"})
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def download(url, dest, token=None):
    req = urllib.request.Request(url, headers={"Accept": "application/octet-stream",
                                               "User-Agent": "build-store"})
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=600) as r, open(dest, "wb") as f:
        shutil.copyfileobj(r, f)


def aapt_tool():
    for name in ("aapt2", "aapt"):
        path = shutil.which(name)
        if path:
            return path
    # Android SDK build-tools, newest first
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if sdk:
        bt = os.path.join(sdk, "build-tools")
        if os.path.isdir(bt):
            for ver in sorted(os.listdir(bt), reverse=True):
                for name in ("aapt2.exe", "aapt2", "aapt.exe", "aapt"):
                    cand = os.path.join(bt, ver, name)
                    if os.path.isfile(cand):
                        return cand
    sys.exit("need aapt or aapt2 on PATH (CI: apt-get install aapt)")


def apk_facts(tool, apk):
    """The three fields the APK is authoritative for."""
    out = subprocess.run([tool, "dump", "badging", apk], capture_output=True, text=True,
                         errors="replace").stdout
    pkg = re.search(r"package: name='([^']+)'", out)
    ver = re.search(r"versionCode='(\d+)'", out)
    label = re.search(r"application-label:'([^']*)'", out)
    if not pkg or not ver:
        sys.exit("could not read package/versionCode from " + os.path.basename(apk))
    return pkg.group(1), int(ver.group(1)), (label.group(1) if label else "")


def build(repo, tag, token):
    rel = api("https://api.github.com/repos/%s/releases/tags/%s" % (repo, tag), token)
    assets = [a for a in rel.get("assets", []) if a["name"].lower().endswith(".apk")]
    if not assets:
        sys.exit("no .apk assets on release '%s'" % tag)

    meta_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                             "apps-meta.json")
    meta = {}
    if os.path.isfile(meta_path):
        with open(meta_path, encoding="utf-8") as f:
            meta = {e["pkg"]: e for e in json.load(f).get("apps", [])}

    tool = aapt_tool()
    tmp = tempfile.mkdtemp(prefix="store-apks-")
    apps = []
    try:
        for a in sorted(assets, key=lambda x: x["name"].lower()):
            local = os.path.join(tmp, a["name"])
            print("reading %s (%.1f MB)" % (a["name"], a["size"] / 1048576.0), flush=True)
            download(a["url"], local, token)
            pkg, code, label = apk_facts(tool, local)
            os.remove(local)
            m = meta.get(pkg, {})
            if m.get("hidden"):
                print("  skipped (hidden in apps-meta.json): " + pkg, flush=True)
                continue
            apps.append({
                "name": m.get("name") or label or pkg,
                "pkg": pkg,
                "apkUrl": a["browser_download_url"],
                "versionCode": code,
                "desc": m.get("desc", ""),
                "category": m.get("category", "Tools"),
            })
            print("  %s  versionCode=%d" % (pkg, code), flush=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    def sort_key(app):
        cat = app["category"]
        rank = CATEGORY_ORDER.index(cat) if cat in CATEGORY_ORDER else len(CATEGORY_ORDER)
        return (rank, cat, app["name"].lower())

    apps.sort(key=sort_key)
    return {"apps": apps}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="saba7oo/baicx7")
    ap.add_argument("--tag", default="apps")
    ap.add_argument("--out", default=None)
    ap.add_argument("--check", action="store_true", help="verify only; exit 1 if store.json is stale")
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = args.out or os.path.join(root, "store.json")
    built = build(args.repo, args.tag, os.environ.get("GITHUB_TOKEN"))
    text = json.dumps(built, indent=2, ensure_ascii=False) + "\n"

    if args.check:
        current = open(out, encoding="utf-8").read() if os.path.isfile(out) else ""
        try:
            same = json.loads(current) == built
        except Exception as e:
            sys.exit("store.json does not parse: %s" % e)
        if not same:
            sys.exit("store.json is stale — run tools/build_store.py to regenerate it")
        print("store.json matches the release (%d apps)" % len(built["apps"]))
        return

    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("wrote %s (%d apps)" % (out, len(built["apps"])))


if __name__ == "__main__":
    main()
