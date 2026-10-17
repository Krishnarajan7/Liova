# Liova developer commands. Run `make help` for the list.

PROJECT       := Liova.xcodeproj
SCHEME        := Liova
CONFIG        ?= Debug
DERIVED       := build
APP           := $(DERIVED)/Build/Products/$(CONFIG)/Liova.app
PACKAGE_DIR   := Packages/LiovaKit
MRA_SRC       := Vendor/mediaremote-adapter
MRA_BUILD     := $(DERIVED)/vendor/mra
MRA_FRAMEWORK := $(MRA_BUILD)/MediaRemoteAdapter.framework
# Signs with the local "Liova Development" certificate when it exists (create it once with
# `make dev-cert`), so macOS keeps permissions such as Accessibility across rebuilds.
# Otherwise ad-hoc ("-"). Override with: make run SIGN_IDENTITY="..."
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"Liova Development"' && echo "Liova Development" || echo "-")

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
	-derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=$(shell uname -m)' \
	CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)"

.PHONY: help setup project vendor dev-cert build run cli test lint format format-check clean

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}'

setup: ## Check tools and generate the Xcode project
	@for tool in xcodebuild xcodegen swiftlint swiftformat cmake; do \
		command -v $$tool >/dev/null || { echo "Missing $$tool. Run: brew install xcodegen swiftlint swiftformat cmake"; exit 1; }; \
	done
	@$(MAKE) --no-print-directory project

project: vendor ## Regenerate Liova.xcodeproj from project.yml
	xcodegen generate --quiet

dev-cert: ## Create a local code-signing certificate so permissions survive rebuilds
	./scripts/create-dev-cert.sh

vendor: $(MRA_FRAMEWORK) ## Build vendored dependencies (Now Playing adapter)

$(MRA_FRAMEWORK): $(shell find $(MRA_SRC) -type f)
	cmake -S $(MRA_SRC) -B $(MRA_BUILD) -DCMAKE_BUILD_TYPE=Release -Wno-dev > /dev/null
	cmake --build $(MRA_BUILD) --config Release --target MediaRemoteAdapter > /dev/null
	@touch $@

build: project ## Build the app
	$(XCODEBUILD) build -quiet

run: build ## Build and launch the app (restarts a running copy)
	-@pkill -x Liova 2>/dev/null; true
	open "$(APP)"

cli: ## Build the `liova` command-line tool (release) into build/cli/liova
	swift build --package-path $(PACKAGE_DIR) --product liova -c release
	@mkdir -p $(DERIVED)/cli
	@cp "$$(swift build --package-path $(PACKAGE_DIR) -c release --show-bin-path)/liova" $(DERIVED)/cli/liova
	@echo "Built $(DERIVED)/cli/liova. Try: $(DERIVED)/cli/liova ping"

test: ## Run package unit tests
	swift test --package-path $(PACKAGE_DIR)

lint: ## Lint with SwiftLint (strict)
	swiftlint lint --strict --quiet

format: ## Format code in place with SwiftFormat
	swiftformat .

format-check: ## Fail if code isn't formatted
	swiftformat --lint .

clean: ## Remove build output and the generated project
	rm -rf $(DERIVED) $(PROJECT) $(PACKAGE_DIR)/.build
