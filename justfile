alias h := help
alias c := check
alias f := fmt
alias l := lint
alias t := test
alias p := prepare

help:
    @just --list

lint: lint-fmt lint-clippy machete

lint-clippy:
    @echo "Running clippy..."
    cargo clippy --no-deps --all-targets --workspace -- -D warnings

lint-fmt:
    @echo "Checking code format..."
    cargo fmt --all -- --check

machete:
    @echo "Running machete..."
    cargo machete

fmt:
    @echo "Formatting code..."
    cargo fmt --all

check:
    @echo "Running cargo check..."
    cargo check --all-targets --workspace

test:
    @echo "Running cargo test"
    CARGO_WORKSPACE_PATH="{{justfile_directory()}}" cargo t

prepare: check lint test

clean:
    @echo "Running cargo clean"
    cargo clean
