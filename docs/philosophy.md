<!-- SPDX-FileCopyrightText: 2026 Harish Narayanan -->
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# The freedom to continue

When I share something, I want the next person to be able to understand
it, use it, change it and continue on their own terms. That is the
standard I want Hello Guix to meet.

As a teenager, I found in [GNU][gnu] a coherent expression of this
instinct. I could get inside the tools I depended on, learn from them and
pass my changes on. [Copyleft][copyleft] appealed to me because it sought
to preserve those freedoms for the next recipient too. As I’ve grown
older, this understanding has deepened into a broader concern with how
we share work and what someone else needs to make it their own.

## Freedom we can use

Licences such as the [GPL][gpl] protect our rights to study, change and share
a program. Yet that permission is hard to exercise when the program’s
structure obscures its ideas or its documentation leaves us guessing.

These rights give us *legal agency*. The tools and working materials we
need to exercise them give us *practical agency*. I want to make
*intellectual agency* equally explicit: the ability to understand the
work, reason about it and form our own ideas.

A work is not fully shared if its ideas remain needlessly opaque to
someone willing to learn. Making those ideas understandable is a
responsibility of the design itself.

## A way into the ideas

A program is an expression of [a way of thinking about a problem][sicp].
In Hello Guix, I want that thinking to be visible in the architecture: the
concepts we choose, the responsibilities of each part and the ways those
parts fit together.

The code’s names and interfaces should express those concepts, so a reader
can see how a change would fit into the wider design or how a part could
serve a different purpose. Documentation should help them explore that
reasoning and understand the choices behind it.

This is also why I value [modularity and composability][sicp-modularity].
Parts we can understand on their own can be combined in ways their author
did not anticipate. I would still choose a straightforward design someone
can follow over elaborate abstractions they cannot.

## Building on each other’s work

In building Hello Guix, we are already benefiting from this kind of
sharing. [Asahi][asahi], the [Asahi Guix Channel][asahi-channel] and
[GNU Guix][guix] give us work we can understand, combine and extend. I want
our additions to give someone else that same freedom. Our licence choices
support that relationship. [COPYING](../COPYING) explains which terms
apply to each part.

I use these principles to judge contributions: does a change help someone
understand, maintain or extend the work, and can we explain why it
belongs? They add no restrictions to the rights granted by its licences,
but they ask more of us as authors: to make our thinking coherent and give
someone willing to learn a clear path into the ideas.

Questions from someone learning the code can show us where its structure
or explanation is unclear. We should take time to understand what they
found difficult and use that to improve the work.

## What we pass on

Hello Guix works with Apple hardware, and installing it begins in macOS.
I accept that proprietary dependency as part of the project, but you
should know about it before deciding whether Hello Guix suits you.

The tools I use during development are a different matter. I use an LLM
to help with the work. It can be useful for repetitive tasks such as
testing, but I must still understand and be able to explain what I share.
That choice should leave you free to work on the code with tools that
accord with your own convictions. The code’s structure and its explanation
should let you reason about changes yourself.

Take the ideas you find useful here and put them to work on questions of
your own. When you share what you make, give the next person the rights,
materials and understanding to continue on their own terms.

[gnu]: https://www.gnu.org/philosophy/philosophy.html
[copyleft]: https://www.gnu.org/licenses/copyleft.html
[gpl]: https://www.gnu.org/licenses/gpl-3.0.html
[asahi]: https://asahilinux.org/
[asahi-channel]: https://codeberg.org/asahi-guix/channel
[guix]: https://guix.gnu.org/
[sicp]:
  https://mitp-content-server.mit.edu/books/content/sectbyfn/books_pres_0/6515/sicp.zip/full-text/book/book-Z-H-7.html
[sicp-modularity]:
  https://mitp-content-server.mit.edu/books/content/sectbyfn/books_pres_0/6515/sicp.zip/full-text/book/book-Z-H-10.html
