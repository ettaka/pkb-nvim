# Not NVIM: inside a Neovim :terminal $NVIM is the parent server socket.
NVIM_BIN ?= nvim

# make test [FILTER=substring]   run the headless test suite (see tests/run.lua)
test: deps
	$(NVIM_BIN) --clean -l tests/run.lua $(FILTER)

# timestamps-nvim is found as ../timestamps-nvim, $TIMESTAMPS_NVIM_DIR, or cloned into .deps/
deps:
	@if [ ! -d ../timestamps-nvim ] && [ -z "$$TIMESTAMPS_NVIM_DIR" ] && [ ! -d .deps/timestamps-nvim ]; then \
		git clone --depth 1 https://github.com/ettaka/timestamps-nvim .deps/timestamps-nvim; \
	fi

.PHONY: test deps
