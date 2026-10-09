#!/usr/bin/env python3
"""check-images.py — every container image the repo pins must exist in its registry.

A nonexistent tag only shows up on the box, in the middle of the first boot. This resolves each
reference (Docker Hub, ghcr.io, lscr.io, quay.io) with a manifest HEAD request and exits 1 if any
is missing. Needs network + docker compose; not part of the offline bats run (see tests/images.bats).

    scripts/check-images.py            check everything
    scripts/check-images.py --list     just print the image references
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ACCEPT = ",".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])
# Locally built (docker/net/caddy/Dockerfile): not in any registry.
LOCAL = {"tvbox/caddy-cloudflare"}
def example_env():
    """Defaults the real .env starts from (the Immich version is pinned there)."""
    out = {}
    for line in open(os.path.join(REPO, "docker", ".env.example"), errors="replace"):
        m = re.match(r"^([A-Z0-9_]+)=([^#\s]*)", line)
        if m and m.group(2):
            out[m.group(1)] = m.group(2)
    return out


DUMMY_ENV = {
    "PIHOLE_PASS": "x", "IMMICH_DB_PASSWORD": "x", "NEXTCLOUD_DB_PASSWORD": "x",
    "NEXTCLOUD_DB_ROOT_PASSWORD": "x", "NEXTCLOUD_ADMIN_PASSWORD": "x", "DOMAIN": "example.org",
    "LAN_IP": "192.168.1.10", "COMPOSE_PROFILES": "media,docs,torrent,public,agent",
}
DUMMY_ENV = {**example_env(), **DUMMY_ENV}


def compose_images(path, extra_env=None):
    env = {**os.environ, **DUMMY_ENV, **(extra_env or {})}
    cmd = ["docker", "compose", "--env-file", "/dev/null", "-f", path, "config", "--images"]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, cwd=os.path.dirname(path))
    if out.returncode != 0:
        sys.exit(f"docker compose config failed for {path}:\n{out.stderr}")
    return {l.strip() for l in out.stdout.splitlines() if l.strip()}


def script_images():
    """Images that scripts run directly: `docker run ... image:tag`."""
    found = set()
    for root, _, files in os.walk(os.path.join(REPO, "scripts")):
        for f in files:
            if not f.endswith((".sh", ".py")):
                continue
            text = open(os.path.join(root, f), errors="replace").read()
            for m in re.finditer(r"\b(trufflesecurity/[a-z0-9._-]+:[A-Za-z0-9._-]+)", text):
                found.add(m.group(1))
    return found


def token(host, repo):
    if host == "registry-1.docker.io":
        url = f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull"
    else:
        url = f"https://{host}/token?service={host}&scope=repository:{repo}:pull"
    return json.load(urllib.request.urlopen(url, timeout=30))["token"]


def exists(ref):
    name, _, tag = ref.rpartition(":")
    if not name or "/" in tag:          # no tag given: implicit :latest
        name, tag = ref, "latest"
    parts = name.split("/")
    if parts[0] in ("ghcr.io", "quay.io"):
        host, repo = parts[0], "/".join(parts[1:])
    elif parts[0] == "lscr.io":
        host, repo = "ghcr.io", "/".join(parts[1:])      # lscr.io is a front for ghcr.io
    elif "." in parts[0] or ":" in parts[0]:
        return None                                       # some other registry: not checked
    else:
        host, repo = "registry-1.docker.io", name if "/" in name else f"library/{name}"
    try:
        req = urllib.request.Request(
            f"https://{host}/v2/{repo}/manifests/{tag}", method="HEAD",
            headers={"Authorization": "Bearer " + token(host, repo), "Accept": ACCEPT})
        return urllib.request.urlopen(req, timeout=30).status == 200
    except urllib.error.HTTPError as e:
        return False if e.code == 404 else None
    except (urllib.error.URLError, OSError):
        return None


def main():
    refs = set()
    refs |= compose_images(os.path.join(REPO, "docker", "compose.yml"))
    ml = os.path.join(REPO, "docker", "ml-laptop", "compose.yml")
    if os.path.exists(ml):
        refs |= compose_images(ml, {"COMPOSE_PROFILES": "photos,audio,ollama"})
    refs |= script_images()
    refs = sorted(r for r in refs if r.rpartition(":")[0] not in LOCAL and r not in LOCAL)
    if "--list" in sys.argv:
        print("\n".join(refs))
        return 0
    bad = unknown = 0
    for r in refs:
        ok = exists(r)
        print(("ok       " if ok else "MISSING  " if ok is False else "unknown  ") + r)
        bad += ok is False
        unknown += ok is None
    if unknown:
        print(f"{unknown} reference(s) could not be checked (network/registry)", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
