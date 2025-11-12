CARGO ?= cargo
RUNNER := $(CARGO) run --quiet --bin starry-test-harness --
SUPPORTED_SUITES := ci-test stress-test daily-test

SUITE := $(firstword $(MAKECMDGOALS))
ACTION := $(word 2,$(MAKECMDGOALS))
ifeq ($(ACTION),)
ACTION := run
endif

.DEFAULT_GOAL := help

.PHONY: $(SUPPORTED_SUITES) run help build

$(SUPPORTED_SUITES):
	@$(RUNNER) $(SUITE) $(ACTION)

run:
	@# helper targets so `make ci-test run` works as expected

build:
	@$(CARGO) build

help:
	@echo "Available targets:"
	@echo "  make ci-test run        # build + run CI smoke tests"
	@echo "  make stress-test run    # build + run stress tests"
	@echo "  make daily-test run     # run long stability tests"
	@echo "  make build              # compile the Rust harness"
