# coralnpu_mpact Workspace Override

This directory contains workaround files used to override the workspace configuration of the external repository `@coralnpu_mpact`.

## Why this exists

In the legacy Bazel `WORKSPACE` system, transitive dependencies of external repositories are not automatically resolved. Typically, they must either:

1. Be declared in the root project's `WORKSPACE` (or loaded via macros),
  polluting the root project's dependency list.
2. Be resolved by the external repository itself if it has a non-empty
  `WORKSPACE` file. However, fetched repositories (especially if they are
  designed to be used as submodules or via copybara) may have empty or missing
  `WORKSPACE` files in the context they are fetched.

`@coralnpu_mpact` has a complex set of transitive dependencies (e.g., `@com_google_mpact-riscv`, `@rules_python`, etc.). To avoid polluting our dependency declarations with these dependencies, we use Bazel's `workspace_file` attribute in `http_archive` (in `rules/repo_defs.bzl`) to inject the custom `WORKSPACE` template found in this directory (`third_party/coralnpu_mpact/WORKSPACE`) into the fetched repository.

This allows `@coralnpu_mpact` to resolve and compile its own dependencies hermetically within its own external workspace context.

## Bzlmod Transition and Removal Plan

Bzlmod (Bazel's modular dependency system) natively solves the transitive dependency problem. Under Bzlmod:

1. `@coralnpu_mpact` will be defined as a Bazel module with its own `MODULE.bazel` file specifying its dependencies (`mpact-riscv`, `rules_python`, etc.).
2. The root project will simply depend on `coralnpu_mpact` as a module.
3. Bazel will automatically resolve the transitive dependencies based on `coralnpu_mpact`'s `MODULE.bazel`, without requiring any overrides or root-level declarations of transitive dependencies.

### Removal Steps

1. Transition `@coralnpu_mpact` to be a Bazel module (adding `MODULE.bazel` to its repository).
2. Update our `MODULE.bazel` to depend on `coralnpu_mpact`.
3. Remove `third_party/coralnpu_mpact/` directory entirely, as the override will no longer be needed.
4. Remove the `workspace_file` override pointing to this directory in `rules/repo_defs.bzl`.
