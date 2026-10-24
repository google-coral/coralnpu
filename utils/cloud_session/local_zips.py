#!/usr/bin/env python3
"""OPT-IN, UNSAFE: point GitHub .zip dependencies at local zips, skipping sha256.

GitHub's .zip archives cannot be rebuilt byte-for-byte from git, so where
github.com/<owner>/<repo>/archive/*.zip is blocked, fill_gh_archives.py cannot
help. This script builds each zip locally from the pinned ref with
`git archive --format=zip` and rewrites the URL (to file://) and its sha256 in
the repository's .bzl files.

This DISABLES the sha256 check for those dependencies: their contents are only
as trustworthy as the git fetch of the pinned commit (or tag). The edits point
at local files, so never commit them; the script ends by printing the
`git checkout -- <files>` that undoes exactly its edits.

Refuses to run without --i-understand-this-skips-sha256.

usage: local_zips.py --i-understand-this-skips-sha256 [--repo ROOT] [--work DIR]
                     (--all | ZIP_URL...)
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys

ZIP_RE = re.compile(
    r"https://github\.com/([^/\s\"']+)/([^/\s\"']+)/archive/([^\s\"']+)\.zip"
)


def fetch(work, owner, repo, ref):
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
    sys.exit(f"cannot fetch {owner}/{repo} {ref}")


def rule_span(text, i):
    """Returns the [start, end) span of the rule call that contains offset i."""
    start = text.rfind("(", 0, i)
    ends = [
        e for e in (text.find("\n)", i), text.find("\n    )", i)) if e != -1
    ]
    return start, min(ends) if ends else len(text)


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument(
        "--i-understand-this-skips-sha256", dest="ack", action="store_true"
    )
    p.add_argument("--repo", default=".", help="repository root")
    p.add_argument(
        "--work",
        default=os.path.expanduser("~/.cache/coralnpu-gitsrc"),
        help="where the shallow git checkouts and built zips are kept"
    )
    p.add_argument(
        "--all",
        action="store_true",
        help="every GitHub .zip URL in the .bzl files"
    )
    p.add_argument("urls", nargs="*")
    args = p.parse_args()
    if not args.ack:
        sys.exit(
            "refusing: this skips sha256 verification; pass --i-understand-this-skips-sha256"
        )

    files = subprocess.run(["git", "-C", args.repo, "ls-files", "*.bzl"],
                           capture_output=True,
                           text=True,
                           check=True).stdout.split()
    urls = list(args.urls)
    if args.all:
        for f in files:
            urls += [
                m.group(0) for m in
                ZIP_RE.finditer(open(os.path.join(args.repo, f)).read())
            ]
    zdir = os.path.join(args.work, "zips")
    os.makedirs(zdir, exist_ok=True)
    patched = set()

    for url in sorted(set(urls)):
        m = ZIP_RE.fullmatch(url)
        if not m:
            sys.exit(f"not a GitHub archive .zip URL: {url}")
        owner, repo, ref = m.groups()
        for prefix in ("refs/tags/", "refs/heads/"):
            if ref.startswith(prefix):
                ref = ref[len(prefix):]
        name = re.sub(r"^[vV](?=\d)", "", ref).replace("/", "-")
        path, local = fetch(args.work, owner, repo, ref)
        out = os.path.join(
            zdir, f"{owner}__{repo}__{ref.replace('/', '-')}.zip"
        )
        subprocess.run([
            "git", "-C", path, "archive", "--format=zip",
            f"--prefix={repo}-{name}/", "-o", out, local
        ],
                       check=True)
        digest = hashlib.sha256(open(out, "rb").read()).hexdigest()
        hit = False
        for f in files:
            fpath = os.path.join(args.repo, f)
            text = open(fpath).read()
            if url not in text:
                continue
            start, end = rule_span(text, text.index(url))
            others = [
                u for u in re.findall(r"https://[^\s\"']+", text[start:end])
                if u != url
            ]
            if others:
                # A mirror that still serves the original bytes keeps sha256 checking intact.
                print(f"SKIPPED {f}: {url} (rule also lists {others[0]})")
                hit = True
                continue
            block = re.sub(
                r'sha256 = "[0-9a-f]{64}"',
                f'sha256 = "{digest}"',
                text[start:end],
                count=1
            )
            block = block.replace(url, "file://" + out)
            with open(fpath, "w") as fh:
                fh.write(text[:start] + block + text[end:])
            hit = True
            patched.add(f)
            print(
                f"PATCHED {f}: {url} -> {out} (sha256 {digest[:12]}, NOT VERIFIED)"
            )
        if not hit:
            print(f"NOT-FOUND {url}")
    if patched:
        print("Undo with: git checkout -- " + " ".join(sorted(patched)))


if __name__ == "__main__":
    main()
