# Architecture and development

Everything lives in [`jenkins-mode.el`](../jenkins-mode.el). Tests are in
[`test/jenkins-mode-test.el`](../test/jenkins-mode-test.el).

## Code layout

The file is organised in sections, top to bottom:

| Section | Contents |
| --- | --- |
| Configuration & Credentials | `jenkins--parse-ini-file`, `jenkins--get-config`, `jenkins-base-url`, `jenkins--auth-header` |
| Job paths | `jenkins--job-path`, `jenkins--job-url`, `jenkins--join-path` |
| API & HTTP helper | `jenkins--http` (raw body), `jenkins--request` (parsed JSON), `jenkins--fetch-crumb`, `jenkins--get` |
| Core Jenkins queries | `jenkins--jobs-url`, `jenkins--fetch-jobs`, `jenkins--folder-p`, formatting helpers |
| Refresh handling | `jenkins--refresh-later`, and the shared auto-refresh timer |
| Jobs UI | `jenkins--job-entries`, `jenkins-mode`, folder navigation |
| Build history | `jenkins--fetch-build-history`, `jenkins--history-entries`, `jenkins-build-history-mode` |
| Console | `jenkins-console-mode`, `jenkins-view-console` |

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
- For `POST`, `PUT` and `DELETE` it first fetches a CSRF crumb from `/crumbIssuer/api/json` and sends it as a header. If the crumb endpoint is missing, the request goes ahead without one.
- Requests are **synchronous** (`url-retrieve-synchronously`) with `jenkins-request-timeout`.

### Queries use `tree=`

Every API call passes a `tree` parameter listing only the fields needed, which
keeps responses small. The history query adds `{0,N}` to limit the number of builds.

### Auto-refresh

One global timer (`jenkins--refresh-timer`) is started by the major-mode
functions when `jenkins-auto-refresh-interval` is positive. Each tick refreshes
every visible Jenkins buffer, and cancels the timer if no Jenkins buffers remain.

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
