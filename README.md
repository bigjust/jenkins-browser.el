# jenkins-browser

An interactive Emacs major mode for browsing Jenkins jobs: list and filter
jobs, drill into folders and multibranch projects, trigger builds with
interactive parameter prompts, browse build history with authors, read console
logs, and abort builds.

It is a single file with no external dependencies (Emacs 27.1+ with native
JSON support, which every Emacs 30 build has).

## Features

- **Jobs view**: status, last build number and duration, with the current line highlighted.
- **Folders and multibranch pipelines**: folders show as `name/` and open with `RET`, to any depth.
- **Views**: set `jenkins-browser-view-name` to use a Jenkins view as the top-level list.
- **Running filter**: toggle between all jobs and running jobs only with `f`. Folders always stay visible.
- **Parameterized triggering**: reads the job's parameter definitions and prompts for each one. Choice parameters use `completing-read`, password parameters use `read-passwd`, and defaults are pre-filled.
- **Re-trigger builds (`R`)**: re-run past builds with their historical parameters pre-filled.
- **Build history**: build number, status, timestamp, **author (culprits)**, duration and **description** for the most recent builds (`jenkins-browser-history-limit`, default 50).
- **Pipeline Stage View (`s`)**: view stages, per-stage status/duration, and individual stage execution logs.
- **Build Queue (`Q`)**: inspect queued builds, queue reasons, elapsed time, and cancel queued items.
- **Artifacts Browser (`a`)**: list build artifacts, preview them in Emacs, or download them locally.
- **Console viewer**: `^M` characters and Jenkins' hidden console annotations are stripped and the buffer is read-only. Any build can be opened, not just the latest. A running build is **followed live**: new output is fetched in the background and appended.
- **Abort** the last build from the jobs list, or a specific build from the history.
- **Server Profiles**: switch between multiple Jenkins instances defined in `~/.jenkins_jobs.ini` using `M-x jenkins-browser-switch-server`.
- **CSRF crumbs** are handled automatically on `POST`.
- **HTTP errors** (401, 403, 404, ...) show up as Emacs errors rather than being parsed as data.
- **Optional auto-refresh** of visible Jenkins buffers.
- **Zero-config credentials**: reads `~/.jenkins_jobs.ini` or `auth-source`, or use `M-x customize-group RET jenkins-browser`.

## Installation

```bash
git clone https://github.com/bigjust/jenkins-browser.el.git ~/code/jenkins-browser
```

```elisp
(add-to-list 'load-path "~/code/jenkins-browser")
(require 'jenkins-browser)

;; Optional global shortcut
(global-set-key (kbd "C-c j") #'jenkins-browser)
```

Then run `M-x jenkins-browser`.

## Configuration

The simplest option is an existing Jenkins Job Builder file, `~/.jenkins_jobs.ini`:

```ini
[jenkins]
url=https://jenkins.example.com
user=your_username
password=your_api_token
```

Or set the variables directly:

```elisp
(setq jenkins-browser-url "https://jenkins.example.com"
      jenkins-browser-username "your_username"
      jenkins-browser-api-token "your_api_token")
```

Or keep the username and token in `auth-source` (for example `~/.authinfo.gpg`),
with the URL set as above:

```
machine jenkins.example.com login your_username password your_api_token
```

All options, including views, timeouts and auto-refresh, are covered in
[docs/configuration.md](docs/configuration.md).

## Keybindings

### Jobs list (`*Jenkins*`, `*Jenkins: <folder>*`)

| Key | Action |
| --- | --- |
| `RET` | Open the folder at point, or the build history of the job |
| `h` | View build history for the job at point |
| `c` | View console output of the latest build |
| `b` | Trigger / build job (prompts for parameters) |
| `s` | View pipeline stages of the latest build |
| `a` | View artifacts of the latest build |
| `Q` | Open the Jenkins build queue |
| `f` | Toggle all jobs / running only |
| `k` | Abort the latest build |
| `g` | Refresh |
| `o` | Open job in the browser |
| `q` | Quit window |

### Build history (`*Jenkins-History: <job>*`)

| Key | Action |
| --- | --- |
| `RET` / `c` | View console output for the build at point |
| `R` | Re-trigger build with previous parameters pre-filled |
| `s` | View pipeline stages for the build at point |
| `a` | View artifacts for the build at point |
| `k` | Abort the build at point |
| `Q` | Open the Jenkins build queue |
| `g` | Refresh |
| `o` | Open build in the browser |
| `q` | Quit window |

### Build queue (`*Jenkins-Queue*`)

| Key | Action |
| --- | --- |
| `RET` / `h` | Open build history for the queued task |
| `k` / `d` | Cancel the queue item at point |
| `g` | Refresh |
| `o` | Open queue item in the browser |
| `q` | Quit window |

### Pipeline stages (`*Jenkins-Stages: <job> #<n>*`)

| Key | Action |
| --- | --- |
| `RET` / `c` | View full build console log |
| `l` | View log output for the stage at point |
| `g` | Refresh |
| `o` | Open pipeline build in the browser |
| `q` | Quit window |

### Artifacts (`*Jenkins-Artifacts: <job> #<n>*`)

| Key | Action |
| --- | --- |
| `RET` / `v` | View/preview artifact in Emacs buffer |
| `d` | Download artifact to a local file |
| `g` | Refresh |
| `o` | Open artifact URL in the browser |
| `q` | Quit window |

### Console (`*Jenkins-Console: <job> #<n>*`)

A read-only `special-mode` buffer: `q` quits, `SPC` / `DEL` scroll. For a
running build the mode line shows `follow` and new output is appended every
`jenkins-browser-console-poll-interval` seconds.

| Key | Action |
| --- | --- |
| `f` | Start or stop following the build |
| `g` | Fetch new output now |
| `q` | Quit window |

## Documentation

- [Configuration](docs/configuration.md): credentials, customization options, views, auto-refresh.
- [Usage](docs/usage.md): a walkthrough of each buffer and command, including folders and parameters.
- [Architecture and development](docs/development.md): code layout, how requests work, running the tests.
- [Troubleshooting](docs/troubleshooting.md): common errors and fixes.

## Development

```bash
make check   # byte-compile, checkdoc, package-lint and the test suite
make test    # just the tests (no Jenkins server needed)
```

## Releasing

Releases follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
semantic versioning (the version is `Version:` in `jenkins-browser.el`). A
release is a git tag `vX.Y.Z`; MELPA Stable builds from the same tag, while
MELPA builds from `main`.

1. Make sure `make check` passes and the changes are listed under
   `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md).
2. In one commit, set `;; Version: X.Y.Z` in `jenkins-browser.el`, rename
   `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`, add a new empty
   `## [Unreleased]` above it, and update the link references at the bottom of
   the changelog.
3. Push `main` and wait for the CI workflow to pass on Emacs 27.1, 29.4 and 30.1.
4. Tag that commit and push the tag:

   ```bash
   git tag -a vX.Y.Z -m "jenkins-browser X.Y.Z"
   git push origin vX.Y.Z
   ```

The [release workflow](.github/workflows/release.yml) then runs on the tag. It
fails if the tag does not equal the `Version:` header or the changelog has no
section for that version, runs `make check`, and publishes the GitHub release
with that changelog section as the notes. If it fails before publishing, fix
the problem, delete the tag (`git push origin :refs/tags/vX.Y.Z`) and tag again.

## License

Copyright (C) 2026 Justin Caratzas.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See [LICENSE](LICENSE) for the full text.
