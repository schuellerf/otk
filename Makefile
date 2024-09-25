
check-pre-commit:
	@which pre-commit >/dev/null 2>&1 || { \
          echo >&2 -e "Please install https://pre-commit.com !\n"; \
	  echo >&2 "Either with 'pip install pre-commit'"; \
	  echo >&2 "or your package manager e.g. 'sudo dnf install pre-commit'"; \
	  exit 1; \
	}


SRC_CONTAINER_FILES=$(shell find src 2>/dev/null|| echo "src") \
                    Makefile \
                    pyproject.toml

# Detect the current architecture
CONTAINER_ARCH ?= $(shell uname -m)

# Define the platform mapping
ifeq ($(CONTAINER_ARCH), x86_64)
    PLATFORM_TYPE := amd64
else ifeq ($(CONTAINER_ARCH), aarch64)
    PLATFORM_TYPE := arm64
else ifeq ($(CONTAINER_ARCH), s390x)
    PLATFORM_TYPE := s390x
else ifeq ($(CONTAINER_ARCH), ppc64le)
    PLATFORM_TYPE := ppc64le
else
    PLATFORM_TYPE := $(CONTAINER_ARCH)
endif

PLATFORM := linux/$(PLATFORM_TYPE)

container_built.info: Containerfile $(SRC_CONTAINER_FILES) # internal rule to avoid rebuilding if not necessary
	podman build --platform "$(PLATFORM)" \
	             --build-arg CONTAINERS_STORAGE_THIN_TAGS="$(CONTAINERS_STORAGE_THIN_TAGS)" \
	             --build-arg IMAGES_REF="$(IMAGES_REF)" \
	             --tag otk_$(CONTAINER_ARCH) \
	             --pull=newer .
	echo "Container last built on" > $@
	date >> $@

.PHONY: container
container: container_built.info ## rebuild the upstream container "ghcr.io/osbuild/otk" locally

CONTAINER_TEST_FILE?=example/centos/centos-9-$(CONTAINER_ARCH)-tar.yaml

# just a sanity-check including hints for the user
# if the given filename does not exist.
# By default this filename is constructed by including the
# detected architecture, which then could lead to a broken `container-test`
$(CONTAINER_TEST_FILE): # internal rule for sanity check including hints for the user
ifeq (,$(findstring $(CONTAINER_ARCH),$(CONTAINER_TEST_FILE)))
	@echo "WARNING: $(CONTAINER_TEST_FILE) does not exist"
else
	@echo "WARNING: $(CONTAINER_TEST_FILE) does not exist so it seems"
	@echo "         $(CONTAINER_ARCH) is not supported by the project (yet)"
	@echo "         please use a supported architecture in CONTAINER_ARCH, implement the missing example"
	@echo "         or override CONTAINER_TEST_FILE with an existing file"
endif
	exit 1

.PHONY: container-test
container-test: $(CONTAINER_TEST_FILE) container ## run an example command in the container to test it
ifeq (,$(findstring $(PLATFORM),$(CONTAINER_TEST_FILE)))
	echo "WARNING: The CONTAINER_TEST_FILE ($(CONTAINER_TEST_FILE)) does not contain the PLATFORM_TYPE $(PLATFORM_TYPE)"
	echo "This is just a naming convention to warn for possible incompatibilities"
endif
	podman run --platform="$(PLATFORM)" --rm -ti -v .:/app localhost/otk_$(CONTAINER_ARCH):latest compile /app/$(CONTAINER_TEST_FILE)

.PHONY: lint
lint: check-pre-commit
	pre-commit run --all-files

.PHONY: type
type: check-pre-commit
	pre-commit run --all-files mypy

.PHONY: format
format:
	@find src test -name '*.py' | xargs autopep8 --in-place

.PHONY: test
test: external
	cp $(shell (which "osbuild-gen-depsolve-dnf4")) ./external/
	cp $(shell (which "osbuild-make-depsolve-dnf4-rpm-stage")) ./external/
	cp $(shell (which "osbuild-make-depsolve-dnf4-curl-source")) ./external/
	@pytest

.PHONY: push-check
push-check: test lint type

.PHONY: git-diff-check
git-diff-check:
	@git diff --exit-code
	@git diff --cached --exit-code

## Package building
SRCDIR ?= $(abspath .)
COMMIT = $(shell (cd "$(SRCDIR)" && git rev-parse HEAD 2>/dev/null || echo "INVALID" ))
RPM_SPECFILE=rpmbuild/SPECS/otk-$(COMMIT).spec
RPM_TARBALL=rpmbuild/SOURCES/otk-$(COMMIT).tar.gz

$(RPM_SPECFILE):
	mkdir -p $(CURDIR)/rpmbuild/SPECS
	(echo "%global commit $(COMMIT)"; git show HEAD:otk.spec 2>/dev/null || echo "INVALID SETUP" ) > $(RPM_SPECFILE)

$(RPM_TARBALL):
	mkdir -p $(CURDIR)/rpmbuild/SOURCES
	git archive --prefix=otk-$(COMMIT)/ --format=tar.gz HEAD > $(RPM_TARBALL)

.PHONY: srpm
srpm: git-diff-check $(RPM_SPECFILE) $(RPM_TARBALL)
	rpmbuild -bs \
		--define "_topdir $(CURDIR)/rpmbuild" \
		$(RPM_SPECFILE)

.PHONY: rpm
rpm: git-diff-check $(RPM_SPECFILE) $(RPM_TARBALL)
	rpmbuild -bb \
		--define "_topdir $(CURDIR)/rpmbuild" \
		$(RPM_SPECFILE)

# Note that "external" will most likely in the future build from internal
# sources instead of pulling of the network
.PHONY: external
# # Keep this in sync with e.g. https://github.com/containers/podman/blob/2981262215f563461d449b9841741339f4d9a894/Makefile#L51
CONTAINERS_STORAGE_THIN_TAGS=containers_image_openpgp exclude_graphdriver_btrfs exclude_graphdriver_devicemapper
IMAGES_REF ?= github.com/osbuild/images
external:
	mkdir -p "$(SRCDIR)/external"
	set -e ; \
	for otk_cmd in gen-partition-table \
			make-fstab-stage \
			make-grub2-inst-stage \
			resolve-containers \
			resolve-ostree-commit \
			make-partition-mounts-devices \
			make-partition-stages; do \
		GOBIN="$(SRCDIR)/external" go install -tags "$(CONTAINERS_STORAGE_THIN_TAGS)" "$(IMAGES_REF)"/cmd/otk-$${otk_cmd}@main ; \
	done
