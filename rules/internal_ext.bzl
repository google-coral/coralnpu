"""Module extension that delegates to @internal_check//:repositories.bzl."""

load("@internal_check//:repositories.bzl", "internal_repos")

def _internal_ext_impl(ctx):
    internal_repos()
    return ctx.extension_metadata(reproducible = True)

internal_ext = module_extension(implementation = _internal_ext_impl)
