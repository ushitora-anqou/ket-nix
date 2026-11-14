#!/usr/bin/env python
import argparse
import base64
import sys
import urllib.parse

import requests
import semver
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
    if chart["repo"].startswith(("http://", "https://")):
        version, hash = fetch_from_index_yaml(chart)
    elif chart["repo"].startswith("oci://"):
        version, hash = fetch_from_oci(chart)
    else:
        raise RuntimeError("invalid repository")

    if chart["version"] != version:
        print(f"- {chart["name"]}: `{chart["version"]}` -> `{version}`")
        chart["version"] = version
    chart["hash"] = hash

def fetch_from_index_yaml(chart):
    index_yaml = requests.get(f"{chart["repo"]}/index.yaml").content
    index = yaml.safe_load(index_yaml)
    entries = index["entries"][chart["name"]]
    if use_latest:
        latest = find_latest(entries)
    else:
        for entry in entries:
            if entry["version"] == chart["version"]:
                latest = entry
    return latest["version"], calculate_hash(latest["digest"])

def parse_www_authenticate_header(header):
    body = header.removeprefix("Bearer ")
    params = {}
    for kv in map(str.strip, body.split(",")):
        key, value = kv.split("=")
        value = value.strip('"')
        params[key] = value
    return params

def authenticate(base_url):
    resp = requests.get(f"{base_url}/v2")
    if resp.status_code != 401:
        return None
    params = parse_www_authenticate_header(resp.headers["www-authenticate"])
    resp = requests.get(f"{params["realm"]}", params={"service": params["service"], "scope": params["scope"]})
    token = resp.json()["token"]
    return f"Bearer {token}"

def oci_list_tags(base_url, repo_url_path, name, authorization):
    url = urllib.parse.urljoin(base_url, f"/v2{repo_url_path}/{name}/tags/list")
    resp = requests.get(url, headers={"authorization": authorization})
    return resp.json()["tags"]

def find_latest_semver(tags):
    latest = None
    for tag in tags:
        try:
            ver = semver.Version.parse(tag)
            if ver.prerelease is not None or ver.build is not None:
                continue
            if latest is None or semver.compare(latest, tag) < 0:
                latest = tag
        except ValueError:
            pass
    return latest

def oci_get_manifest(base_url, repo_url_path, name, authorization, version):
    url = urllib.parse.urljoin(base_url, f"/v2{repo_url_path}/{name}/manifests/{version}")
    resp = requests.get(url, headers={"authorization": authorization})
    return resp.json()

def fetch_from_oci(chart):
    repo_url = urllib.parse.urlsplit(chart["repo"])
    base_url = f"https://{repo_url.netloc}"
    authorization = authenticate(base_url)

    version = chart["version"]
    if use_latest:
        tags = oci_list_tags(base_url, repo_url.path, chart["name"], authorization)
        version = find_latest_semver(tags)

    manifest = oci_get_manifest(base_url, repo_url.path, chart["name"], authorization, version)
    digest = manifest["layers"][0]["digest"]
    if not digest.startswith("sha256:"):
        raise RuntimeError("invalid digest")
    return version, calculate_hash(digest.removeprefix("sha256:"))

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
