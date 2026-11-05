.PHONY: all
all:
	$(MAKE) fmt
	ruff check --fix scripts/
	$(MAKE) test

.PHONY: fmt
fmt:
	nix fmt .

.PHONY: test
test:
	cd tests ; nix build . ; diff -r expected/ result/ 

.PHONY: generate-test-expected
generate-test-expected:
	cd tests ; nix build . ; rm -rf expected ; rsync -r result/ expected/ ; chmod -R go+rX expected
