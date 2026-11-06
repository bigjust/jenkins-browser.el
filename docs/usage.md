# Usage

Start with `M-x jenkins-browser`. All three buffer types are read-only and
refreshable with `g`.

## The jobs list

`M-x jenkins-browser` opens `*Jenkins*`:

```
  Job Name                                  Status       Last #   Duration
  deploy-prod                               SUCCESS      #212     4m 05s
  nightly-tests                             RUNNING      #88      -
  team/                                     FOLDER       -        -
```

- Click a column header (or press `S` on it) to sort.
- `f` toggles running-only. Folders remain visible so you can still navigate.
- `g` refreshes.

### Folders and multibranch projects

Rows marked `name/` are containers. Press `RET` to open one in a new buffer,
named `*Jenkins: team/sub*`. Folders can nest to any depth, and each level opens
its own buffer. Press `q` to go back.

Multibranch projects behave like folders, so their branches (and pull requests)
are listed as jobs. Branch names such as `feature/x` are stored by Jenkins as
`feature%2Fx`, and `jenkins-browser` encodes them correctly.

Actions on a folder row (`b`, `c`, `k`, `o`, `h`) report that it is a folder
rather than acting on it.

### Job paths

Everywhere a job is asked for, it is a slash-separated path such as
`team/sub/deploy`. Each component is URL-encoded before it is placed in a
`/job/<name>` URL, so names containing spaces or other special characters work.

### Triggering a build (`b`)

`jenkins-browser-trigger-job` fetches the job's definition:

- **No parameters**: the build is queued immediately.
- **With parameters**: each parameter is prompted for in turn.
  - Choice parameters use `completing-read` with the default pre-selected.
  - Everything else uses `read-string` with the default pre-filled. The parameter's description is shown in the prompt.
  - The build is then queued with `buildWithParameters`.

The list refreshes two seconds after the trigger.

If point is not on a job (for example when called from another buffer), you
are asked to pick one from the current folder.

### Build history (`RET` or `h`)

Opens `*Jenkins-History: <job>*` with the most recent builds
(`jenkins-browser-history-limit`):

```
  Build   Status    Timestamp         Author          Duration  Description
  #212    SUCCESS   2026-11-02 14:03  Ann Lee         4m 05s    Release 1.4 to prod
  #211    FAILURE   2026-11-02 11:40  Bo Park, Ann L  3m 12s    -
```

**Author** is Jenkins' list of *culprits*: the users whose commits went into
the build. It is `-` for builds without changes (timer or manual runs).

**Description** is the build's description, as set in the Jenkins UI or by a
pipeline (`currentBuild.description`). It is shown on one line with HTML tags
removed, common entities decoded and whitespace collapsed. It is `-` when the
build has none, and it takes the remaining window width, so long descriptions
are truncated (use `M-x toggle-truncate-lines` or widen the window).

| Key | Action |
| --- | --- |
| `RET`, `c` | Console of the build at point |
| `k` | Abort the build at point (after confirmation) |
| `o` | Open the build in the browser |
| `g` | Refresh |

### Console (`c`)

`c` in the jobs list shows the latest build. In the history it shows the build
at point. The log opens in `*Jenkins-Console: <job> #<n>*`:

- carriage returns (`^M`) and the hidden annotations Jenkins embeds in the log
  (links, step markers) are removed;
- the buffer is read-only (`special-mode`), with `q` to close;
- point starts at the end of the log.

A running build is followed live. The mode line shows `follow`, and every
`jenkins-browser-console-poll-interval` seconds (default 2) the new part of the log is
fetched in the background and appended. Only whole lines are shown, so a line
never appears half written. If point is at the end of the buffer it keeps
following the output, and if you have scrolled up, the buffer leaves your
position alone. Following stops by itself when the build finishes.

| Key | Action |
| --- | --- |
| `f` | Stop or resume following |
| `g` | Fetch new output now (also useful after following stopped on an error) |
| `q` | Quit window |

`c` on `lastBuild` opens the console of the build that is the latest at that
moment, and keeps following that build even if a newer one starts.

### Aborting (`k`)

In the jobs list, `k` stops the job's last build; in the history it stops the
selected one. Both ask for confirmation first.

## Commands

| Command | Description |
| --- | --- |
| `jenkins-browser` | Open the top-level jobs list |
| `jenkins-browser-refresh` | Refresh the current jobs list |
| `jenkins-browser-enter` | Open the folder or history at point |
| `jenkins-browser-open-folder` | Open the jobs list for a folder path (Lisp function) |
| `jenkins-browser-toggle-running-filter` | Toggle running-only |
| `jenkins-browser-trigger-job` | Trigger a job |
| `jenkins-browser-view-build-history` | Show a job's builds |
| `jenkins-browser-view-console` | Show a build's console |
| `jenkins-browser-abort-build` | Abort a job's last build |
| `jenkins-browser-open-in-browser` | Open a job in the browser |
| `jenkins-browser-history-view-console` | Console for a build in the history |
| `jenkins-browser-history-abort-build` | Abort a build in the history |
| `jenkins-browser-history-open-in-browser` | Open a build in the browser |
| `jenkins-browser-history-refresh` | Refresh the current history |
| `jenkins-browser-reload` | Reload `jenkins-browser` from its library file (for development) |

Both major modes derive from `tabulated-list-mode`, so its keys also work
(`n`/`p`, `S`, `{`/`}` to resize columns, and so on). The major modes are
`jenkins-browser-mode`, `jenkins-browser-build-history-mode` and `jenkins-browser-console-mode`, each
with a hook of the same name plus `-hook`.
