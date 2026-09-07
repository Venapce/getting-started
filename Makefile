# Venapce — build and publish the appliance images.
#
# Two images, one permanent and one fast-moving:
#
#   mehdishokohi/venapce-base   postgres + superset + nginx + supervisord.
#                               The heavy, slow-changing foundation. Rebuilt only
#                               when Superset, its drivers, or the base plumbing
#                               changes — versioned on its OWN cadence (BASE_VERSION).
#
#   mehdishokohi/venapce        FROM venapce-base, adds the venapce-api Go binary
#                               and the compiled venapce-wapp panel. This is what
#                               install.sh pulls and what ships on every product
#                               release (VERSION).
#
# Splitting them means a product release doesn't recompile Superset or reinstall
# apt packages — `make build` layers the Go binary + static panel onto an existing
# base in seconds.
#
# Typical flow:
#   make base-build                 # build venapce-base:local (host arch)
#   make build                      # build venapce:local FROM venapce-base:local
#   make run                        # try it on PORT, standalone
#
#   make login
#   make base-release               # publish venapce-base:$(BASE_VERSION) + :latest (multi-arch)
#   make release                    # publish venapce:$(VERSION) + :latest (multi-arch)
#
# arm64 on an amd64 host is emulated (QEMU) — see `make binfmt` / `make builder`.

# ── versions ──────────────────────────────────────────────────────────────────
# The product image version. Bump per release.
VERSION      ?= v0.1.0
# The base image version. Bump only when the base actually changes.
BASE_VERSION ?= v1

IMAGE_NAME      := mehdishokohi/venapce
BASE_IMAGE_NAME := mehdishokohi/venapce-base

# The Superset release the base is built on.
SUPERSET_TAG ?= 4.1.1

# The base tag the PRODUCT image layers on. Defaults to the pinned base version;
# `make build` overrides it to the local base tag.
BASE_IMAGE ?= $(BASE_IMAGE_NAME):$(BASE_VERSION)

# Local (never-pushed) tags for build/run.
BASE_LOCAL  ?= venapce-base:local
LOCAL_IMAGE ?= venapce:local

# Host port for `make run` (the panel).
PORT ?= 8080

# Go module proxy, passed as a build arg to the API stage. Defaults to the
# goproxy.cn mirror because proxy.golang.org redirects module zips to
# storage.googleapis.com and networks that block it answer 403 mid-download.
# Pass IMAGE_GOPROXY= to ship the upstream default instead. Deliberately NOT
# called GOPROXY, so a shell that exports GOPROXY can't silently override it.
IMAGE_GOPROXY ?= https://goproxy.cn,direct

# Force a clean rebuild with NO_CACHE=--no-cache.
NO_CACHE ?=
# buildx builder for the MULTI-ARCH push targets (needs the docker-container
# driver). Empty = whatever `docker buildx` currently defaults to.
BUILDER ?=
# buildx builder for the LOCAL --load builds. Must be the `docker` driver so a
# product build can read the base image straight from the local image store
# (a docker-container builder can't see local-only images and tries to pull them).
LOCAL_BUILDER ?= default

# Contexts + Dockerfiles.
#  base:    context is docker/ (Dockerfile.base COPYs base/*)
#  product: context is the VenapceProject root (the parent of this repo) so the
#           sibling venapce-api / venapce-wapp checkouts can be COPYed
BASE_DOCKERFILE    := docker/Dockerfile.base
PRODUCT_DOCKERFILE := docker/Dockerfile.venapce
PRODUCT_CONTEXT    := ..

BUILDX       := docker buildx build $(if $(BUILDER),--builder $(BUILDER),)
BUILDX_LOCAL := docker buildx build --builder $(LOCAL_BUILDER)

BASE_ARGS    := --build-arg SUPERSET_TAG=$(SUPERSET_TAG)
PRODUCT_ARGS := --build-arg BASE_IMAGE=$(BASE_IMAGE) \
	$(if $(IMAGE_GOPROXY),--build-arg GOPROXY=$(IMAGE_GOPROXY),)

.DEFAULT_GOAL := help

.PHONY: help version check-version check-base-version check-arm64 login builder binfmt \
	base-build base-docker-amd64 base-docker-arm64 base-docker \
	base-push-amd64 base-push-arm64 base-push base-release \
	build run stop \
	docker-amd64 docker-arm64 docker \
	docker-push-amd64 docker-push-arm64 docker-push release \
	inspect clean

