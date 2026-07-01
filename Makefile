# Claude Usage Widget — common tasks. Run `make help` for the list.
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

.DEFAULT_GOAL := help

.PHONY: help check live install build clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

check: ## Run data-layer checks against fixtures (no Xcode needed)
	swift run DataLayerCheck

live: ## Show a live snapshot: Keychain → endpoint → parsed (no Xcode needed)
	swift run DataLayerCheck --live

install: ## Configure, build, install to /Applications, and launch (one command)
	./scripts/install.sh

build: ## Generate the project and build the app + widget
	./scripts/configure.sh
	xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage \
	  -configuration Debug -destination 'platform=macOS' -allowProvisioningUpdates build

clean: ## Remove build artifacts and the generated project
	rm -rf .build ClaudeUsage.xcodeproj
