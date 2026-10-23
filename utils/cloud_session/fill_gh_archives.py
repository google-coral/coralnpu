#!/usr/bin/env python3
"""Seed Bazel's repository cache with GitHub source archives rebuilt from git.

Some sandboxed environments (e.g. Claude Code cloud sessions) block
https://github.com/<owner>/<repo>/archive/* downloads but still allow anonymous
`git fetch`. GitHub builds its .tar.gz archives as
`git archive --format=tar --prefix=<repo>-<ref>/ <ref> | gzip -n -6`, so the
same bytes can be rebuilt locally from the pinned ref and stored in the
repository cache under their sha256. Bazel still checks every archive against
the sha256 in the .bzl files: an archive whose bytes differ is simply never
used. GitHub .zip archives cannot be reproduced this way (see local_zips.py).

Bazel only reads such entries when the default canonical id is off, so build
with utils/cloud_session/cloud.bazelrc.

usage: fill_gh_archives.py [--cache DIR] [--work DIR] (--repo ROOT | URL_FILE...)
"""
import argparse
import hashlib
import os
import re
import subprocess

URL_RE = re.compile(
    r"https://(?:github\.com/([^/\s\]\"']+)/([^/\s\]\"']+)/archive/(.+?)|"
    r"codeload\.github\.com/([^/\s\]\"']+)/([^/\s\]\"']+)/tar\.gz/(.+?))"
    r"(?=[\s\],'\"]|$)"
)


def find_urls(args):
    texts = []
    if args.repo:
        files = subprocess.run([
            "git", "-C", args.repo, "ls-files", "*.bzl", "MODULE.bazel"
        ],
                               capture_output=True,
                               text=True,
                               check=True).stdout.split()
        texts = [
            open(os.path.join(args.repo, f), errors="replace").read()
            for f in files
        ]
    for f in args.url_files:
        texts.append(open(f, errors="replace").read())
    # Skip templated URLs ("{}" placeholders filled in by Starlark).
    return sorted({
        m.group(0)
        for t in texts
        for m in URL_RE.finditer(t)
        if "{" not in m.group(0)
    })


def fetch(work, owner, repo, ref):
    """Shallow-fetches `ref` (tag, branch or commit) into refs/cc/<ref>."""
    path = os.path.join(work, f"{owner}__{repo}")
    if not os.path.isdir(path):
        subprocess.run(["git", "init", "-q", path], check=True)
    local = f"refs/cc/{ref}"
    for spec in (f"refs/tags/{ref}", ref):
        try:
            subprocess.run([
                "git", "-C", path, "fetch", "-q", "--depth", "1",
                f"https://github.com/{owner}/{repo}", f"+{spec}:{local}"
            ],
                           check=True,
                           capture_output=True,
                           timeout=1200)
            return path, local
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            pass
    return None, None


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument(
        "--cache",
        default=os.path.expanduser(
            f"~/.cache/bazel/_bazel_{os.environ.get('USER', 'root')}"
            "/cache/repos/v1"
        ),
        help="Bazel repository cache (`bazel info repository_cache`)"
    )
    p.add_argument(
        "--work",
        default=os.path.expanduser("~/.cache/coralnpu-gitsrc"),
        help="where the shallow git checkouts are kept"
    )
    p.add_argument(
        "--repo",
        help="repository root: seed every GitHub archive its .bzl files name"
    )
    p.add_argument(
        "url_files", nargs="*", help="files to scan for archive URLs"
    )
    args = p.parse_args()
    os.makedirs(args.work, exist_ok=True)

    seeded = 0
    urls = find_urls(args)
    for url in urls:
        m = URL_RE.match(url)
        owner, repo, ref = m.group(1, 2, 3) if m.group(1) else m.group(4, 5, 6)
        if ref.endswith(".zip"):
            continue  # Not reproducible byte-for-byte; see local_zips.py.
        if ref.endswith(".tar.gz"):
            ref = ref[:-len(".tar.gz")]
        for prefix in ("refs/tags/", "refs/heads/"):
            if ref.startswith(prefix):
                ref = ref[len(prefix):]
        # GitHub drops a leading v/V from a version tag in the archive's top directory.
        name = re.sub(r"^[vV](?=\d)", "", ref).replace("/", "-")
        path, local = fetch(args.work, owner, repo, ref)
        if not path:
            print(f"FETCH-FAIL {url}", flush=True)
            continue
        tar = subprocess.run([
            "git", "-C", path, "archive", "--format=tar",
            f"--prefix={repo}-{name}/", local
        ],
                             capture_output=True,
                             check=True).stdout
        data = subprocess.run(["gzip", "-n", "-6"],
                              input=tar,
                              capture_output=True,
                              check=True).stdout
        digest = hashlib.sha256(data).hexdigest()
        entry = os.path.join(
            args.cache, "content_addressable", "sha256", digest
        )
        os.makedirs(entry, exist_ok=True)
        with open(os.path.join(entry, "file"), "wb") as f:
            f.write(data)
        seeded += 1
        print(f"SEEDED {digest[:12]} {url}", flush=True)
    print(f"urls={len(urls)} seeded={seeded}")


if __name__ == "__main__":
    main()
