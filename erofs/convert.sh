#!/bin/bash
# convert.sh <dArkOSen disk image> <output folder> <dArkOSen version> <revision>
#
# Takes the root filesystem out of a dArkOSen release image and writes it again
# as a compressed read-only EROFS image, packed with xz (and cut into parts only
# if it is still too large for one GitHub release file), with a manifest.json
# that describes it. Nothing in the
# filesystem is changed, added or left out: after writing, every file, link,
# owner, mode and extended attribute is compared with the original.
#
# Needs root (loop devices, mounts), sfdisk, btrfs support, erofs-utils, attr.
set -euo pipefail

image=$1 out=$2 version=$3 revision=$4
here=$(cd "$(dirname "$0")" && pwd)
part_bytes=$((2040 * 1024 * 1024))   # GitHub takes release files under 2 GiB only
work=$(mktemp -d "$(dirname "$out")/work.XXXXXX")   # beside the output, never in it
src=$work/src new=$work/new
mkdir -p "$src" "$new"
src_loop= new_loop=

cleanup() {
	mountpoint -q "$new" && umount "$new"
	mountpoint -q "$src" && umount "$src"
	[ -z "$new_loop" ] || losetup -d "$new_loop" || :
	[ -z "$src_loop" ] || losetup -d "$src_loop" || :
	rm -rf "$work"
}
trap cleanup EXIT

# The root filesystem is the first Linux (type 83) partition of the MBR image,
# the same one the console picks.
read -r start sectors < <(sfdisk -J "$image" | python3 -c '
import json, sys
for p in json.load(sys.stdin)["partitiontable"]["partitions"]:
    if p["type"].lower() in ("83", "0fc63daf-8483-4772-8e79-3d69d8477de4"):
        print(p["start"], p["size"]); break
else:
    sys.exit("no Linux partition in the image")')
echo "root filesystem: start sector $start, $sectors sectors"

src_loop=$(losetup --find --show --read-only --offset $((start * 512)) --sizelimit $((sectors * 512)) "$image")
fstype=$(blkid -o value -s TYPE "$src_loop")
echo "source filesystem: $fstype"
case $fstype in
btrfs) mount -t btrfs -o ro "$src_loop" "$src" 2>/dev/null ||
	mount -t btrfs -o ro,rescue=nologreplay "$src_loop" "$src" ;;
ext4) mount -t ext4 -o ro,noload "$src_loop" "$src" ;;
*) echo "unexpected root filesystem type: $fstype" >&2; exit 1 ;;
esac
[ -x "$src/bin/sh" ] || [ -L "$src/bin" ] || { echo "this does not look like a root filesystem" >&2; exit 1; }

name=dArkOSen_R36_$version.erofs.img
# Same options the console uses when it converts an image itself, with the
# stronger lz4hc packer: smaller, and read back exactly like lz4.
mkfs.erofs -b4096 -zlz4hc -E^xattr-name-filter --preserve-mtime --quiet "$out/$name" "$src"
fsck.erofs "$out/$name"

new_loop=$(losetup --find --show --read-only "$out/$name")
mount -t erofs -o ro "$new_loop" "$new"

# What must be identical: kind, mode, owner, group, link target, size of every
# file and link, modification time, extended attributes, and file contents.
listing() {
	(cd "$1" && find . -xdev \( -type d -printf 'd %m %U %G %T@ %p\n' \) -o \
		\( -not -type d -printf '%y %m %U %G %s %T@ %l %p\n' \) | LC_ALL=C sort)
}
attrs() {
	(cd "$1" && getfattr -R -h -d -m - -e hex . 2>/dev/null | LC_ALL=C sort)
}
hashes() {
	(cd "$1" && find . -xdev -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum)
}
listing "$src" > "$work/src.list"; listing "$new" > "$work/new.list"
cmp "$work/src.list" "$work/new.list" || { diff "$work/src.list" "$work/new.list" | head -40; echo "file listing differs" >&2; exit 1; }
attrs "$src" > "$work/src.attr"; attrs "$new" > "$work/new.attr"
cmp "$work/src.attr" "$work/new.attr" || { diff "$work/src.attr" "$work/new.attr" | head -40; echo "extended attributes differ" >&2; exit 1; }
hashes "$src" > "$work/src.sha"; hashes "$new" > "$work/new.sha"
cmp "$work/src.sha" "$work/new.sha" || { diff "$work/src.sha" "$work/new.sha" | head -40; echo "file contents differ" >&2; exit 1; }
echo "verified: $(wc -l < "$work/src.list") entries, $(wc -l < "$work/src.sha") files identical"
(cd "$src" && du -sxh . 2>/dev/null | sed 's/^/source size: /')

umount "$new"; losetup -d "$new_loop"; new_loop=
umount "$src"; losetup -d "$src_loop"; src_loop=

size=$(stat -c %s "$out/$name")
sum=$(sha256sum "$out/$name" | cut -d' ' -f1)
# Packed with xz for the download. Only cut into parts when the packed file is
# still too large for one release file.
xz -T0 -6 "$out/$name"
packed_size=$(stat -c %s "$out/$name.xz")
packed_sum=$(sha256sum "$out/$name.xz" | cut -d' ' -f1)
echo "image $size bytes, packed $packed_size bytes"
if [ "$packed_size" -gt "$part_bytes" ]; then
	(cd "$out" && split -b "$part_bytes" -d -a 3 --numeric-suffixes=1 "$name.xz" "$name.xz.")
	rm "$out/$name.xz"
fi

python3 "$here/manifest.py" "$out" "$name" "$size" "$sum" "$version" "$revision" "$here/hotfixes/$version" "$packed_size" "$packed_sum"
(cd "$out" && sha256sum -- * > "$work/sums")
mv "$work/sums" "$out/SHA256SUMS"
ls -la "$out"
