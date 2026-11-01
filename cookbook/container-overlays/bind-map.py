#!/usr/bin/env python3
"""Write the bind map the container-side agtermctl wrapper translates paths with.

Usage: bind-map.py CONTAINER OUTPUT
Reads the container's bind mounts from `docker inspect` and writes the JSON
document the wrapper loads (bind_map: container path -> host path). Run it
on the Mac whenever the container's -v mounts change.
"""

import json
import subprocess
import sys


def main():
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} CONTAINER OUTPUT")
    container, out_path = sys.argv[1], sys.argv[2]
    try:
        raw = subprocess.run(
            ["docker", "inspect", "--format", "{{json .Mounts}}", container],
            capture_output=True, text=True, check=True,
        ).stdout
        bind_map = {
            m["Destination"]: m["Source"]
            for m in json.loads(raw)
            if m.get("Type") == "bind" and "Destination" in m and "Source" in m
        }
    except (subprocess.CalledProcessError, ValueError, KeyError) as e:
        sys.exit(f"bind-map: reading mounts of {container} failed: {e}")
    doc = {"container": container, "bind_map": bind_map, "store_roots": []}
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1, sort_keys=True)
    print(f"bind-map: wrote {len(bind_map)} bind(s) to {out_path}")


if __name__ == "__main__":
    main()
