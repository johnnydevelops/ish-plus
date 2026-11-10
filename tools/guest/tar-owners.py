#!/usr/bin/env python3
"""Print debugfs commands that give every file in an ext4 image the owner,
group and mode recorded in the tar archive it was extracted from.

mke2fs -d copies a directory into an image but takes ownership from the host
files, which on macOS belong to the user who extracted them, not root.

Usage: tar-owners.py <archive>... | debugfs -w -f - <image>
"""
import sys
import tarfile

seen = set()
for archive in sys.argv[1:]:
    with tarfile.open(archive) as tar:
        for m in tar.getmembers():
            path = "/" + m.name.lstrip("./").rstrip("/")
            if path == "/" or path in seen:
                continue
            seen.add(path)
            if m.issym() or m.islnk():
                # debugfs follows nothing here; symlink owners matter little
                # and hard links share the inode of their target.
                if m.issym():
                    print(f'sif "{path}" uid {m.uid}')
                    print(f'sif "{path}" gid {m.gid}')
                continue
            kind = 0o040000 if m.isdir() else 0o100000
            print(f'sif "{path}" uid {m.uid}')
            print(f'sif "{path}" gid {m.gid}')
            print(f'sif "{path}" mode 0{kind | (m.mode & 0o7777):o}')
