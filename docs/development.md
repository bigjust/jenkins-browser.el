# Architecture and development

Everything lives in [`jenkins-browser.el`](../jenkins-browser.el). Tests are in
[`test/jenkins-browser-test.el`](../test/jenkins-browser-test.el).

## Code layout

The file is organised in sections, top to bottom:

| Section | Contents |
| --- | --- |
| Configuration & Credentials | `jenkins-browser--parse-ini-file`, `jenkins-browser--get-config`, `jenkins-browser--auth-source-lookup`, `jenkins-browser-base-url`, `jenkins-browser--auth-header` |
| Job paths | `jenkins-browser--job-path`, `jenkins-browser--job-url`, `jenkins-browser--join-path` |
| API & HTTP helper | `jenkins-browser--http` (raw body), `jenkins-browser--request` (parsed JSON), `jenkins-browser--send`, `jenkins-browser--crumb`, `jenkins-browser--fetch-crumb`, `jenkins-browser--get` |
| Core Jenkins queries | `jenkins-browser--jobs-url`, `jenkins-browser--fetch-jobs`, `jenkins-browser--folder-p`, formatting helpers |
| Refresh handling | `jenkins-browser--refresh-current`, `jenkins-browser--refresh-later`, and the shared auto-refresh timer |
| Jobs UI | `jenkins-browser--job-entries`, `jenkins-browser-mode`, folder navigation |
| Build history | `jenkins-browser--fetch-build-history`, `jenkins-browser--history-entries`, `jenkins-browser-build-history-mode`, `jenkins-browser-history-rebuild` |
| Console | `jenkins-browser-console-mode`, `jenkins-browser-view-console`, and the live-follow functions `jenkins-browser--console-fetch`, `jenkins-browser--console-apply`, `jenkins-browser--console-split` |
| Build Queue | `jenkins-browser-queue-mode`, `jenkins-browser-queue`, `jenkins-browser--fetch-queue`, `jenkins-browser-queue-cancel-item` |
| Pipeline Stages | `jenkins-browser-stages-mode`, `jenkins-browser-view-stages`, `jenkins-browser--fetch-stages`, `jenkins-browser-stages-view-stage-log` |

## Concepts

### Job paths

A job is a slash-separated string (`"team/sub/deploy"`). `jenkins-browser--job-path`
turns it into `/job/team/job/sub/job/deploy`, URL-encoding each component.
Jenkins forbids `/` in job names, so the join is unambiguous. All URL building
goes through `jenkins-browser--job-url`; never interpolate a job name into a URL by hand.

### Entry ids

In the jobs list, each `tabulated-list` entry id is a cons `(NAME . FOLDER-P)`,
where `NAME` is the bare name in the current folder. The full path is
rebuilt with the buffer-local `jenkins-browser--folder`. In the history, the id is the
build number, and the buffer-local `jenkins-browser--history-job` holds the full job path.

### HTTP layer

- `jenkins-browser--http` does the request and returns the response body as a UTF-8 decoded string. It signals an error for status >= 400. An empty body is returned as `""`, which is what a successful `POST` to `/build` gives.
- `jenkins-browser--request` calls it and tries to parse JSON (hash-tables, lists, `nil` for null and false). If parsing fails, it returns the raw body, which is how console text and empty POST responses are handled.
- For `POST`, `PUT` and `DELETE` it sends a CSRF crumb from `/crumbIssuer/api/json` as a header. The crumb is cached per server and user in `jenkins-browser--crumb-cache`. On an HTTP 403 the cache is cleared, a fresh crumb is fetched and the request is retried once (only if the crumb changed). If the crumb endpoint is missing, the request goes ahead without one, and nothing is cached.
- Requests made through `jenkins-browser--http` and `jenkins-browser--request` are **synchronous** (`url-retrieve-synchronously`) with `jenkins-browser-request-timeout`.
- `jenkins-browser--request-async URL CALLBACK` is the non-blocking variant (GET only, so no crumb). It calls `CALLBACK` once with `(RESULT ERROR)`, where `ERROR` is a message string for connection failures, HTTP status >= 400 and timeouts. It enforces `jenkins-browser-request-timeout` itself, and ignores an answer that arrives after the timeout.

