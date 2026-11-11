#!/usr/bin/env python3
"""Writes source.json: a sideloading source (AltStore's format, which
SideStore, AltStore and Feather read) listing iSH+'s releases, so people who
add https://raw.githubusercontent.com/johnnydevelops/ish-plus/main/source.json
get each new release as an update. Run after publishing a release (it reads
the GitHub releases with `gh`), then commit source.json.
"""
import json
import os
import plistlib
import subprocess
import sys

REPO = "johnnydevelops/ish-plus"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
RAW = f"https://raw.githubusercontent.com/{REPO}/main"


def gh(path):
    return json.loads(subprocess.run(["gh", "api", "--paginate", path], check=True,
                                     capture_output=True, text=True).stdout)


# Sideloading stores refuse apps that ask for more than the source says, so
# the permissions come from the latest release's tag: what its .ipa has.
def at_tag(tag, path):
    return plistlib.loads(subprocess.run(["git", "-C", ROOT, "show", f"{tag}:{path}"], check=True,
                                         capture_output=True).stdout)


def privacy_descriptions(tag):
    """The usage descriptions iSH+ asks permission with (its Info.plist)."""
    info = at_tag(tag, "app/Info.plist")
    return {key: value for key, value in info.items() if key.endswith("UsageDescription")}


def entitlements(tag):
    """What iSH+ is signed with (tools/package-ipa.sh adds get-task-allow)."""
    return sorted(set(at_tag(tag, "app/iSH.entitlements")) | {"get-task-allow"})


def main():
    versions = []
    for release in gh(f"repos/{REPO}/releases"):
        if release["draft"]:
            continue
        ipa = next((a for a in release["assets"] if a["name"].endswith(".ipa")), None)
        if ipa is None:
            continue
        versions.append({
            "tag": release["tag_name"],
            "version": release["tag_name"].lstrip("v"),
            "date": release["published_at"],
            "localizedDescription": release["body"] or "",
            "downloadURL": ipa["browser_download_url"],
            "size": ipa["size"],
            "minOSVersion": "26.0",
        })
    versions.sort(key=lambda v: v["date"], reverse=True)
    latest = versions[0]["tag"]
    for version in versions:
        del version["tag"]

    description = (
        "A Linux terminal that runs a real Linux kernel in a virtual machine (QEMU, with JIT), "
        "with the distribution of your choice: Alpine, Debian, Ubuntu, Arch, Fedora and more. "
        "x86_64 programs run through FEX. iSH+ enables JIT by itself through LocalDevVPN once it "
        "is paired with your device.\n\nBased on iSH. Source: https://github.com/" + REPO
    )
    source = {
        "name": "iSH+",
        "identifier": "com.johnnydevelops.ish.source",
        "subtitle": "A real Linux in a terminal",
        "description": description,
        "iconURL": f"{RAW}/design/app-icon.png",
        "website": f"https://github.com/{REPO}",
        "tintColor": "#00C040",
        "apps": [{
            "name": "iSH+",
            "bundleIdentifier": "com.johnnydevelops.ish",
            "developerName": "johnnydevelops",
            "subtitle": "A real Linux in a terminal",
            "localizedDescription": description,
            "iconURL": f"{RAW}/design/app-icon.png",
            "tintColor": "#00C040",
            "category": "developer",
            "screenshotURLs": [],
            "versions": versions,
            "appPermissions": {
                "entitlements": entitlements(latest),
                "privacy": privacy_descriptions(latest),
            },
        }],
        "news": [],
    }
    with open(os.path.join(ROOT, "source.json"), "w") as f:
        json.dump(source, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"source.json: {len(versions)} versions, latest {versions[0]['version'] if versions else '-'}")


if __name__ == "__main__":
    sys.exit(main())