help: ## Show this help
	@printf 'Venapce image targets\n  product: %s\n  base:    %s\n\n' "$(IMAGE_NAME)" "$(BASE_IMAGE_NAME)"
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@printf '\nproduct VERSION=%s   base BASE_VERSION=%s   superset=%s\n' \
	  "$(VERSION)" "$(BASE_VERSION)" "$(SUPERSET_TAG)"

version: ## Print the versions and the tags a release would push
	@printf 'VERSION         %s -> %s:%s , %s:latest\n' "$(VERSION)" "$(IMAGE_NAME)" "$(VERSION)" "$(IMAGE_NAME)"
	@printf 'BASE_VERSION    %s -> %s:%s , %s:latest\n' "$(BASE_VERSION)" "$(BASE_IMAGE_NAME)" "$(BASE_VERSION)" "$(BASE_IMAGE_NAME)"
	@printf 'BASE_IMAGE      %s (what the product layers on)\n' "$(BASE_IMAGE)"
	@printf 'SUPERSET_TAG    %s\n' "$(SUPERSET_TAG)"

check-version:
	@test -n "$(VERSION)" || { printf 'VERSION is empty — set it or pass VERSION=v0.1.0\n'; exit 1; }
check-base-version:
	@test -n "$(BASE_VERSION)" || { printf 'BASE_VERSION is empty — set it or pass BASE_VERSION=v1\n'; exit 1; }

# arm64 on an amd64 host is emulated, and the emulators aren't registered by
# default — without them buildx fails with "exec format error" minutes in.
check-arm64:
	@docker buildx inspect $(BUILDER) 2>/dev/null | grep -q 'linux/arm64' || { \
	  printf 'this builder cannot produce linux/arm64.\n'; \
	  printf '  make binfmt    register the QEMU emulators\n'; \
	  printf '  make builder   create a docker-container builder that can use them\n'; \
	  exit 1; }

login: ## docker login (needed once before any push target)
	docker login

builder: ## Create/select a docker-container builder that can do multi-arch
	docker buildx inspect venapce >/dev/null 2>&1 \
	  || docker buildx create --name venapce --driver docker-container --bootstrap
	docker buildx use venapce

binfmt: ## Register QEMU emulators so this host can build arm64
	docker run --privileged --rm tonistiigi/binfmt --install arm64,amd64

# ── base image (the permanent foundation) ─────────────────────────────────────

base-build: ## Build the base for this host, as BASE_LOCAL
	$(BUILDX_LOCAL) $(NO_CACHE) $(BASE_ARGS) -f $(BASE_DOCKERFILE) -t $(BASE_LOCAL) --load docker

base-docker-amd64: check-base-version
	$(BUILDX) $(NO_CACHE) $(BASE_ARGS) --platform linux/amd64 -f $(BASE_DOCKERFILE) \
		-t $(BASE_IMAGE_NAME):$(BASE_VERSION)-amd64 --load docker
base-docker-arm64: check-base-version check-arm64
	$(BUILDX) $(NO_CACHE) $(BASE_ARGS) --platform linux/arm64 -f $(BASE_DOCKERFILE) \
		-t $(BASE_IMAGE_NAME):$(BASE_VERSION)-arm64 --load docker
base-docker: base-docker-amd64 base-docker-arm64 ## Build both base arches locally, push nothing

base-push-amd64: check-base-version
	$(BUILDX) $(NO_CACHE) $(BASE_ARGS) --platform linux/amd64 -f $(BASE_DOCKERFILE) \
		-t $(BASE_IMAGE_NAME):$(BASE_VERSION)-amd64 --push docker
base-push-arm64: check-base-version check-arm64
	$(BUILDX) $(NO_CACHE) $(BASE_ARGS) --platform linux/arm64 -f $(BASE_DOCKERFILE) \
		-t $(BASE_IMAGE_NAME):$(BASE_VERSION)-arm64 --push docker
base-push: base-push-amd64 base-push-arm64 ## Push both per-arch base tags

