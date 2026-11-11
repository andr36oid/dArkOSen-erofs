#!/usr/bin/env python3
"""manifest.py <out> <image name> <size> <sha256> <version> <revision> <hotfix folder>

Writes manifest.json, the one file an installer reads to know what this release
is: which dArkOSen version, how large the EROFS image is, its parts in order,
how large a partition should be made for it, and the hotfixes that belong to it.
"""
import hashlib, json, os, shutil, sys, zipfile

out, name, size, digest, version, revision, fixes = sys.argv[1:8]
size = int(size)
GIB = 1 << 30


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


parts = []
for part in sorted(p for p in os.listdir(out) if p.startswith(name + ".")):
    path = os.path.join(out, part)
    parts.append({"name": part, "size": os.path.getsize(path), "sha256": sha256(path)})
if sum(p["size"] for p in parts) != size:
    sys.exit("parts do not add up to the image size")

hotfixes = []
if os.path.isdir(fixes):
    for fix in sorted(os.listdir(fixes)):
        if not fix.endswith(".fix.zip"):
            continue
        path = os.path.join(fixes, fix)
        fields = {}
        with zipfile.ZipFile(path) as z:
            for line in z.read("manifest.txt").decode().splitlines():
                key, sep, value = line.partition("=")
                if sep:
                    fields[key] = value
        shutil.copyfile(path, os.path.join(out, fix))
        hotfixes.append({"file": fix, "name": fields.get("name", fix[:-8]),
                         "description": fields.get("description", ""),
                         "build": fields.get("build", ""),
                         "size": os.path.getsize(path), "sha256": sha256(path)})

minimum = ""
try:
    with open(os.path.join(os.path.dirname(fixes), "..", "minimum-andr36oid.txt")) as f:
        minimum = f.read().strip()
except OSError:
    pass

manifest = {
    "format": 1,
    "darkosen": version,
    "revision": int(revision),
    "upstream": {"repository": os.environ.get("UPSTREAM", ""), "tag": version,
                 "assets": json.loads(os.environ.get("UPSTREAM_ASSETS", "[]"))},
    "image": {"name": name, "filesystem": "erofs", "size": size, "sha256": digest,
              "parts": parts},
    # room for a later, somewhat larger release: a quarter on top, whole GiB
    "partition_bytes": -(-(size + size // 4) // GIB) * GIB,
    "minimum_andr36oid": minimum,
    "hotfixes": hotfixes,
}
with open(os.path.join(out, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
print(json.dumps(manifest, indent=2))
