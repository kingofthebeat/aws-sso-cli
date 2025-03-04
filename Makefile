PROJECT_VERSION := 1.7.1
DOCKER_REPO     := synfinatic
PROJECT_NAME    := aws-sso

DIST_DIR ?= dist/
GOOS ?= $(shell uname -s | tr "[:upper:]" "[:lower:]")
ARCH ?= $(shell uname -m)
ifeq ($(ARCH),x86_64)
GOARCH             := amd64
else
GOARCH             := $(ARCH)  # no idea if this works for other platforms....
endif

ifneq ($(BREW_INSTALL),1)
PROJECT_TAG               := $(shell git describe --tags 2>/dev/null $(git rev-list --tags --max-count=1))
PROJECT_COMMIT            := $(shell git rev-parse HEAD || echo "")
PROJECT_DELTA             := $(shell DELTA_LINES=$$(git diff | wc -l); if [ $${DELTA_LINES} -ne 0 ]; then echo $${DELTA_LINES} ; else echo "''" ; fi)
else
PROJECT_TAG               := Homebrew

endif

BUILDINFOSDET ?=
PROGRAM_ARGS ?=
ifeq ($(PROJECT_TAG),)
PROJECT_TAG               := NO-TAG
endif
ifeq ($(PROJECT_COMMIT),)
PROJECT_COMMIT            := NO-CommitID
endif
ifeq ($(PROJECT_DELTA),)
PROJECT_DELTA             :=
endif
VERSION_PKG               := $(shell echo $(PROJECT_VERSION) | sed 's/^v//g')
LICENSE                   := GPLv3
URL                       := https://github.com/$(DOCKER_REPO)/$(PROJECT_NAME)
DESCRIPTION               := AWS SSO CLI
BUILDINFOS                := $(shell date +%FT%T%z)$(BUILDINFOSDET)
HOSTNAME                  := $(shell hostname)
LDFLAGS                   := -X "main.Version=$(PROJECT_VERSION)" -X "main.Delta=$(PROJECT_DELTA)" -X "main.Buildinfos=$(BUILDINFOS)" -X "main.Tag=$(PROJECT_TAG)" -X "main.CommitID=$(PROJECT_COMMIT)"
OUTPUT_NAME               := $(DIST_DIR)$(PROJECT_NAME)-$(PROJECT_VERSION)  # default for current platform

# supported platforms for `make release`
WINDOWS_BIN               := $(DIST_DIR)$(PROJECT_NAME)-$(PROJECT_VERSION)-windows-amd64.exe
WINDOWS32_BIN             := $(DIST_DIR)$(PROJECT_NAME)-$(PROJECT_VERSION)-windows-386.exe
LINUX_BIN                 := $(DIST_DIR)$(PROJECT_NAME)-$(PROJECT_VERSION)-linux-amd64
LINUXARM64_BIN            := $(DIST_DIR)$(PROJECT_NAME)-$(PROJECT_VERSION)-linux-arm64
DARWIN_BIN                := $(DIST_DIR)$(PROJECT_NAME)-$(PROJECT_VERSION)-darwin-amd64
DARWINARM64_BIN           := $(DIST_DIR)$(PROJECT_NAME)-$(PROJECT_VERSION)-darwin-arm64

ALL: $(DIST_DIR)$(PROJECT_NAME) ## Build binary for this platform

include help.mk  # place after ALL target and before all other targets