### Queries use `tree=`

Every API call passes a `tree` parameter listing only the fields needed, which
keeps responses small. The history query adds `{0,N}` to limit the number of builds.

### Auto-refresh

One global timer (`jenkins-browser--refresh-timer`) is started by the major-mode
functions when `jenkins-browser-auto-refresh-interval` is positive. Each tick refreshes
every visible Jenkins buffer, and cancels the timer if no Jenkins buffers remain.

Ticks and the refresh after an action use `jenkins-browser--refresh-current`, which
sends the query with `jenkins-browser--request-async` and fills the buffer in the
callback (`jenkins-browser--apply-refresh`). The buffer-local `jenkins-browser--refresh-in-flight`
stops a second refresh from starting while one is waiting, and a failed refresh
keeps the old rows. The interactive `jenkins-browser-refresh` and `jenkins-browser-history-refresh`
(`g`) stay synchronous, so they report errors directly.

### Console following

`jenkins-browser-view-console` reads the log with `/logText/progressiveText?start=N`
instead of `/consoleText`. The reply carries two headers: `X-Text-Size` is the
byte offset to ask for next, and `X-More-Data: true` means the build may still
write. The buffer keeps these in `jenkins-browser--console-offset` and
`jenkins-browser--console-more-data`, and a timer asks again until the header is gone.

Things that are easy to get wrong:

- **The offset is the header, not the body length.** The progressive text
  contains hidden annotations (`ESC[8mha:...ESC[0m`), so the body is longer than
  the log bytes it covers. Always take the next offset from `X-Text-Size`.
- **Bodies are handled as bytes.** `jenkins-browser--send` leaves the body undecoded;
  `jenkins-browser--console-split` cuts it at the last newline and keeps the rest in
  `jenkins-browser--console-pending`, so neither a line, an annotation nor a multibyte
  character is ever split between two requests. Only the complete part is
  decoded (`jenkins-browser--decode`), cleaned (`jenkins-browser--console-text`),
  and styled with ANSI colors (`ansi-color-apply`).
- **Stale answers are dropped.** An answer whose request started at an older
  offset than the buffer now has is ignored.
- `lastBuild` is resolved to a build number when the console is opened, so
  following does not jump to a newer build.

## Running the checks

`make check` runs everything below (`compile`, `checkdoc`, `lint`, `test`).
`make lint` installs `package-lint` into `./.elpa` (git-ignored), not into your
Emacs. The individual commands are:

```bash
# byte-compile; keep it warning-free
emacs -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
      -f batch-byte-compile jenkins-browser.el
rm -f jenkins-browser.elc

# docstring style
emacs -Q --batch --eval '(checkdoc-file "jenkins-browser.el")'

# MELPA package rules (needs package-lint, see `make lint`)
make lint

# tests
emacs -Q --batch -L . -l test/jenkins-browser-test.el \
      -f ert-run-tests-batch-and-exit
```

The tests stub `jenkins-browser--request` and `jenkins-browser--http` with `cl-letf`, so they
need no network and no Jenkins server.

## Trying it against a fake server

For an end-to-end check of the HTTP layer, any small server that answers
`/api/json`, `/job/<name>/api/json`, `/crumbIssuer/api/json` and `.../consoleText`
will do. Point `jenkins-browser-url` at it (use `http://127.0.0.1:<port>`), and check
that:

- `Authorization` is sent on every request;
- `POST` requests carry the crumb header;
- 4xx/5xx responses surface as errors.

## Reloading while developing

`M-x jenkins-browser-reload` finds the library on your `load-path` with
`find-library-name`, loads it, and re-initialises the top-level `*Jenkins*`
buffer. Other open Jenkins buffers keep their old mode functions until they are
reopened.

## Adding a feature

1. Build URLs with `jenkins-browser--job-url`; fetch with `jenkins-browser--request` (JSON) or `jenkins-browser--http` (text).
2. Add a command, with `jenkins-browser--read-job` in its `interactive` form if it acts on a job.
3. Bind it in `jenkins-browser-mode-map` or `jenkins-browser-build-history-mode-map`.
4. Add a test that stubs the HTTP layer, and update the README key tables and `docs/usage.md`.
