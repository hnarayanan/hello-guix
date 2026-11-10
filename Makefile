# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later

.DEFAULT_GOAL := help
.NOTPARALLEL:

GUIX ?= guix
PYTHON ?= python3
build_dir ?= build
catalogue ?= $(build_dir)/catalogue
assembly ?= $(build_dir)/assembly
package_dir ?= $(build_dir)/package
jobs ?=
cores ?=
vm_memory ?=
boot_reference ?=
channel_profile ?=
configuration ?=
only ?= python
runtime_archive ?=
source_archive ?=
runtime_sources ?=
version ?=
base_url ?=

ifneq ($(origin candidate),undefined)
$(error Use catalogue= instead of candidate=)
endif
ifneq ($(origin release_dir),undefined)
$(error Use package_dir= instead of release_dir=)
endif

export GUIX PYTHON
export PYTHONDONTWRITEBYTECODE = 1
export BUILD_DIR = $(build_dir)
export MAX_JOBS = $(jobs)
export CORES = $(cores)
export VM_MEMORY = $(vm_memory)
export BOOT_REFERENCE = $(boot_reference)
export CHECK_CHANNEL_PROFILE = $(channel_profile)
export CHECK_CONFIGURATION = $(configuration)

operations := plan-system build-system plan-image build-image build-installer build-package \
              check-code check-image check-installer check-package

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
ifneq ($(strip $(configuration)),)
ifeq ($(filter $(verb)-$(noun),plan-system build-system),)
ifneq ($(verb)-$(noun):$(only),check-code:runtime)
$(error configuration= is for make check code only=runtime or make plan/build system)
endif
endif
endif
ifneq ($(strip $(channel_profile)),)
ifneq ($(verb)-$(noun):$(only),check-code:configuration)
$(error channel_profile= is for make check code only=configuration)
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
	  'make plan system      Describe a system build using the selected channel profile.' \
	  'make build system     Build a reviewed system and retain its result and provenance.' \
	  'make plan image       Preview image build steps and paths without building or downloading.' \
	  'make build image      Save source, build and check the image and its catalogue.' \
	  'make build installer  Assemble the Mac installer and its source tree.' \
	  'make build package    Create the two downloads, launcher and checksums.' \
	  'make check code       Run the local Python tests.' \
	  'make check image      Verify the image, catalogue and saved source.' \
	  'make check installer  Verify the assembly and test its bundled runtime on macOS.' \
	  'make check package    Verify the download files against their checksums.' \
	  '' \
	  'check code: only=python|runtime|runtime-channel|runtime-system|hardware|source|desktop|configuration|installation-target|installation' \
	  'Runtime checks use GUIX as selected; other Guix checks use the release channels.' \
	  'Runtime-channel: authenticate and replay a signed local test channel.' \
	  'Runtime-system: exercise native commands in a disposable Linux container.' \
	  'Runtime: optional boot_reference compares an existing store bundle byte for byte.' \
	  'System builds: configuration=/absolute/config.scm; GUIX selects its complete channel profile.' \
	  'Runtime: configuration=/absolute/config.scm checks a reviewed declaration with GUIX as selected.' \
	  'Configuration: optional channel_profile checks generated channel imports and replay.' \
	  'Locations: build_dir, catalogue, assembly, package_dir.' \
	  'Resources: optional jobs and cores; otherwise use the build tools defaults.' \
	  'VM: optional vm_memory in MiB for the full installation check.' \
	  'Installer inputs: runtime_archive, source_archive, runtime_sources (optional).' \
	  'Package inputs: version, base_url (HTTPS).' \
	  'Tools: GUIX, PYTHON. See docs/development.md for the complete flow.'

_plan-system:
	bash scripts/system/build.sh --plan "$(configuration)"

_build-system:
	bash scripts/system/build.sh "$(configuration)"

_plan-image:
	bash scripts/packaging/build-image.sh --dry-run "$(catalogue)"

_build-image:
	bash scripts/packaging/build-image.sh "$(catalogue)"

_build-installer:
	"$(PYTHON)" scripts/packaging/macos_bundle.py build-installer --catalogue "$(catalogue)" --output "$(assembly)" \
	  $(if $(runtime_archive),--runtime-archive "$(runtime_archive)") \
	  $(if $(source_archive),--source-archive "$(source_archive)") \
	  $(if $(runtime_sources),--runtime-sources "$(runtime_sources)") \
	  $(if $(cores),--cores "$(cores)")

_build-package:
	"$(PYTHON)" scripts/packaging/macos_bundle.py build-package --assembly "$(assembly)" \
	  --output "$(package_dir)" --version "$(version)" --base-url "$(base_url)"

_check-code:
	bash scripts/check-code.sh "$(only)" "$(source_archive)"

_check-image:
	"$(PYTHON)" scripts/packaging/macos_bundle.py check-image --catalogue "$(catalogue)"

_check-installer:
	"$(PYTHON)" scripts/packaging/macos_bundle.py check-installer --assembly "$(assembly)"
	bash "$(assembly)/installer/install.sh" check

_check-package:
	"$(PYTHON)" scripts/packaging/macos_bundle.py check-package --directory "$(package_dir)"
