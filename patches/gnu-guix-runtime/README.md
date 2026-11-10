<!-- SPDX-FileCopyrightText: 2026 Harish Narayanan -->
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# GNU Guix runtime

Guix can suspend one lowering while it builds inputs needed to continue.
The selected revision leaves that computation’s parameter bindings active
while another lowering runs. When a system and a Guix Home environment use
different transformations, this can make a builder name files that its
derivation does not declare as inputs.

`0001-preserve-lowering-contexts.patch` restores ordinary dynamic parameter
scope across suspension and resumption. It changes Guix’s evaluator, not
the installed system’s services. The patch includes upstream-style parameter
tests; our runtime checks also build small Home and system fixtures together
in both orders, using fresh input names for each run.

The correction is based on Guix
`7c39b1b1a0ad114ab5ceab0c53fb84dd0f990d9f` and has not been submitted upstream.
[Issue 76485](https://issues.guix.gnu.org/76485) explains why the previous
implementation avoided the C `with-fluids*` procedure. This patch uses
Guile’s ordinary `parameterize` syntax, compiled to VM fluid bindings.

The development evaluator recipe retains the base source, this patch and
the patched source in its profile. Remove the patch when an equivalent
upstream correction passes the same tests.