$(DIST_DIR)$(PROJECT_NAME):	$(wildcard */*.go) .prepare
	go build -ldflags='$(LDFLAGS)' -o $(DIST_DIR)$(PROJECT_NAME) cmd/*.go
	@echo "Created: $(DIST_DIR)$(PROJECT_NAME)"

INSTALL_PREFIX ?= /usr/local

install: $(DIST_DIR)$(PROJECT_NAME)  ## install binary in $INSTALL_PREFIX
	install -d $(INSTALL_PREFIX)/bin
	install -c $(DIST_DIR)$(PROJECT_NAME) $(INSTALL_PREFIX)/bin

uninstall:  ## Uninstall binary from $INSTALL_PREFIX
	rm /usr/local/bin/$(PROJECT_NAME)


HOMEBREW := ./homebrew/Formula/aws-sso-cli.rb

homebrew: $(HOMEBREW)  ## Build homebrew tap file

#DOWNLOAD_URL := https://synfin.net/misc/aws-sso-cli.$(PROJECT_VERSION).tar.gz
DOWNLOAD_URL ?= https://github.com/synfinatic/aws-sso-cli/archive/refs/tags/v$(PROJECT_VERSION).tar.gz

.PHONY: $(HOMEBREW)
$(HOMEBREW):  homebrew/template.rb  ## no-help
	TEMPFILE=$$(mktemp) && wget -q -O $${TEMPFILE} $(DOWNLOAD_URL) ; \
	if test -s $${TEMPFILE}; then \
		export SHA=$$(cat $${TEMPFILE} | sha256sum | sed -e 's|  -||') && rm $${TEMPFILE} && \
		m4 -D __SHA256__=$${SHA} \
		   -D __VERSION__=$(PROJECT_VERSION) \
		   -D __COMMIT__=$(PROJECT_COMMIT) \
		   -D __URL__=$(DOWNLOAD_URL) \
		   homebrew/template.rb | tee $(HOMEBREW) && \
		   echo "***** Please review above and test! ******" && \
		   echo "File written to: $(HOMEBREW)  Please commit in git submodule!" ; \
	else \
		echo "*** Error downloading $(DOWNLOAD_URL) ***" ; \
	fi

.PHONY: package
package: linux linux-arm64  ## Build deb/rpm packages
	docker build -t aws-sso-cli-builder:latest .
	docker run --rm \
		-v $$(pwd)/dist:/root/dist \
		-e VERSION=$(PROJECT_VERSION) aws-sso-cli-builder:latest

tags: cmd/*.go sso/*.go  ## Create tags file for vim, etc
	@echo Make sure you have Universal Ctags installed: https://github.com/universal-ctags/ctags
	ctags -R

.build-release: windows windows32 linux linux-arm64 darwin darwin-arm64

.validate-release: ALL
	@TAG=$$(./$(DIST_DIR)$(PROJECT_NAME) version 2>/dev/null | grep '(v$(PROJECT_VERSION))'); \
		if test -z "$$TAG"; then \
		echo "Build tag from does not match PROJECT_VERSION=v$(PROJECT_VERSION) in Makefile:" ; \
		./$(DIST_DIR)$(PROJECT_NAME) version 2>/dev/null | grep built ; \
		exit 1 ; \
	fi

release: .validate-release clean .build-release package ## Build all our release binaries
	cd dist && shasum -a 256 * | gpg --clear-sign >release.sig.asc

.PHONY: run
run: cmd/*.go  sso/*.go ## build and run using $PROGRAM_ARGS
	go run cmd/*.go $(PROGRAM_ARGS)

.PHONY: delve
delve: cmd/*.go sso/*.go ## debug binary using $PROGRAM_ARGS
	dlv debug cmd/*.go -- $(PROGRAM_ARGS)

clean-all: clean ## clean _everything_

clean: ## Remove all binaries in dist
	rm -rf dist/*

clean-go: ## Clean Go cache
	go clean -i -r -cache -modcache

go-get:  ## Get our go modules
	go get -v all

.prepare: $(DIST_DIR)

.PHONY: build-race
build-race: .prepare ## Build race detection binary
	go build -race -ldflags='$(LDFLAGS)' -o $(OUTPUT_NAME) cmd/*.go

debug: .prepare ## Run debug in dlv
	dlv debug cmd/*.go

.PHONY: unittest
unittest: ## Run go unit tests
	go test -race -covermode=atomic -coverprofile=coverage.out  ./...

.PHONY: test-race
test-race: ## Run `go test -race` on the code
	@echo checking code for races...
	go test -race ./...

.PHONY: vet
vet: ## Run `go vet` on the code
	@echo checking code is vetted...
	for x in $(shell go list ./...); do echo $$x ; go vet $$x ; done

test: vet unittest lint ## Run important tests

precheck: test test-fmt test-tidy ## Run all tests that happen in a PR

# run everything but `lint` because that runs via it's own workflow
.build-tests: vet unittest test-tidy test-fmt

$(DIST_DIR):
	@if test ! -d $(DIST_DIR); then mkdir -p $(DIST_DIR) ; fi

.PHONY: fmt
fmt: ## Format Go code
	@go fmt cmd

.PHONY: test-fmt
test-fmt: fmt ## Test to make sure code if formatted correctly
	@if test `git diff cmd | wc -l` -gt 0; then \
	    echo "Code changes detected when running 'go fmt':" ; \
	    git diff -Xfiles ; \
	    exit -1 ; \
	fi

.PHONY: test-tidy
test-tidy:  ## Test to make sure go.mod is tidy
	@go mod tidy
	@if test `git diff go.mod | wc -l` -gt 0; then \
	    echo "Need to run 'go mod tidy' to clean up go.mod" ; \
	    exit -1 ; \
	fi

lint:  ## Run golangci-lint
	golangci-lint run

# Build targets for our supported plaforms
windows: $(WINDOWS_BIN)  ## Build 64bit x86 Windows binary

$(WINDOWS_BIN): $(wildcard */*.go) .prepare
	GOARCH=amd64 GOOS=windows go build -ldflags='$(LDFLAGS)' -o $(WINDOWS_BIN) cmd/*.go
	@echo "Created: $(WINDOWS_BIN)"

windows32: $(WINDOWS32_BIN)  ## Build 32bit x86 Windows binary

$(WINDOWS32_BIN): $(wildcard */*.go) .prepare
	GOARCH=386 GOOS=windows go build -ldflags='$(LDFLAGS)' -o $(WINDOWS32_BIN) cmd/*.go
	@echo "Created: $(WINDOWS32_BIN)"

linux: $(LINUX_BIN)  ## Build Linux/x86_64 binary

$(LINUX_BIN): $(wildcard */*.go) .prepare
	GOARCH=amd64 GOOS=linux go build -ldflags='$(LDFLAGS)' -o $(LINUX_BIN) cmd/*.go
	@echo "Created: $(LINUX_BIN)"

linux-arm64: $(LINUXARM64_BIN)  ## Build Linux/arm64 binary

$(LINUXARM64_BIN): $(wildcard */*.go) .prepare
	GOARCH=arm64 GOOS=linux go build -ldflags='$(LDFLAGS)' -o $(LINUXARM64_BIN) cmd/*.go
	@echo "Created: $(LINUXARM64_BIN)"

darwin: $(DARWIN_BIN)  ## Build MacOS/x86_64 binary

$(DARWIN_BIN): $(wildcard */*.go) .prepare
	GOARCH=amd64 GOOS=darwin go build -ldflags='$(LDFLAGS)' -o $(DARWIN_BIN) cmd/*.go
	@echo "Created: $(DARWIN_BIN)"

darwin-arm64: $(DARWINARM64_BIN)  ## Build MacOS/ARM64 binary

$(DARWINARM64_BIN): $(wildcard */*.go) .prepare
	GOARCH=arm64 GOOS=darwin go build -ldflags='$(LDFLAGS)' -o $(DARWINARM64_BIN) cmd/*.go
	@echo "Created: $(DARWINARM64_BIN)"

$(OUTPUT_NAME): $(wildcard */*.go) .prepare
	go build -ldflags='$(LDFLAGS)' -o $(OUTPUT_NAME) cmd/*.go

docs: docs/default-region.png  ## Build document files

docs/default-region.png:
	dot -o docs/default-region.png -Tpng docs/default-region.dot

