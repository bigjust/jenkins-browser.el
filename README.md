# jenkins-mode.el

An interactive Emacs major mode for browsing Jenkins jobs: list and filter
jobs, drill into folders and multibranch projects, trigger builds with
interactive parameter prompts, browse build history with authors, read console
logs, and abort builds.

It is a single file with no external dependencies (Emacs 27.1+ with native
JSON support, which every Emacs 30 build has).

## Features

- **Jobs view**: status, last build number and duration, with the current line highlighted.
- **Folders and multibranch pipelines**: folders show as `name/` and open with `RET`, to any depth.
- **Views**: set `jenkins-view-name` to use a Jenkins view as the top-level list.
- **Running filter**: toggle between all jobs and running jobs only with `f`. Folders always stay visible.
- **Parameterized triggering**: reads the job's parameter definitions and prompts for each one. Choice parameters use `completing-read`, and defaults are pre-filled.
- **Build history**: build number, status, timestamp, **author (culprits)**, duration and **description** for the most recent builds (`jenkins-history-limit`, default 50).
- **Console viewer**: `^M` characters and Jenkins' hidden console annotations are stripped and the buffer is read-only. Any build can be opened, not just the latest. A running build is **followed live**: new output is fetched in the background and appended.
- **Abort** the last build from the jobs list, or a specific build from the history.
- **CSRF crumbs** are handled automatically on `POST`.
- **HTTP errors** (401, 403, 404, ...) show up as Emacs errors rather than being parsed as data.
- **Optional auto-refresh** of visible Jenkins buffers.
- **Zero-config credentials**: reads `~/.jenkins_jobs.ini`, or use `M-x customize-group RET jenkins`.

## Installation

```bash
git clone https://github.com/bigjust/jenkins-mode.el.git ~/code/jenkins-mode.el
```

```elisp
(add-to-list 'load-path "~/code/jenkins-mode.el")
(require 'jenkins-mode)

;; Optional global shortcut
(global-set-key (kbd "C-c j") #'jenkins)
```

Then run `M-x jenkins`.

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
(setq jenkins-url "https://jenkins.example.com"
      jenkins-username "your_username"
      jenkins-api-token "your_api_token")
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
| `f` | Toggle all jobs / running only |
| `k` | Abort the latest build |
| `g` | Refresh |
| `o` | Open job in the browser |
| `q` | Quit window |

### Build history (`*Jenkins-History: <job>*`)

| Key | Action |
| --- | --- |
| `RET` / `c` | View console output for the build at point |
| `k` | Abort the build at point |
| `g` | Refresh |
| `o` | Open build in the browser |
| `q` | Quit window |

### Console (`*Jenkins-Console: <job> #<n>*`)

A read-only `special-mode` buffer: `q` quits, `SPC` / `DEL` scroll. For a
running build the mode line shows `follow` and new output is appended every
`jenkins-console-poll-interval` seconds.

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

## License

Copyright (C) 2026 Justin Caratzas.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See [LICENSE](LICENSE) for the full text.
