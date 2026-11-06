# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Build Queue viewer (`*Jenkins-Queue*`, `Q`, `M-x jenkins-browser-queue`) with item cancellation (`k` / `d`) and task navigation.
- Re-trigger build command (`R` / `jenkins-browser-history-rebuild`) in build history to replay previous runs with historical parameters pre-filled.
- Multiple Jenkins server profiles support (`M-x jenkins-browser-switch-server`) with interactive switching across sections in `~/.jenkins_jobs.ini`.

## [0.3.0] - 2026-11-06

### Changed

- **Renamed the package from `jenkins-mode` to `jenkins-browser`** so it does
  not clash with the `jenkins` package on MELPA. This is a breaking change:
  - `(require 'jenkins-mode)` becomes `(require 'jenkins-browser)`.
  - `M-x jenkins` becomes `M-x jenkins-browser`.
  - Every `jenkins-` symbol is now `jenkins-browser-`, for example
    `jenkins-url` is `jenkins-browser-url`, and the customize group is
    `jenkins-browser`.
  - The `[jenkins]` INI section, `~/.jenkins_jobs.ini` and the `*Jenkins...*`
    buffer names are unchanged.
- Buffers now refresh in the background (timer and after an action) instead of
  blocking Emacs. A failed refresh keeps the old rows and shows the error.
- A failed first load no longer leaves an empty buffer behind.
- Removed the unused `jenkins-current-job` and the redundant `C-m` bindings.

### Added

- Live following of running builds in the console buffer (`f` toggles,
  `g` refreshes), with `jenkins-browser-console-poll-interval`.
- `auth-source` as a fallback for the username and password, looked up by the
  host of the Jenkins URL.
- INI parsing accepts comment lines (`#`, `;`) and `:` as the separator.
- A warning when a password is read from an INI file that other users can read.
- The CSRF crumb is cached and fetched again once on HTTP 403.
- A `Makefile` (`make check`), package-lint, and GitHub Actions CI on
  Emacs 27.1, 29.4 and 30.1.
- `URL:` header and other package metadata needed for MELPA.

### Fixed

- Boolean job parameters are sent as `true`/`false`.

## [0.2.0] - 2026-11-03

### Added

- Build history buffer with number, status, timestamp, author (culprits),
  duration and description, limited by `jenkins-history-limit`.
- Folder, multibranch and view support. Jobs are addressed by URL-encoded path.
- Read-only console buffer without carriage returns.
- Optional auto-refresh of visible buffers, and current-line highlighting.
- ERT test suite with a stubbed HTTP layer, and the `docs/` directory.
- GPL-3.0-or-later license.

### Changed

- HTTP errors are signalled as Emacs errors, responses are decoded as UTF-8,
  and requests have a timeout.

## [0.1.0] - 2026-11-03

- Initial version: list jobs with a running-only filter, trigger jobs
  (including parameterized ones), view a build's console, abort builds and open
  jobs in the browser, reading credentials from `~/.jenkins_jobs.ini`.

[Unreleased]: https://github.com/bigjust/jenkins-browser.el/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/bigjust/jenkins-browser.el/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/bigjust/jenkins-browser.el/commit/4284f3e
[0.1.0]: https://github.com/bigjust/jenkins-browser.el/commit/1e77501