base-release: base-push ## Publish base BASE_VERSION + latest (multi-arch manifest)
	docker buildx imagetools create \
		-t $(BASE_IMAGE_NAME):latest \
		-t $(BASE_IMAGE_NAME):$(BASE_VERSION) \
		$(BASE_IMAGE_NAME):$(BASE_VERSION)-amd64 \
		$(BASE_IMAGE_NAME):$(BASE_VERSION)-arm64
	@printf '\npublished %s:%s and %s:latest\n' "$(BASE_IMAGE_NAME)" "$(BASE_VERSION)" "$(BASE_IMAGE_NAME)"

# ── product image (FROM the base) ─────────────────────────────────────────────

build: ## Build the product for this host FROM the LOCAL base, as LOCAL_IMAGE
	$(BUILDX_LOCAL) $(NO_CACHE) --build-arg BASE_IMAGE=$(BASE_LOCAL) \
		$(if $(IMAGE_GOPROXY),--build-arg GOPROXY=$(IMAGE_GOPROXY),) \
		-f $(PRODUCT_DOCKERFILE) -t $(LOCAL_IMAGE) --load $(PRODUCT_CONTEXT)

run: ## Run the local product image on PORT, standalone (no FloMorphic wired in)
	@printf 'starting %s — panel http://localhost:%s , superset http://localhost:8090\n' "$(LOCAL_IMAGE)" "$(PORT)"
	@printf 'first boot migrates Superset + creates the admin, so give it ~60-120s.\n'
	docker run --rm -d --name venapce-local \
		-e SUPERSET_SECRET_KEY=local-insecure-key \
		-e VENAPCE_APP_SECRET=local-insecure-secret \
		-p $(PORT):80 -p 8090:8088 $(LOCAL_IMAGE)
	@printf 'follow it with: docker logs -f venapce-local\n'

stop: ## Stop the container `run` started
	-docker rm -f venapce-local

docker-amd64: check-version
	$(BUILDX) $(NO_CACHE) $(PRODUCT_ARGS) --platform linux/amd64 -f $(PRODUCT_DOCKERFILE) \
		-t $(IMAGE_NAME):$(VERSION)-amd64 --load $(PRODUCT_CONTEXT)
docker-arm64: check-version check-arm64
	$(BUILDX) $(NO_CACHE) $(PRODUCT_ARGS) --platform linux/arm64 -f $(PRODUCT_DOCKERFILE) \
		-t $(IMAGE_NAME):$(VERSION)-arm64 --load $(PRODUCT_CONTEXT)
docker: docker-amd64 docker-arm64 ## Build both product arches locally, push nothing

docker-push-amd64: check-version
	$(BUILDX) $(NO_CACHE) $(PRODUCT_ARGS) --platform linux/amd64 -f $(PRODUCT_DOCKERFILE) \
		-t $(IMAGE_NAME):$(VERSION)-amd64 --push $(PRODUCT_CONTEXT)
docker-push-arm64: check-version check-arm64
	$(BUILDX) $(NO_CACHE) $(PRODUCT_ARGS) --platform linux/arm64 -f $(PRODUCT_DOCKERFILE) \
		-t $(IMAGE_NAME):$(VERSION)-arm64 --push $(PRODUCT_CONTEXT)
docker-push: docker-push-amd64 docker-push-arm64 ## Push both per-arch product tags

release: docker-push ## Publish product VERSION + latest (multi-arch manifest)
	docker buildx imagetools create \
		-t $(IMAGE_NAME):latest \
		-t $(IMAGE_NAME):$(VERSION) \
		$(IMAGE_NAME):$(VERSION)-amd64 \
		$(IMAGE_NAME):$(VERSION)-arm64
	@printf '\npublished %s:%s and %s:latest\n' "$(IMAGE_NAME)" "$(VERSION)" "$(IMAGE_NAME)"
	@$(MAKE) --no-print-directory inspect

inspect: check-version ## Show what is published for the product version
	-docker buildx imagetools inspect $(IMAGE_NAME):$(VERSION)
	-docker buildx imagetools inspect $(IMAGE_NAME):latest

clean: ## Drop the local per-arch and :local tags
	-docker rmi $(LOCAL_IMAGE) $(BASE_LOCAL) 2>/dev/null
	-docker rmi $(IMAGE_NAME):$(VERSION)-amd64 $(IMAGE_NAME):$(VERSION)-arm64 2>/dev/null
	-docker rmi $(BASE_IMAGE_NAME):$(BASE_VERSION)-amd64 $(BASE_IMAGE_NAME):$(BASE_VERSION)-arm64 2>/dev/null
