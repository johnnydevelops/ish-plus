#!/usr/bin/env python3
"""Fetches distribution logos from Simple Icons (CC0, https://simpleicons.org)
into app/Assets.xcassets/Distros as vector template images, plus their brand
colours (DistroIcons.json there), for the distribution chooser. The logos are
their owners' trademarks."""
import json, os, urllib.request

VERSION = "16.37.0"
BASE = f"https://cdn.jsdelivr.net/npm/simple-icons@{VERSION}"
# family (as in DistroManager) -> Simple Icons slug
SLUGS = {
    "almalinux": "almalinux", "alpine": "alpinelinux", "archlinux": "archlinux",
    "artix": "artixlinux", "centos": "centos", "debian": "debian", "devuan": "devuan",
    "fedora": "fedora", "kali": "kalilinux", "opensuse": "opensuse",
    "rockylinux": "rockylinux", "ubuntu": "ubuntu", "voidlinux": "voidlinux",
}
root = os.path.join(os.path.dirname(__file__), "..", "app", "Assets.xcassets", "Distros")
os.makedirs(root, exist_ok=True)
with open(os.path.join(root, "Contents.json"), "w") as f:
    json.dump({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": True}}, f, indent=2)
data = json.load(urllib.request.urlopen(f"{BASE}/data/simple-icons.json"))
icons = data if isinstance(data, list) else data["icons"]
def slug_of(icon):
    if "slug" in icon: return icon["slug"]
    t = icon["title"].lower()
    for a, b in [("+", "plus"), (".", "dot"), ("&", "and")]: t = t.replace(a, b)
    return "".join(c for c in t if c.isalnum())
colours = {}
for family, slug in SLUGS.items():
    icon = next((i for i in icons if slug_of(i) == slug), {"hex": "888888"})
    colours[family] = "#" + icon["hex"]
    svg = urllib.request.urlopen(f"{BASE}/icons/{slug}.svg").read()
    d = os.path.join(root, f"{family}.imageset")
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, f"{family}.svg"), "wb").write(svg)
    json.dump({"images": [{"filename": f"{family}.svg", "idiom": "universal"}],
               "info": {"author": "xcode", "version": 1},
               "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"}},
              open(os.path.join(d, "Contents.json"), "w"), indent=2)
# Read by the app (a data set)
ds = os.path.join(root, "DistroColors.dataset")
os.makedirs(ds, exist_ok=True)
json.dump(colours, open(os.path.join(ds, "DistroColors.json"), "w"), indent=2)
json.dump({"data": [{"filename": "DistroColors.json", "idiom": "universal", "universal-type-identifier": "public.json"}],
           "info": {"author": "xcode", "version": 1}}, open(os.path.join(ds, "Contents.json"), "w"), indent=2)
print(colours)
