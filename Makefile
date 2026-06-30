# agterm tasks — a thin front door over scripts/*.sh (the scripts stay the source of truth).
# Run `make` (or `make help`) to list targets.

INSTALL_DIR := $(HOME)/Applications
RELEASE_APP := build/DerivedData/Build/Products/Release/agterm.app

.DEFAULT_GOAL := help
.PHONY: help prep generate build run release deploy test lint dist clean

help: ## list targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-9s\033[0m %s\n", $$1, $$2}'

prep: ## build libghostty + ghostty resources (one-time, idempotent)
	./scripts/setup.sh

generate: prep ## regenerate agterm.xcodeproj from project.yml
	xcodegen generate

build: generate ## debug build, no launch
	xcodebuild -project agterm.xcodeproj -scheme agterm -configuration Debug \
	  -derivedDataPath build/DerivedData build

run: ## debug build + launch (scripts/run.sh)
	./scripts/run.sh

release: ## release build, no launch (scripts/build.sh)
	./scripts/build.sh

deploy: release ## release build + copy to ~/Applications
	rm -rf "$(INSTALL_DIR)/agterm.app"
	cp -R "$(RELEASE_APP)" "$(INSTALL_DIR)/agterm.app"
	@echo "installed $(INSTALL_DIR)/agterm.app"

test: ## host-free agtermCore unit tests (scripts/test.sh)
	./scripts/test.sh

lint: ## swiftlint over the tree (strict — warnings fail too)
	swiftlint lint --strict --quiet

dist: ## signed + notarized DMG — usage: make dist VERSION=x.y.z [PUBLISH=1]
	@test -n "$(VERSION)" || { echo "usage: make dist VERSION=x.y.z [PUBLISH=1]" >&2; exit 1; }
	./scripts/release.sh $(VERSION) $(if $(PUBLISH),--publish,)

clean: ## remove build artifacts (build/)
	rm -rf build
