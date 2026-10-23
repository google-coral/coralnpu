# Running CoralNPU builds and tests in a Claude Code cloud session

The SessionStart hook in `.claude/hooks/session-start.sh` prepares a cloud
session container: it installs the system packages and lint tools of the CI
image (`utils/coralnpu.dockerfile`), installs Bazel through bazelisk, and,
where GitHub source archives cannot be downloaded, seeds Bazel's repository
cache from git. The scripts here cover the rest.

## Network

The session's network policy must allow the Bazel hosts
(`bcr.bazel.build`, `mirror.bazel.build`, `releases.bazel.build`) and the
non-GitHub download hosts the build uses (`ftp.gnu.org`, `sourceforge.net`,
`opensecura.googlesource.com`, `www.antlr.org`, `storage.googleapis.com`,
`repo1.maven.org`).

Cloud sessions may still refuse `github.com/<owner>/<repo>/archive/*` for
repositories that are not attached to the session, while allowing anonymous
`git fetch` of them. The two scripts below work around that.

## `.tar.gz` dependencies: `fill_gh_archives.py`

GitHub builds a `.tar.gz` archive as
`git archive --prefix=<repo>-<ref>/ <ref> | gzip -n -6`, so the script rebuilds
the identical bytes from the pinned ref and stores them in the repository cache
under their sha256. Bazel still verifies each archive against the sha256 in the
`.bzl` files. The hook runs it automatically when archive downloads are blocked;
to run it by hand:

```bash
python3 -I utils/cloud_session/fill_gh_archives.py --repo .
```

Build with `--bazelrc=utils/cloud_session/cloud.bazelrc`, which turns off the
URL-based canonical id so Bazel finds the seeded entries.

## `.zip` dependencies: `local_zips.py` (opt-in, skips sha256)

GitHub's `.zip` archives cannot be rebuilt byte-for-byte. `local_zips.py` builds
each zip from the pinned ref and rewrites the dependency's URL to the local file
and its sha256 to the local file's hash. **This disables sha256 verification for
those dependencies**: their contents are only as trustworthy as the git fetch of
the pinned commit or tag. Rules that also list a non-GitHub mirror are left
alone. The rewritten files point at local paths: never commit them.

```bash
python3 -I utils/cloud_session/local_zips.py --i-understand-this-skips-sha256 --all
# ... build and test ...
# then run the `git checkout -- <files>` line the script printed, which
# restores only the .bzl files it rewrote
```

## Running the cocotb regression

This runs every Verilator cocotb target that CI runs (no `manual` or `vcs`
tags) and collects each testcase's result and simulation time:

```bash
bazel query 'kind(cocotb_test, tests(//...)) except attr(tags, "\bmanual\b", //...) except attr(tags, "\bvcs\b", //...)' \
  > /tmp/cocotb_targets.txt
bazel --bazelrc=utils/cloud_session/cloud.bazelrc test --keep_going \
  --target_pattern_file=/tmp/cocotb_targets.txt 2>&1 | tee /tmp/cocotb.log
python3 -I utils/cloud_session/parse_cocotb_results.py /tmp/cocotb.log \
  /tmp/cocotb_targets.txt "$(readlink -f bazel-testlogs)" /tmp/cocotb_results
```

`parse_cocotb_results.py` also lists targets that Bazel passed but that ran no
testcase (a testcase name in `BUILD` the test module does not define).
