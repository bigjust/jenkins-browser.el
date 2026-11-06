EMACS ?= emacs
BATCH  = $(EMACS) -Q --batch -L .
ELPA   = .elpa

.PHONY: all check compile checkdoc lint test clean

all: check

check: compile checkdoc lint test

# Byte-compile with warnings as errors.
compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile jenkins-mode.el
	rm -f jenkins-mode.elc

# checkdoc always exits 0, so fail if it prints anything.
checkdoc:
	@out=$$($(BATCH) --eval '(checkdoc-file "jenkins-mode.el")' 2>&1); \
	  if [ -n "$$out" ]; then echo "$$out"; exit 1; fi

# package-lint is installed into ./.elpa (git-ignored), not into your Emacs.
lint: $(ELPA)/.package-lint
	$(BATCH) --eval '(progn (require (quote package)) (setq package-user-dir (expand-file-name "$(ELPA)")) (package-initialize) (require (quote package-lint)) (setq package-lint-main-file "jenkins-mode.el"))' \
	  -f package-lint-batch-and-exit jenkins-mode.el

$(ELPA)/.package-lint:
	$(BATCH) --eval '(progn (require (quote package)) (setq package-user-dir (expand-file-name "$(ELPA)") package-archives (quote (("melpa" . "https://melpa.org/packages/") ("gnu" . "https://elpa.gnu.org/packages/")))) (package-initialize) (package-refresh-contents) (package-install (quote package-lint)))'
	touch $@

test:
	$(BATCH) -l test/jenkins-mode-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -rf $(ELPA) jenkins-mode.elc
