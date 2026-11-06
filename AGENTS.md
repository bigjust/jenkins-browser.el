# AGENTS.md

This file provides guidance to agents when working with code in this repository.

Single-file Emacs Lisp package: all code in `jenkins-browser.el`, tests in `test/jenkins-browser-test.el` (ERT). Architecture notes: `docs/development.md`.

## Commands (run from repo root; see docs/development.md)
- Everything CI runs: `make check` (`compile`, `checkdoc`, `lint`, `test`). `make lint` installs package-lint into git-ignored `./.elpa`.
- Byte-compile (must be warning-free; delete the `.elc` afterwards):
  `emacs -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile jenkins-browser.el && rm -f jenkins-browser.elc`
- Docstring lint: `emacs -Q --batch --eval '(checkdoc-file "jenkins-browser.el")'`
- All tests: `emacs -Q --batch -L . -l test/jenkins-browser-test.el -f ert-run-tests-batch-and-exit`
- Single test (ERT selector is a name/regexp): `emacs -Q --batch -L . -l test/jenkins-browser-test.el --eval '(ert-run-tests-batch-and-exit "jenkins-browser-test-parse-ini")'`

## Conventions
- `lexical-binding: t`; private symbols use `jenkins-browser--` prefix, public/interactive use `jenkins-browser-`. Docstrings must pass checkdoc. Min Emacs 27.1; JSON uses native `json-parse-string`.
- Jobs are slash-separated path strings (`"folder/sub/job"`). ALWAYS build URLs via `jenkins-browser--job-url` / `jenkins-browser--job-path` (they URL-encode each component); never interpolate job names by hand. Use `jenkins-browser--join-path` to combine with `jenkins-browser--folder`.
- HTTP: `jenkins-browser--http` returns raw body (signals error on >=400); `jenkins-browser--request` returns parsed JSON (hash-tables, lists, nil for null/false) or the raw body if parsing fails. Requests are synchronous except `jenkins-browser--request-async` (GET only, used by `jenkins-browser--refresh-current` for timer/post-action refreshes). POST/PUT/DELETE auto-attach a cached CSRF crumb (`jenkins-browser--crumb`), refreshed and retried once on 403. Use `jenkins-browser--get` (not `gethash`) to read fields — it maps `:null`/`:json-false` to nil.
- Console uses `logText/progressiveText`: take the next offset from the `X-Text-Size` header (never the body length, annotations make it longer), keep bodies as bytes until `jenkins-browser--console-split` has cut at a newline. Follow state is buffer-local (`jenkins-browser--console-*`).
- Every API query must pass a minimal `tree=` parameter (history adds `{0,N}`).
- Jobs-list `tabulated-list` entry ids are `(NAME . FOLDER-P)` conses (NAME is relative to `jenkins-browser--folder`); history ids are build numbers (job in `jenkins-browser--history-job`). Both buffer-local vars.
- Commands acting on a job take `(interactive (list (jenkins-browser--read-job "Prompt: ")))`, and call `jenkins-browser--refresh-later` after state changes.
- One global refresh timer (`jenkins-browser--refresh-timer`), started by the mode functions via `jenkins-browser--ensure-timer`.
- Adding a feature: add a stubbed-HTTP test, bind key in `jenkins-browser-mode-map`/`jenkins-browser-build-history-mode-map`, update README key tables and `docs/usage.md`.

## Testing
- Tests stub `jenkins-browser--request` / `jenkins-browser--http` with `cl-letf`; no network or Jenkins needed. Wrap in `jenkins-browser-test--with-config` for fixed URL/credentials. Test names: `jenkins-browser-test-<name>`.
- `jenkins-browser-reload` only reinitialises the top-level `*Jenkins*` buffer; other buffers keep old mode functions.
