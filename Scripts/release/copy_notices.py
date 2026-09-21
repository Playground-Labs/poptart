#!/usr/bin/env python3
"""Preserve license and notice files from every pinned dependency, including vendored code."""
import json
import re
import shutil
import sys
from pathlib import Path


def copy_notices(pins_path, checkouts, output):
    directories = {p.name.lower(): p for p in checkouts.iterdir() if p.is_dir()}
    for pin in json.loads(pins_path.read_text())["pins"]:
        identity = pin["identity"]
        directory = directories.get(identity.lower())
        if directory is None:
            raise ValueError(f"missing dependency checkout: {identity}")
        notices = [p for p in directory.rglob("*") if p.is_file() and ".git" not in p.parts
                   and re.search(r"(^|[-_])(LICENSE|LICENCE|NOTICE|COPYING)(\.[A-Za-z0-9-]+)?$", p.name, re.I)]
        if not notices:
            raise ValueError(f"missing dependency license: {identity}")
        for source in notices:
            destination = output / identity / source.relative_to(directory)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: copy_notices.py PACKAGE_RESOLVED CHECKOUTS OUTPUT_DIRECTORY")
    copy_notices(*(Path(value) for value in sys.argv[1:]))
