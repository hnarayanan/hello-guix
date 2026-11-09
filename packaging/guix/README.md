# Guix packaging

The source lives in `hello-guix/`, with separate `system/` and `installer/`
modules. Guix compiles every Scheme file beneath a channel's module root,
so the channel uses a small directory of relative file links:

- `channel/` exposes the system modules, selected by `.guix-channel`.
- `installer/` exposes the Linux installer modules for image builds.

Each link points to its corresponding file in `hello-guix/`. Image builds
put both directories on the module path, alongside the patched GNU Guix
installer. Tests and standalone build recipes stay outside those paths.
Guix uses its normal channel compiler; there is no custom channel builder.

When adding a Scheme module, add its relative file link to the appropriate
directory too. `make check code` checks that the views are complete, that
module names match their paths, and that saved source and archives preserve
the links. Source snapshots accept only these links, pointing to their
matching files within the source tree.
