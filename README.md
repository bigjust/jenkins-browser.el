# jenkins-mode.el

An interactive Emacs major mode for browsing Jenkins jobs, tracking running builds, triggering builds with interactive parameter input, viewing live console logs, and aborting builds.

## Features

- **Tabulated Jobs View**: Fast overview of job status, latest build number, and duration.
- **Filter Running Builds**: Toggle between all jobs and actively running jobs with `f`.
- **Interactive Parameterized Triggering**: Automatically inspects job parameter definitions and prompts for choices/strings when triggering (`b`).
- **Live Console Log Viewer**: Open the latest build's console text with `RET` or `c`.
- **CSRF Crumb Support**: Automatically handles Jenkins CSRF protection for `POST` actions.
- **Zero-Config Credentials**: Automatically discovers Jenkins URL and API credentials from `~/.jenkins_jobs.ini` or Emacs `custom` settings.

## Installation

Clone this repository:

```bash
git clone https://github.com/your-username/jenkins-mode.el.git ~/code/jenkins-mode.el
```

Add to your `init.el` or `~/.emacs.d/init.el`:

```elisp
(add-to-list 'load-path "~/code/jenkins-mode.el")
(require 'jenkins-mode)

;; Optional: Bind to a global shortcut
(global-set-key (kbd "C-c j") #'jenkins)
```

## Configuration

### Option A: Using `~/.jenkins_jobs.ini` (Recommended)

If you already use Jenkins Job Builder or `~/.jenkins_jobs.ini`, `jenkins-mode` reads your credentials automatically:

```ini
[jenkins]
url=https://jenkins.example.com
user=your_username
password=your_api_token
```

### Option B: Using Emacs `custom` variables

```elisp
(setq jenkins-url "https://jenkins.example.com"
      jenkins-username "your_username"
      jenkins-api-token "your_api_token")
```

## Keybindings in `*Jenkins*` Buffer

| Key | Action |
| --- | --- |
| `g` | Refresh jobs list |
| `f` | Toggle filter (all jobs vs. running only) |
| `b` | Trigger / build job at point (prompts for parameters) |
| `RET` / `c` | View console output for latest build |
| `k` | Abort / stop currently active build |
| `o` | Open job in external browser |
| `q` | Quit window |

## License

GPL-3.0-or-later
