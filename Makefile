# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later

.DEFAULT_GOAL := help
.NOTPARALLEL:

GUIX ?= guix
PYTHON ?= python3
build_dir ?= build
candidate ?= $(build_dir)/catalogue
assembly ?= $(build_dir)/assembly
release_dir ?= $(build_dir)/release
jobs ?=
cores ?=
only ?= python
runtime_archive ?=
source_archive ?=
runtime_sources ?=
version ?=
base_url ?=
guix_sources ?=

export GUIX PYTHON
export PYTHONDONTWRITEBYTECODE = 1
export BUILD_DIR = $(build_dir)
export MAX_JOBS = $(jobs)
export CORES = $(cores)

operations := plan-image build-image build-candidate build-installer build-release \
              check-code check-image check-installer check-release

# Validate the whole request before Make starts any operation.
ifneq ($(strip $(MAKECMDGOALS)),)
ifneq ($(MAKECMDGOALS),help)
ifneq ($(words $(MAKECMDGOALS)),2)
$(error Use make <verb> <noun>. Run make help for the available commands)
endif
verb := $(word 1,$(MAKECMDGOALS))
noun := $(word 2,$(MAKECMDGOALS))
ifeq ($(filter $(verb)-$(noun),$(operations)),)
$(error Unknown command: $(MAKECMDGOALS). Run make help)
endif
ifneq ($(origin only),file)
ifneq ($(verb)-$(noun),check-code)
$(error only= selects a check in make check code)
endif
endif
$(verb): _$(verb)-$(noun)
$(noun):
	@:
.PHONY: $(verb) $(noun)
endif
endif

.PHONY: help $(addprefix _,$(operations))
help:
	@printf '%s\n' \
	  'Hello Guix: make <verb> <noun> [setting=value]' \
	  '' \
	  'make plan image       Prepare Guix and show the image build/download plan.' \
	  'make build image      Build and check the installation image.' \
	  'make build candidate  Freeze source and build its image and catalogue.' \
	  'make build installer  Assemble the Mac installer and its source tree.' \
	  'make build release    Create the two downloads, launcher and checksums.' \
	  'make check code       Prepare Asahi source and run the local Python tests.' \
	  'make check image      Check the existing installation image.' \
	  'make check installer  Verify the assembled installer and its source tree.' \
	  'make check release    Verify the release files against their checksums.' \
	  '' \
	  'check code: only=python|hardware|source|desktop|configuration|installation-target|installation' \
	  'Locations: build_dir, candidate, assembly, release_dir.' \
	  'Resources: optional jobs and cores; otherwise use the build tools defaults.' \
	  'Installer inputs: runtime_archive, source_archive, runtime_sources (optional).' \
	  'Release inputs: version, base_url (HTTPS), guix_sources (required).' \
	  'Tools: GUIX, PYTHON. See docs/development.md for the complete flow.'

_plan-image:
	bash scripts/build_image.sh --dry-run

_build-image:
	bash scripts/build_image.sh

_build-candidate:
	bash scripts/build_candidate.sh "$(candidate)"

_build-installer:
	"$(PYTHON)" scripts/macos_bundle.py build --catalogue "$(candidate)" --output "$(assembly)" \
	  $(if $(runtime_archive),--runtime-archive "$(runtime_archive)") \
	  $(if $(source_archive),--source-archive "$(source_archive)") \
	  $(if $(runtime_sources),--runtime-sources "$(runtime_sources)") \
	  $(if $(cores),--cores "$(cores)")

_build-release:
	"$(PYTHON)" scripts/macos_bundle.py release --assembly "$(assembly)" \
	  --output "$(release_dir)" --version "$(version)" --base-url "$(base_url)" \
	  --guix-sources "$(guix_sources)"

_check-code:
	bash scripts/check_code.sh "$(only)" "$(source_archive)"

_check-image:
	"$(PYTHON)" scripts/asahi_payload.py check --package "$(BUILD_DIR)/payload"

_check-installer:
	"$(PYTHON)" scripts/macos_bundle.py check --assembly "$(assembly)"

_check-release:
	"$(PYTHON)" scripts/macos_bundle.py check-release --directory "$(release_dir)"
