#!/usr/bin/env python3
"""Compare the base images pinned in the Dockerfile against their upstream tags.

A digest pin stops taking upstream rebuilds, which is the point of the pin and
also its cost: a rebuilt base image (Debian security update) never reaches us
unless something notices. This does the noticing, on a schedule.

For every `FROM <image>@sha256:<digest>` line it resolves <image>:<tag> from the
registry without a docker daemon, picks the linux/amd64 manifest, and compares.

Exit 0 = everything matches. Exit 1 = drift (a new digest exists for a tag we
pin), after opening or updating an issue. Exit 2 = the check itself failed
(network, unparseable Dockerfile) - silence must never read as "no drift".

Stdlib only; runs under the runner's python3.
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request

DOCKERFILE = "Dockerfile"
PLATFORM = ("linux", "amd64")
FROM_RE = re.compile(r"^\s*FROM\s+(?P<image>[^\s]+?)(?:@(?P<digest>sha256:[0-9a-f]{64}))?(?:\s+AS\s+\S+)?\s*$", re.I)
REGISTRIES = {
    "docker.io": ("https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull",
                  "https://registry-1.docker.io/v2/{repo}/manifests/{ref}"),
    "ghcr.io": ("https://ghcr.io/token?scope=repository:{repo}:pull&service=ghcr.io",
                "https://ghcr.io/v2/{repo}/manifests/{ref}"),
}
ACCEPT = ",".join((
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
))


def split_image(image: str) -> tuple[str, str, str]:
    """'python:3.13.18-slim' -> ('docker.io', 'library/python', '3.13.18-slim')."""
    registry = "docker.io"
    rest = image
    if "/" in rest.split(":")[0]:
        first, rest = rest.split("/", 1)
        if "." in first or ":" in first or first == "localhost":
            registry = first
    tag = "latest"
    if ":" in rest:
        rest, tag = rest.rsplit(":", 1)
    if registry == "docker.io" and "/" not in rest:
        rest = "library/" + rest
    return registry, rest, tag


def token_for(registry: str, repo: str) -> str:
    url = REGISTRIES[registry][0].format(repo=repo)
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r).get("token") or json.load(r).get("access_token")


def get_manifest(registry: str, repo: str, ref: str, token: str) -> tuple[dict, dict]:
    url = REGISTRIES[registry][1].format(repo=repo, ref=ref)
    req = urllib.request.Request(url)
    req.add_header("Accept", ACCEPT)
    req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=30) as r:
        headers = {k.lower(): v for k, v in r.headers.items()}
        return json.load(r), headers


def platform_digest(registry: str, repo: str, tag: str) -> tuple[str, str]:
    """Return (current platform manifest digest, index digest) for the tag."""
    token = token_for(registry, repo)
    body, headers = get_manifest(registry, repo, tag, token)
    index_digest = headers.get("docker-content-digest", "")
    if body.get("manifests") is None:  # already a single-platform manifest
        return index_digest, index_digest
    for m in body["manifests"]:
        plat = m.get("platform") or {}
        if (plat.get("os"), plat.get("architecture")) == PLATFORM:
            return m["digest"], index_digest
    raise RuntimeError(f"no {PLATFORM[0]}/{PLATFORM[1]} manifest in {repo}:{tag}")


def pinned_froms(path: str) -> list[dict]:
    out = []
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            m = FROM_RE.match(line)
            if not m or not m.group("digest"):
                continue
            registry, repo, tag = split_image(m.group("image"))
            out.append({"line": lineno, "image": m.group("image"), "registry": registry,
                        "repo": repo, "tag": tag, "digest": m.group("digest")})
    return out


def open_or_update_issue(title: str, body: str) -> str:
    repo = os.environ.get("GITHUB_REPOSITORY")
    token = os.environ.get("GITHUB_TOKEN")
    if not repo or not token:
        return "issue: skipped (no GITHUB_TOKEN / GITHUB_REPOSITORY - local run)"
    api = f"https://api.github.com/repos/{repo}/issues"
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28"}

    def call(url, payload=None, method="GET"):
        data = json.dumps(payload).encode() if payload else None
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        if data:
            req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)

    existing = [i for i in call(api + "?state=open&per_page=100") if i["title"] == title]
    if existing:
        call(f"{api}/{existing[0]['number']}/comments", {"body": body}, "POST")
        return f"issue: commented on #{existing[0]['number']}"
    created = call(api, {"title": title, "body": body}, "POST")
    return f"issue: opened #{created['number']}"


def main() -> int:
    pins = pinned_froms(DOCKERFILE)
    if not pins:
        print(f"::error::no digest-pinned FROM lines found in {DOCKERFILE}")
        return 2

    rows, drifted = [], []
    for pin in pins:
        try:
            current, index = platform_digest(pin["registry"], pin["repo"], pin["tag"])
        except (urllib.error.URLError, urllib.error.HTTPError, RuntimeError, ValueError) as exc:
            print(f"::error::cannot resolve {pin['repo']}:{pin['tag']}: {exc}")
            return 2
        same = current == pin["digest"]
        rows.append(f"| `{pin['repo']}:{pin['tag']}` | `{pin['digest'][7:19]}` | "
                    f"`{current[7:19]}` | {'ok' if same else '**DRIFT**'} |")
        if not same:
            drifted.append((pin, current, index))

    table = "\n".join([
        "| pinned ref | pinned amd64 | current amd64 | |",
        "|---|---|---|---|",
        *rows,
    ])
    print(table)

    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(f"## Base image drift\n\n{table}\n\n")
            if drifted:
                fh.write("A pinned base image has been rebuilt upstream. Bump the pin in "
                         f"`{DOCKERFILE}`, rebuild, smoke-test, then re-pin the published digest.\n")

    if not drifted:
        print("no drift")
        if summary:
            with open(summary, "a", encoding="utf-8") as fh:
                fh.write("No drift: every pinned base still resolves to the digest in the Dockerfile.\n")
        return 0

    detail = "\n".join(
        f"- `{p['repo']}:{p['tag']}` line {p['line']}: pinned `{p['digest']}`, "
        f"now `{cur}` (index `{idx}`)" for p, cur, idx in drifted)
    body = ("The scheduled base-image check found a pinned base that has been rebuilt upstream.\n\n"
            f"{detail}\n\n{table}\n\n"
            "Bump the pin in `Dockerfile` to the current platform digest, rebuild, let the smoke "
            "test pass, publish, then re-pin the published image digest where it is consumed.\n")
    print(open_or_update_issue("Base image drift detected", body))
    for p, cur, idx in drifted:
        print(f"::warning file={DOCKERFILE},line={p['line']}::"
              f"{p['repo']}:{p['tag']} now resolves to {cur}, not the pinned {p['digest']}")
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # never let an exception read as a clean result
        print(f"::error::base-image-drift check failed: {exc}")
        sys.exit(2)
