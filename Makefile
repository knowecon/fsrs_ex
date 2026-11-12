.PHONY: help deps format format-check test fixture docs hex-build hex-dry-run preflight publish publish-interactive release

help:
	@printf "Available targets:\n"
	@printf "  deps                - Fetch dependencies\n"
	@printf "  format              - Format source code\n"
	@printf "  format-check        - Check formatting without changing files\n"
	@printf "  test                - Run test suite\n"
	@printf "  fixture             - Regenerate the fsrs-rs parity fixture (needs cargo)\n"
	@printf "  docs                - Build HexDocs locally\n"
	@printf "  hex-build           - Build Hex package tarball\n"
	@printf "  hex-dry-run         - Validate publish flow without uploading\n"
	@printf "  preflight           - Run all release checks\n"
	@printf "  publish             - Publish non-interactively (requires HEX_API_KEY)\n"
	@printf "  publish-interactive - Publish using local interactive credentials\n"
	@printf "  release             - preflight + publish\n"

deps:
	mix deps.get

format:
	mix format

format-check:
	mix format --check-formatted

test:
	mix test

FIXTURE := test/fixtures/fsrs_rs_v7_0_0_fixture.json

fixture:
	cd test/fixtures/rust_fixture && cargo run --release --locked -- ../../../$(FIXTURE)
	gzip -9nf $(FIXTURE)

docs:
	mix docs

hex-build:
	mix hex.build

hex-dry-run:
	@if [ -z "$$HEX_API_KEY" ]; then \
		printf "Skipping hex dry-run: HEX_API_KEY is not set (interactive key cannot be used non-interactively).\n"; \
	else \
		mix hex.publish --dry-run --yes; \
	fi

preflight: deps format-check test docs hex-build hex-dry-run

publish:
	@if [ -z "$$HEX_API_KEY" ]; then \
		printf "HEX_API_KEY is required for non-interactive publish.\n"; \
		printf "Run 'mix hex.user key generate --key-name fsrs_ex_release' and export HEX_API_KEY.\n"; \
		exit 1; \
	fi
	mix hex.publish --yes

publish-interactive:
	mix hex.publish --yes

release: preflight publish
