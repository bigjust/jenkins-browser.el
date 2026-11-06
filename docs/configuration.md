# Configuration

## Credentials

`jenkins-browser` looks up three values: the Jenkins URL, a username, and an API
token (or password). For each one, the first source that has a non-empty value wins:

1. The Emacs variable (`jenkins-browser-url`, `jenkins-browser-username`, `jenkins-browser-api-token`).
2. The `[jenkins]` section of the INI file (`jenkins-browser-ini-path`, default `~/.jenkins_jobs.ini`).

Because lookup happens per value, you can keep the URL in your Emacs config
and the token in the INI file, or the other way round.

### INI file

This is the same file Jenkins Job Builder uses:

```ini
[jenkins]
url=https://jenkins.example.com
user=your_username
password=your_api_token
```

Other sections are ignored. Keep the file private (`chmod 600`).

### Emacs variables

```elisp
(setq jenkins-browser-url "https://jenkins.example.com"
      jenkins-browser-username "your_username"
      jenkins-browser-api-token "your_api_token")
```

Avoid committing tokens to a dotfiles repository. Prefer the INI file, or load
the token at startup from `auth-source`, `pass`, or similar:

```elisp
(setq jenkins-browser-api-token (auth-source-pick-first-password :host "jenkins.example.com"))
```

An API token can be generated in Jenkins under
*People > your user > Configure > API Token*.

## Options

Customize with `M-x customize-group RET jenkins-browser`.

| Variable | Default | Description |
| --- | --- | --- |
| `jenkins-browser-url` | `nil` | Base URL. `nil` means read from the INI file. A trailing slash is ignored. |
| `jenkins-browser-username` | `nil` | Username. `nil` means read from the INI file. |
| `jenkins-browser-api-token` | `nil` | API token or password. `nil` means read from the INI file. |
| `jenkins-browser-ini-path` | `~/.jenkins_jobs.ini` | Location of the INI file. |
| `jenkins-browser-view-name` | `nil` | Jenkins view to use as the top-level list. See below. |
| `jenkins-browser-auto-refresh-interval` | `nil` | Seconds between automatic refreshes, or `nil`/`0` to disable. See below. |
| `jenkins-browser-request-timeout` | `30` | Timeout in seconds for each HTTP request. |
| `jenkins-browser-history-limit` | `50` | Maximum number of builds in a history buffer. |
| `jenkins-browser-console-poll-interval` | `2` | Seconds between requests for new output while following a running build. |
| `jenkins-browser-folder-class-regexp` | `"Folder\\|MultiBranchProject"` | Jobs whose Jenkins `_class` matches are treated as folders. |

### Views

```elisp
(setq jenkins-browser-view-name "My Team")
```

The top-level `*Jenkins*` buffer then lists the jobs in
`<jenkins-browser-url>/view/My%20Team`. The view applies only to the top level. Folders
you open from it list their own contents.

### Auto-refresh

```elisp
(setq jenkins-browser-auto-refresh-interval 30)
```

A single timer refreshes every Jenkins buffer that is currently visible. It
starts when a Jenkins buffer is created, and stops by itself when the last one
is killed.

Timer refreshes run in the background, so Emacs stays responsive while
Jenkins answers. A buffer whose previous refresh has not finished yet is
skipped on the next tick. If a refresh fails or times out
(`jenkins-browser-request-timeout`), the error is shown in the echo area, the old rows
stay on screen and the timer keeps running. The interval is read when the timer
is created, so after changing it, kill your Jenkins buffers and reopen them.

### Folder detection

Folders, organization folders and multibranch projects are recognised by their
Jenkins `_class`. If a plugin adds another container type, extend the regexp:

```elisp
(setq jenkins-browser-folder-class-regexp "Folder\\|MultiBranchProject\\|MyContainerType")
```
