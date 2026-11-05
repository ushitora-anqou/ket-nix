#!/usr/bin/env python
import argparse
import base64
import sys

import requests
import tomlkit
import yaml

use_latest = True

def calculate_hash(sha256_digest):
    return f"sha256-{base64.b64encode(bytes.fromhex(sha256_digest)).decode("ascii")}"

def find_latest(entries):
    for entry in entries:
        if not ("-rc" in entry["version"] or "-beta" in entry["version"]):
            return entry

def update_chart(chart):
    index_yaml = requests.get(f"{chart["repo"]}/index.yaml").content
    index = yaml.safe_load(index_yaml)
    entries = index["entries"][chart["name"]]
    if use_latest:
        latest = find_latest(entries)
    else:
        for entry in entries:
            if entry["version"] == chart["version"]:
                latest = entry
    if chart["version"] != latest["version"]:
        print(f"- {chart["name"]}: `{chart["version"]}` -> `{latest["version"]}`")
        chart["version"] = latest["version"]
    chart["hash"] = calculate_hash(latest["digest"])

def main():
    parser = argparse.ArgumentParser(prog="update-catalog")
    parser.add_argument("catalog")
    args = parser.parse_args()
    catalog_path = args.catalog

    with open(catalog_path) as f:
        catalog = tomlkit.load(f)

    for chart_id in catalog["chart"]:
        update_chart(catalog["chart"][chart_id])

    with open(catalog_path, "w") as f:
        f.write(tomlkit.dumps(catalog))

if __name__ == "__main__":
    sys.exit(main())
