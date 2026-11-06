# AGENTS.md

This file provides guidance to agents when working with code in this repository.

Single-file Emacs Lisp package: all code in `jenkins-mode.el`, tests in `test/jenkins-mode-test.el` (ERT). Architecture notes: `docs/development.md`.

## Commands (run from repo root; see docs/development.md)
- Byte-compile (must be warning-free; delete the `.elc` afterwards):
  `emacs -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile jenkins-mode.el && rm -f jenkins-mode.elc`
- Docstring lint: `emacs -Q --batch --eval '(checkdoc-file "jenkins-mode.el")'`
- All tests: `emacs -Q --batch -L . -l test/jenkins-mode-test.el -f ert-run-tests-batch-and-exit`
- Single test (ERT selector is a name/regexp): `emacs -Q --batch -L . -l test/jenkins-mode-test.el --eval '(ert-run-tests-batch-and-exit "jenkins-test-parse-ini")'`

## Conventions
- `lexical-binding: t`; private symbols use `jenkins--` prefix, public/interactive use `jenkins-`. Docstrings must pass checkdoc. Min Emacs 27.1; JSON uses native `json-parse-string`.
- Jobs are slash-separated path strings (`"folder/sub/job"`). ALWAYS build URLs via `jenkins--job-url` / `jenkins--job-path` (they URL-encode each component); never interpolate job names by hand. Use `jenkins--join-path` to combine with `jenkins--folder`.
- HTTP: `jenkins--http` returns raw body (signals error on >=400); `jenkins--request` returns parsed JSON (hash-tables, lists, nil for null/false) or the raw body if parsing fails. Requests are synchronous except `jenkins--request-async` (GET only, used by `jenkins--refresh-current` for timer/post-action refreshes). POST/PUT/DELETE auto-attach a cached CSRF crumb (`jenkins--crumb`), refreshed and retried once on 403. Use `jenkins--get` (not `gethash`) to read fields — it maps `:null`/`:json-false` to nil.
- Every API query must pass a minimal `tree=` parameter (history adds `{0,N}`).
- Jobs-list `tabulated-list` entry ids are `(NAME . FOLDER-P)` conses (NAME is relative to `jenkins--folder`); history ids are build numbers (job in `jenkins--history-job`). Both buffer-local vars.
- Commands acting on a job take `(interactive (list (jenkins--read-job "Prompt: ")))`, and call `jenkins--refresh-later` after state changes.
- One global refresh timer (`jenkins--refresh-timer`), started by the mode functions via `jenkins--ensure-timer`.
- Adding a feature: add a stubbed-HTTP test, bind key in `jenkins-mode-map`/`jenkins-build-history-mode-map`, update README key tables and `docs/usage.md`.

## Testing
- Tests stub `jenkins--request` / `jenkins--http` with `cl-letf`; no network or Jenkins needed. Wrap in `jenkins-test--with-config` for fixed URL/credentials. Test names: `jenkins-test-<name>`.
- `jenkins-reload` only reinitialises the top-level `*Jenkins*` buffer; other buffers keep old mode functions.
