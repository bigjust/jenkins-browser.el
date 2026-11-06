# Architecture and development

Everything lives in [`jenkins-mode.el`](../jenkins-mode.el). Tests are in
[`test/jenkins-mode-test.el`](../test/jenkins-mode-test.el).

## Code layout

The file is organised in sections, top to bottom:

| Section | Contents |
| --- | --- |
| Configuration & Credentials | `jenkins--parse-ini-file`, `jenkins--get-config`, `jenkins-base-url`, `jenkins--auth-header` |
| Job paths | `jenkins--job-path`, `jenkins--job-url`, `jenkins--join-path` |
| API & HTTP helper | `jenkins--http` (raw body), `jenkins--request` (parsed JSON), `jenkins--send`, `jenkins--crumb`, `jenkins--fetch-crumb`, `jenkins--get` |
| Core Jenkins queries | `jenkins--jobs-url`, `jenkins--fetch-jobs`, `jenkins--folder-p`, formatting helpers |
| Refresh handling | `jenkins--refresh-current`, `jenkins--refresh-later`, and the shared auto-refresh timer |
| Jobs UI | `jenkins--job-entries`, `jenkins-mode`, folder navigation |
| Build history | `jenkins--fetch-build-history`, `jenkins--history-entries`, `jenkins-build-history-mode` |
| Console | `jenkins-console-mode`, `jenkins-view-console`, and the live-follow functions `jenkins--console-fetch`, `jenkins--console-apply`, `jenkins--console-split` |

## Concepts

### Job paths

A job is a slash-separated string (`"team/sub/deploy"`). `jenkins--job-path`
turns it into `/job/team/job/sub/job/deploy`, URL-encoding each component.
Jenkins forbids `/` in job names, so the join is unambiguous. All URL building
goes through `jenkins--job-url`; never interpolate a job name into a URL by hand.

### Entry ids

In the jobs list, each `tabulated-list` entry id is a cons `(NAME . FOLDER-P)`,
where `NAME` is the bare name in the current folder. The full path is
rebuilt with the buffer-local `jenkins--folder`. In the history, the id is the
build number, and the buffer-local `jenkins--history-job` holds the full job path.

### HTTP layer

- `jenkins--http` does the request and returns the response body as a UTF-8 decoded string. It signals an error for status >= 400. An empty body is returned as `""`, which is what a successful `POST` to `/build` gives.
- `jenkins--request` calls it and tries to parse JSON (hash-tables, lists, `nil` for null and false). If parsing fails, it returns the raw body, which is how console text and empty POST responses are handled.
- For `POST`, `PUT` and `DELETE` it sends a CSRF crumb from `/crumbIssuer/api/json` as a header. The crumb is cached per server and user in `jenkins--crumb-cache`. On an HTTP 403 the cache is cleared, a fresh crumb is fetched and the request is retried once (only if the crumb changed). If the crumb endpoint is missing, the request goes ahead without one, and nothing is cached.
- Requests made through `jenkins--http` and `jenkins--request` are **synchronous** (`url-retrieve-synchronously`) with `jenkins-request-timeout`.
- `jenkins--request-async URL CALLBACK` is the non-blocking variant (GET only, so no crumb). It calls `CALLBACK` once with `(RESULT ERROR)`, where `ERROR` is a message string for connection failures, HTTP status >= 400 and timeouts. It enforces `jenkins-request-timeout` itself, and ignores an answer that arrives after the timeout.

### Queries use `tree=`

Every API call passes a `tree` parameter listing only the fields needed, which
keeps responses small. The history query adds `{0,N}` to limit the number of builds.

### Auto-refresh

One global timer (`jenkins--refresh-timer`) is started by the major-mode
functions when `jenkins-auto-refresh-interval` is positive. Each tick refreshes
every visible Jenkins buffer, and cancels the timer if no Jenkins buffers remain.

Ticks and the refresh after an action use `jenkins--refresh-current`, which
sends the query with `jenkins--request-async` and fills the buffer in the
callback (`jenkins--apply-refresh`). The buffer-local `jenkins--refresh-in-flight`
stops a second refresh from starting while one is waiting, and a failed refresh
keeps the old rows. The interactive `jenkins-refresh` and `jenkins-history-refresh`
(`g`) stay synchronous, so they report errors directly.

### Console following

`jenkins-view-console` reads the log with `/logText/progressiveText?start=N`
instead of `/consoleText`. The reply carries two headers: `X-Text-Size` is the
byte offset to ask for next, and `X-More-Data: true` means the build may still
write. The buffer keeps these in `jenkins--console-offset` and
`jenkins--console-more-data`, and a timer asks again until the header is gone.

Things that are easy to get wrong:

- **The offset is the header, not the body length.** The progressive text
  contains hidden annotations (`ESC[8mha:...ESC[0m`), so the body is longer than
  the log bytes it covers. Always take the next offset from `X-Text-Size`.
- **Bodies are handled as bytes.** `jenkins--send` leaves the body undecoded;
  `jenkins--console-split` cuts it at the last newline and keeps the rest in
  `jenkins--console-pending`, so neither a line, an annotation nor a multibyte
  character is ever split between two requests. Only the complete part is
  decoded (`jenkins--decode`) and cleaned (`jenkins--console-text`).
- **Stale answers are dropped.** An answer whose request started at an older
  offset than the buffer now has is ignored.
- `lastBuild` is resolved to a build number when the console is opened, so
  following does not jump to a newer build.

## Running the checks

```bash
# byte-compile; keep it warning-free
emacs -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
      -f batch-byte-compile jenkins-mode.el
rm -f jenkins-mode.elc

# docstring style
emacs -Q --batch --eval '(checkdoc-file "jenkins-mode.el")'

# tests
emacs -Q --batch -L . -l test/jenkins-mode-test.el \
      -f ert-run-tests-batch-and-exit
```

The tests stub `jenkins--request` and `jenkins--http` with `cl-letf`, so they
need no network and no Jenkins server.

## Trying it against a fake server

For an end-to-end check of the HTTP layer, any small server that answers
`/api/json`, `/job/<name>/api/json`, `/crumbIssuer/api/json` and `.../consoleText`
will do. Point `jenkins-url` at it (use `http://127.0.0.1:<port>`), and check
that:

- `Authorization` is sent on every request;
- `POST` requests carry the crumb header;
- 4xx/5xx responses surface as errors.

## Reloading while developing

`M-x jenkins-reload` finds the library on your `load-path` with
`find-library-name`, loads it, and re-initialises the top-level `*Jenkins*`
buffer. Other open Jenkins buffers keep their old mode functions until they are
reopened.

## Adding a feature

1. Build URLs with `jenkins--job-url`; fetch with `jenkins--request` (JSON) or `jenkins--http` (text).
2. Add a command, with `jenkins--read-job` in its `interactive` form if it acts on a job.
3. Bind it in `jenkins-mode-map` or `jenkins-build-history-mode-map`.
4. Add a test that stubs the HTTP layer, and update the README key tables and `docs/usage.md`.
