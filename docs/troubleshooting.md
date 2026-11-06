# Troubleshooting

## "Jenkins URL not configured"

Neither `jenkins-url` nor a `url=` entry in the `[jenkins]` section of
`jenkins-ini-path` was found. Check the section name is exactly `[jenkins]`.
See [configuration](configuration.md).

## "Jenkins returned HTTP 401"

Wrong username or token. Use an **API token** (Jenkins > your user > Configure
> API Token), not your login password if your server uses SSO. Check for
trailing spaces in the INI file; values are trimmed, but quotes are *not*
stripped, so don't quote them.

## "Jenkins returned HTTP 403"

You are authenticated but not permitted, or a CSRF check failed. API tokens
normally bypass the crumb requirement. With a password, `jenkins-mode`
fetches a crumb automatically, but if the Jenkins session is cookie-bound the
crumb may be rejected. Use an API token instead.

## "Jenkins returned HTTP 404"

The job path doesn't exist. Remember that a job inside a folder needs its full
path (`team/deploy`); open the folder first, or pick the job from the folder's
buffer so the path is built for you.

## The job list is empty

- If `jenkins-view-name` is set, the view may not exist or be empty.
- With the running-only filter on (`f`), only running jobs and folders appear.
- Your user may lack *Overall/Read* or *Job/Read*.

## A container isn't shown as a folder

Press `RET` on it and see whether history opens instead. If so, add its Jenkins
class to `jenkins-folder-class-regexp`. You can see the class at
`<jenkins-url>/job/<name>/api/json?tree=_class`.

## `void-function json-parse-string` / wrong-type errors parsing JSON

The package uses Emacs' native JSON parser. Emacs 30+ always has it; older
builds need to be compiled with `--with-json` (libjansson). Check with
`(fboundp 'json-parse-string)`.

## Emacs freezes briefly

Auto-refresh and the refresh after triggering or aborting a build run in the
background. Opening a buffer, pressing `g`, viewing a console and the commands
that change state (trigger, abort) are synchronous, so a slow server makes
Emacs wait for that one request. A hung server is cut off after
`jenkins-request-timeout` seconds.

## Self-signed certificates

Emacs' TLS checks apply as usual. Add the CA to your trust store, or to
`gnutls-trustfiles`. Don't disable certificate verification.

## Author column shows "-"

Jenkins fills *culprits* only for builds that include SCM changes. Manually
triggered or timer-triggered builds with no new commits have none.

## Console is truncated or empty for a running build

Running builds are followed live, so the console grows by itself; the mode
line shows `follow` while it is active. If it stops (for example after a
network error, which is reported in the echo area), press `f` to resume
following or `g` to fetch new output once. Output appears a whole line at a
time, so a long-running step that prints no newline shows nothing until it
ends the line. `c` on a build that has finished always shows its full log.

## Description column is "-" or cut off

"-" means the build has no description (set one in the Jenkins UI, or in a
pipeline with `currentBuild.description = "..."`). The column fills the rest of
the window, so widen the window to see more.
