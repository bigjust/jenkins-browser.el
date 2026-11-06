;;; jenkins-browser.el --- Interactive Jenkins job viewer and trigger -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Justin Caratzas

;; Author: Justin Caratzas
;; URL: https://github.com/bigjust/jenkins-browser.el
;; Keywords: tools, jenkins, ci
;; Version: 0.3.0
;; Package-Requires: ((emacs "27.1"))

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; An interactive major mode to list jobs, navigate folders and multibranch
;; projects, filter running builds, trigger parameterized and
;; non-parameterized jobs, view build history (with authors), inspect console
;; logs, and abort builds.
;;
;; Start with `M-x jenkins-browser'.
;;
;; Credentials and Jenkins URL can be configured via customize options or
;; automatically loaded from `~/.jenkins_jobs.ini' or `auth-source'.
;;
;; Jobs are addressed by a slash-separated path such as "folder/sub/job".
;; Jenkins job names cannot contain a slash, so this is unambiguous.
;;
;; Note: parsing uses `json-parse-string', so Emacs must have native JSON
;; support (always the case in Emacs 30+, and in older builds with jansson).
;;
;; See the docs/ directory of the source repository for details.

;;; Code:

(require 'tabulated-list)
(require 'hl-line)
(require 'json)
(require 'url)
(require 'url-http)
(require 'subr-x)
(require 'cl-lib)
(require 'find-func)
(require 'auth-source)
(require 'ansi-color)

(defgroup jenkins-browser nil
  "Interact with Jenkins from Emacs."
  :group 'tools
  :prefix "jenkins-browser-")

(defcustom jenkins-browser-url nil
  "Base URL for Jenkins (e.g., https://jenkins.example.com).
If nil, attempts to read from `~/.jenkins_jobs.ini`."
  :type '(choice (const :tag "Auto from ini" nil) string)
  :group 'jenkins-browser)

(defcustom jenkins-browser-username nil
  "Jenkins username.  If nil, attempts to read from `~/.jenkins_jobs.ini`."
  :type '(choice (const :tag "Auto from ini" nil) string)
  :group 'jenkins-browser)

(defcustom jenkins-browser-api-token nil
  "Jenkins API token or password.
If nil, attempts to read from `~/.jenkins_jobs.ini`."
  :type '(choice (const :tag "Auto from ini" nil) string)
  :group 'jenkins-browser)

(defcustom jenkins-browser-ini-path (expand-file-name "~/.jenkins_jobs.ini")
  "Path to jenkins_jobs.ini configuration file."
  :type 'file
  :group 'jenkins-browser)

(defcustom jenkins-browser-server-profile "jenkins"
  "Name of the server profile section in `jenkins-browser-ini-path' to use."
  :type 'string
  :group 'jenkins-browser)

(defcustom jenkins-browser-view-name nil
  "Name of a Jenkins view to use as the root job list.
If nil, the jobs of the Jenkins root are listed.  The view only applies to
the root buffer, not to folders opened from it."
  :type '(choice (const :tag "No view" nil) string)
  :group 'jenkins-browser)

(defcustom jenkins-browser-auto-refresh-interval nil
  "Auto-refresh interval in seconds for visible Jenkins buffers.
Set to nil or 0 to disable auto-refresh.  Refreshes run in the
background and do not block Emacs; a buffer whose previous refresh is
still waiting for Jenkins is skipped.  The value is read when a Jenkins
buffer is created."
  :type '(choice (const :tag "Disabled" nil) integer)
  :group 'jenkins-browser)

(defcustom jenkins-browser-request-timeout 30
  "Timeout in seconds for each HTTP request to Jenkins."
  :type 'integer
  :group 'jenkins-browser)

(defcustom jenkins-browser-history-limit 50
  "Maximum number of builds to show in a build history buffer."
  :type 'integer
  :group 'jenkins-browser)

(defcustom jenkins-browser-folder-class-regexp "Folder\\|MultiBranchProject"
  "Regexp matching the Jenkins `_class' of jobs that contain other jobs."
  :type 'regexp
  :group 'jenkins-browser)

(defvar-local jenkins-browser--filter-running-only nil
  "Non-nil if only running builds are displayed.")

(defvar-local jenkins-browser--folder nil
  "Slash-separated folder path shown in this buffer, or nil for the root.")

(defvar-local jenkins-browser--history-job nil
  "The slash-separated job path for the current build history buffer.")

(defvar jenkins-browser--refresh-timer nil
  "Timer object for periodic refresh.")

;;; --- Configuration & Credentials ---

(defun jenkins-browser--parse-ini-sections (path)
  "Parse all sections from PATH and return an alist of (SECTION . KEY-VALUES)."
  (when (file-readable-p path)
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      (let (sections current-section current-pairs)
        (while (not (eobp))
          (let ((line (string-trim (buffer-substring-no-properties
                                    (line-beginning-position)
                                    (line-end-position)))))
            (cond
             ((string-match-p "^[#;]" line))
             ((string-match "^\\[\\([^]]+\\)\\]" line)
              (when current-section
                (push (cons current-section (nreverse current-pairs)) sections))
              (setq current-section (match-string 1 line)
                    current-pairs nil))
             ((and current-section
                   (string-match "^\\([^=:]+\\)[=:]\\(.*\\)$" line))
              (push (cons (string-trim (match-string 1 line))
                          (string-trim (match-string 2 line)))
                    current-pairs))))
          (forward-line 1))
        (when current-section
          (push (cons current-section (nreverse current-pairs)) sections))
        (nreverse sections)))))

(defun jenkins-browser--parse-ini-file (path &optional section)
  "Parse SECTION (default `jenkins-browser-server-profile') from PATH.
Lines starting with `#' or `;' are comments, and a key is separated
from its value by `=' or `:', as Jenkins Job Builder allows.  Inline
comments are not recognised, since a token may contain `#' or `;'.
Return an alist of (KEY . VALUE)."
  (let* ((sec-name (or section jenkins-browser-server-profile "jenkins"))
         (sections (jenkins-browser--parse-ini-sections path)))
    (cdr (assoc sec-name sections))))

(defvar jenkins-browser--crumb-cache nil
  "Cached CSRF crumb as (KEY . CRUMB), or nil.
KEY identifies the server and user the crumb was issued for, see
`jenkins-browser--crumb-key'.  CRUMB is a cons (HEADER . VALUE).")

(defun jenkins-browser-server-profiles ()
  "Return list of available server profile names from `jenkins-browser-ini-path'."
  (let ((sections (jenkins-browser--parse-ini-sections jenkins-browser-ini-path)))
    (mapcar #'car sections)))

(defun jenkins-browser-switch-server (profile)
  "Switch the active Jenkins server configuration to PROFILE."
  (interactive
   (let ((profiles (jenkins-browser-server-profiles)))
     (unless profiles
       (user-error "No server profiles found in %s" jenkins-browser-ini-path))
     (list (completing-read "Jenkins server profile: " profiles nil t nil nil
                            jenkins-browser-server-profile))))
  (setq jenkins-browser-server-profile profile
        jenkins-browser-url nil
        jenkins-browser-username nil
        jenkins-browser-api-token nil
        jenkins-browser--crumb-cache nil)
  (when (get-buffer "*Jenkins*")
    (with-current-buffer "*Jenkins*"
      (jenkins-browser-refresh)))
  (message "Switched to Jenkins server profile '%s'" profile))

;; Paths already warned about, so the warning appears once per session.
(defvar jenkins-browser--warned-ini-paths nil
  "INI file names for which a permissions warning was already shown.")

(defun jenkins-browser--check-ini-permissions (path)
  "Warn once if the INI file PATH, used for a password, is not private.
Do nothing on Windows, where file modes do not express this."
  (unless (or (eq system-type 'windows-nt)
              (member path jenkins-browser--warned-ini-paths))
    (let ((mode (file-modes path)))
      (when (and mode (not (zerop (logand mode #o077))))
        (push path jenkins-browser--warned-ini-paths)
        (display-warning
         'jenkins-browser
         (format (concat "%s contains a password but is readable by other "
                         "users (mode %o); run `chmod 600 %s'")
                 path mode (shell-quote-argument path))
         :warning)))))

(defun jenkins-browser--auth-source-lookup (key)
  "Return KEY (\"user\" or \"password\") from `auth-source', or nil.
The entry is searched by the host name of the configured URL.  For
\"password\" the user name found by `jenkins-browser--get-config' is
used to pick the entry, so both values come from the same one."
  (let* ((url (jenkins-browser--get-config "url"))
         (host (and url (url-host (url-generic-parse-url url))))
         (user (and host (equal key "password")
                    (jenkins-browser--get-config "user"))))
    (when host
      (let* ((spec (append (list :host host :max 1
                                 :require (list (if user :secret :user)))
                           (and user (list :user user))))
             (entry (car (apply #'auth-source-search spec)))
             (value (plist-get entry (if (equal key "user") :user :secret))))
        (if (functionp value) (funcall value) value)))))

(defun jenkins-browser--get-config (key)
  "Retrieve KEY (\"url\", \"user\", or \"password\").
Look in the custom variables first, then the INI file, and for \"user\"
and \"password\" finally in `auth-source'.  Empty values count as unset."
  (let ((custom-val (pcase key
                      ("url" jenkins-browser-url)
                      ("user" jenkins-browser-username)
                      ("password" jenkins-browser-api-token))))
    (if (and custom-val (not (string-empty-p custom-val)))
        custom-val
      (let ((ini-val (cdr (assoc key (jenkins-browser--parse-ini-file
                                      jenkins-browser-ini-path)))))
        (cond
         ((and ini-val (not (string-empty-p ini-val)))
          (when (equal key "password")
            (jenkins-browser--check-ini-permissions jenkins-browser-ini-path))
          ini-val)
         ((member key '("user" "password"))
          (jenkins-browser--auth-source-lookup key)))))))

(defun jenkins-browser-base-url ()
  "Get sanitized Jenkins base URL without trailing slash."
  (let ((url (jenkins-browser--get-config "url")))
    (unless url
      (error "Jenkins URL not configured.  Set `jenkins-browser-url' or configure %s"
             jenkins-browser-ini-path))
    (directory-file-name url)))

(defun jenkins-browser--auth-header ()
  "Construct HTTP Basic Auth header."
  (let ((user (jenkins-browser--get-config "user"))
        (pass (jenkins-browser--get-config "password")))
    (when (and user pass)
      (format "Basic %s" (base64-encode-string (format "%s:%s" user pass) t)))))

;;; --- Job paths ---

(defun jenkins-browser--join-path (&rest parts)
  "Join the non-empty strings in PARTS with a slash."
  (string-join (cl-remove-if (lambda (p) (or (null p) (string-empty-p p))) parts)
               "/"))

(defun jenkins-browser--job-path (job)
  "Return the URL path fragment for JOB, e.g. \"/job/a/job/b\".
JOB is a slash-separated string such as \"a/b\".  Each component is
URL-encoded.  Return the empty string when JOB is nil or empty."
  (mapconcat (lambda (name) (concat "/job/" (url-hexify-string name)))
             (split-string (or job "") "/" t)
             ""))

(defun jenkins-browser--job-url (job &optional suffix)
  "Return the full URL of JOB, optionally followed by SUFFIX."
  (concat (jenkins-browser-base-url) (jenkins-browser--job-path job) (or suffix "")))

;;; --- API & HTTP Helper ---

(defun jenkins-browser--get (key obj)
  "Safely retrieve KEY from OBJ if OBJ is a hash-table, else nil.
Converts `:null` and `:json-false` values to nil."
  (when (hash-table-p obj)
    (let ((val (gethash key obj)))
      (if (memq val '(:null :json-false)) nil val))))

(defun jenkins-browser--crumb-key ()
  "Return a string identifying the current server and user."
  (concat (or (jenkins-browser--get-config "user") "") "@" (jenkins-browser-base-url)))

(defun jenkins-browser--crumb ()
  "Return the CSRF crumb for the current server, fetching it if needed.
A crumb fetched successfully is cached until `jenkins-browser--crumb-cache' is
cleared.  Return nil when the server does not issue crumbs."
  (let ((key (jenkins-browser--crumb-key)))
    (if (equal (car jenkins-browser--crumb-cache) key)
        (cdr jenkins-browser--crumb-cache)
      (let ((crumb (jenkins-browser--fetch-crumb)))
        (when crumb
          (setq jenkins-browser--crumb-cache (cons key crumb)))
        crumb))))

(defun jenkins-browser--parse-headers ()
  "Return the HTTP response headers in the current buffer as an alist.
Header names are downcased, so they can be looked up with `assoc'
whatever capitalisation the server uses."
  (save-excursion
    (goto-char (point-min))
    (forward-line 1)
    (let (headers)
      (while (looking-at "\\([^:\n\r]+\\):[ \t]*\\(.*?\\)\r?$")
        (push (cons (downcase (match-string 1)) (match-string 2)) headers)
        (forward-line 1))
      (nreverse headers))))

(defun jenkins-browser--parse-response ()
  "Return (STATUS BODY HEADERS) for the HTTP response in the current buffer.
STATUS is the HTTP status code or nil.  BODY is the undecoded body, see
`jenkins-browser--decode'.  HEADERS is an alist as returned by
`jenkins-browser--parse-headers'."
  (let ((status (bound-and-true-p url-http-response-status))
        (headers (jenkins-browser--parse-headers)))
    (goto-char (point-min))
    (re-search-forward "^$" nil t)
    (unless (eobp)
      (forward-char 1))
    (list status
          (buffer-substring-no-properties (point) (point-max))
          headers)))

(defun jenkins-browser--decode (bytes)
  "Decode the undecoded response body BYTES as UTF-8."
  (decode-coding-string bytes 'utf-8))

(defun jenkins-browser--send (method url-str post-data content-type crumb)
  "Perform a synchronous HTTP request; return (STATUS BODY HEADERS).
METHOD, URL-STR, POST-DATA and CONTENT-TYPE are as for `jenkins-browser--http'.
CRUMB is a cons (HEADER . VALUE) to send as a header, or nil.  The body
is returned undecoded, see `jenkins-browser--parse-response'.  Never signal an
error because of the HTTP status."
  (let* ((auth (jenkins-browser--auth-header))
         (url-request-method method)
         (url-request-extra-headers
          (delq nil
                (list (when auth (cons "Authorization" auth))
                      (when content-type (cons "Content-Type" content-type))
                      crumb)))
         (url-request-data post-data)
         (buf (url-retrieve-synchronously url-str t t jenkins-browser-request-timeout)))
    (unless buf
      (error "No response from Jenkins for %s" url-str))
    (with-current-buffer buf
      (unwind-protect
          (jenkins-browser--parse-response)
        (kill-buffer buf)))))

(defun jenkins-browser--http-full (method url-str &optional post-data content-type raw)
  "Perform a synchronous HTTP request; return (BODY . HEADERS).
METHOD is the HTTP verb and URL-STR the target.  POST-DATA and CONTENT-TYPE
are sent with the request when non-nil.  BODY is the response body string,
decoded as UTF-8 unless RAW is non-nil, and HEADERS the response headers,
see `jenkins-browser--parse-headers'.  A CSRF
crumb is attached to state-changing methods; it is cached, and if the
server rejects the request with HTTP 403 the crumb is refreshed and the
request retried once.  Signal an error on HTTP status 400 or above."
  (let* ((state-changing (member method '("POST" "PUT" "DELETE")))
         (crumb (and state-changing (jenkins-browser--crumb)))
         (resp (jenkins-browser--send method url-str post-data content-type crumb)))
    (when (and crumb (eql (nth 0 resp) 403))
      (setq jenkins-browser--crumb-cache nil)
      (let ((fresh (jenkins-browser--crumb)))
        (when (and fresh (not (equal fresh crumb)))
          (setq resp (jenkins-browser--send method url-str post-data content-type fresh)))))
    (when (and (integerp (nth 0 resp)) (>= (nth 0 resp) 400))
      (error "Jenkins returned HTTP %d for %s" (nth 0 resp) url-str))
    (cons (if raw (nth 1 resp) (jenkins-browser--decode (nth 1 resp)))
          (nth 2 resp))))

(defun jenkins-browser--http (method url-str &optional post-data content-type)
  "Perform a synchronous HTTP request and return the response body string.
METHOD, URL-STR, POST-DATA and CONTENT-TYPE are as for
`jenkins-browser--http-full', which also describes the CSRF crumb
handling.  Signal an error on HTTP status 400 or above."
  (car (jenkins-browser--http-full method url-str post-data content-type)))

(defun jenkins-browser--parse-json (body)
  "Parse BODY as JSON into hash-tables and lists, or return BODY unchanged.
JSON null and false both become nil."
  (condition-case nil
      (json-parse-string body
                         :object-type 'hash-table
                         :array-type 'list
                         :null-object nil
                         :false-object nil)
    (error body)))

(defun jenkins-browser--request (method url-str &optional post-data content-type)
  "Make a synchronous request; return parsed JSON or the raw body string.
METHOD, URL-STR, POST-DATA and CONTENT-TYPE are as for `jenkins-browser--http'."
  (jenkins-browser--parse-json (jenkins-browser--http method url-str post-data content-type)))

(defun jenkins-browser--request-async (url-str callback &optional raw)
  "Send a GET request to URL-STR without blocking Emacs.
CALLBACK is called exactly once, with arguments (RESULT ERROR).  On
success RESULT is the parsed JSON or raw body, as for
`jenkins-browser--request', and ERROR is nil.  With RAW non-nil,
RESULT is instead the plist \(:body STRING :headers ALIST), where the
body is neither decoded nor parsed.  On failure (connection problem,
HTTP status 400 or above, or `jenkins-browser-request-timeout' seconds
without an answer) RESULT is nil and ERROR is a message string.  Only
GET is supported, so no CSRF crumb is involved."
  (let* ((auth (jenkins-browser--auth-header))
         (url-request-method "GET")
         (url-request-extra-headers
          (when auth (list (cons "Authorization" auth))))
         (url-request-data nil)
         (timeout jenkins-browser-request-timeout)
         (done nil)
         (timer nil)
         (buf nil))
    (cl-flet ((finish (result err)
                (unless done
                  (setq done t)
                  (when timer (cancel-timer timer))
                  (condition-case cb-err
                      (funcall callback result err)
                    (error (message "jenkins-browser: callback failed: %s"
                                    (error-message-string cb-err)))))))
      (setq buf
            (url-retrieve
             url-str
             (lambda (status)
               (let ((resp-buf (current-buffer)))
                 (unwind-protect
                     (let* ((resp (jenkins-browser--parse-response))
                            (code (nth 0 resp)))
                       (cond
                        ((and (integerp code) (>= code 400))
                         (finish nil (format "Jenkins returned HTTP %d for %s"
                                             code url-str)))
                        ((plist-get status :error)
                         (finish nil (format "Request to %s failed: %S" url-str
                                             (plist-get status :error))))
                        ((not (integerp code))
                         (finish nil (format "No response from Jenkins for %s" url-str)))
                        (t (finish (if raw
                                       (list :body (nth 1 resp) :headers (nth 2 resp))
                                     (jenkins-browser--parse-json
                                      (jenkins-browser--decode (nth 1 resp))))
                                   nil))))
                   (when (buffer-live-p resp-buf)
                     (kill-buffer resp-buf)))))
             nil t t))
      ;; The callback may already have run if `url-retrieve' failed at once.
      (unless done
        (setq timer
              (run-at-time
               timeout nil
               (lambda ()
                 (unless done
                   (finish nil (format "Request to %s timed out after %ss"
                                       url-str timeout))
                   (when (buffer-live-p buf)
                     (let ((proc (get-buffer-process buf)))
                       (when proc (delete-process proc)))
                     (kill-buffer buf))))))))))

(defun jenkins-browser--fetch-crumb ()
  "Fetch the CSRF protection crumb as a cons (HEADER . VALUE), or nil."
  (condition-case nil
      (let* ((url (format "%s/crumbIssuer/api/json" (jenkins-browser-base-url)))
             (res (jenkins-browser--request "GET" url)))
        (when (hash-table-p res)
          (let ((field (jenkins-browser--get "crumbRequestField" res))
                (crumb (jenkins-browser--get "crumb" res)))
            (when (and field crumb)
              (cons field crumb)))))
    (error nil)))

;;; --- Core Jenkins Queries ---

(defun jenkins-browser--jobs-url (folder)
  "Return the API URL listing the jobs in FOLDER (nil for the root)."
  (let ((tree "jobs[name,color,_class,lastBuild[number,building,result,duration,timestamp,estimatedDuration]]"))
    (concat (jenkins-browser-base-url)
            (if (and (null folder) jenkins-browser-view-name)
                (concat "/view/" (url-hexify-string jenkins-browser-view-name))
              (jenkins-browser--job-path folder))
            "/api/json?tree=" (url-hexify-string tree))))

(defun jenkins-browser--jobs-from-response (resp)
  "Return the list of job hash-tables in the parsed jobs response RESP."
  (when (hash-table-p resp)
    (jenkins-browser--get "jobs" resp)))

(defun jenkins-browser--fetch-jobs (&optional folder)
  "Fetch all jobs in FOLDER (nil for the root) and their last build metadata."
  (jenkins-browser--jobs-from-response
   (jenkins-browser--request "GET" (jenkins-browser--jobs-url folder))))

(defun jenkins-browser--folder-p (job)
  "Return non-nil if the job hash-table JOB can contain other jobs."
  (let ((class (jenkins-browser--get "_class" job)))
    (and (stringp class)
         (string-match-p jenkins-browser-folder-class-regexp class))))

(defun jenkins-browser--format-duration (millis)
  "Convert MILLIS to a human-readable duration."
  (if (or (null millis) (not (numberp millis)) (<= millis 0))
      "-"
    (let* ((secs (truncate (/ millis 1000.0)))
           (mins (/ secs 60))
           (hours (/ mins 60)))
      (cond
       ((> hours 0) (format "%dh %02dm" hours (% mins 60)))
       ((> mins 0)  (format "%dm %02ds" mins (% secs 60)))
       (t           (format "%ds" secs))))))

(defun jenkins-browser--format-timestamp (millis)
  "Convert MILLIS epoch timestamp to formatted date/time string."
  (if (or (null millis) (not (numberp millis)) (<= millis 0))
      "-"
    (format-time-string "%Y-%m-%d %H:%M" (seconds-to-time (/ millis 1000.0)))))

(defun jenkins-browser--format-description (description)
  "Format build DESCRIPTION as a single line of plain text.
Jenkins descriptions may contain HTML; tags are removed, common entities
decoded and whitespace collapsed.  Return \"-\" when there is nothing to show."
  (let ((text (if (stringp description) description "")))
    (setq text (replace-regexp-in-string "<br[ \t]*/?>" " " text t))
    (setq text (replace-regexp-in-string "<[^>]*>" "" text t))
    (dolist (entity '(("&lt;" . "<") ("&gt;" . ">") ("&quot;" . "\"")
                      ("&#39;" . "'") ("&nbsp;" . " ") ("&amp;" . "&")))
      (setq text (replace-regexp-in-string (car entity) (cdr entity) text t t)))
    (setq text (string-trim (replace-regexp-in-string "[ \t\r\n]+" " " text t t)))
    (if (string-empty-p text) "-" text)))

(defun jenkins-browser--format-culprits (culprits)
  "Format the list of CULPRITS hash-tables as a comma-separated author string."
  (let ((names (when (listp culprits)
                 (delq nil (mapcar (lambda (c) (jenkins-browser--get "fullName" c))
                                   culprits)))))
    (if names (string-join names ", ") "-")))

(defun jenkins-browser--format-status (color building result)
  "Format build status with text properties.
COLOR is the Jenkins job color, BUILDING non-nil if running, RESULT the
build result string."
  (cond
   (building
    (propertize "RUNNING" 'face '(:foreground "deep sky blue" :weight bold)))
   ((equal result "SUCCESS")
    (propertize "SUCCESS" 'face '(:foreground "forest green" :weight bold)))
   ((equal result "UNSTABLE")
    (propertize "UNSTABLE" 'face '(:foreground "gold" :weight bold)))
   ((equal result "FAILURE")
    (propertize "FAILURE" 'face '(:foreground "red" :weight bold)))
   ((equal result "ABORTED")
    (propertize "ABORTED" 'face '(:foreground "dim gray")))
   ((and (stringp color) (string-match-p "\\`anime\\|_anime\\'" color))
    (propertize "RUNNING" 'face '(:foreground "deep sky blue" :weight bold)))
   (t
    (propertize (or result (and (stringp color) color) "NOT BUILT") 'face 'font-lock-comment-face))))

;;; --- Refresh handling ---

(defvar-local jenkins-browser--refresh-in-flight nil
  "Non-nil while a background refresh of this buffer is waiting for Jenkins.")

(defun jenkins-browser--apply-refresh (resp)
  "Replace the entries of the current buffer using the parsed response RESP."
  (setq tabulated-list-entries
        (if (derived-mode-p 'jenkins-browser-build-history-mode)
            (jenkins-browser--build-history-entries (jenkins-browser--builds-from-response resp))
          (jenkins-browser--build-job-entries (jenkins-browser--jobs-from-response resp))))
  (tabulated-list-print t))

(defun jenkins-browser--refresh-current ()
  "Refresh the current Jenkins buffer in the background, without blocking.
The request is sent asynchronously and the buffer is updated when the
answer arrives; a failure is reported with `message' and the old contents
are kept.  Do nothing if a refresh of this buffer is already under way."
  (let ((history (derived-mode-p 'jenkins-browser-build-history-mode)))
    (when (and (not jenkins-browser--refresh-in-flight)
               (or (not history) jenkins-browser--history-job))
      (let ((buf (current-buffer))
            (url (if history
                     (jenkins-browser--history-url jenkins-browser--history-job)
                   (jenkins-browser--jobs-url jenkins-browser--folder))))
        (setq jenkins-browser--refresh-in-flight t)
        (condition-case err
            (jenkins-browser--request-async
             url
             (lambda (resp error-message)
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (setq jenkins-browser--refresh-in-flight nil)
                   (if error-message
                       (message "jenkins-browser refresh failed: %s" error-message)
                     (jenkins-browser--apply-refresh resp))))))
          (error
           (setq jenkins-browser--refresh-in-flight nil)
           (signal (car err) (cdr err))))))))

(defun jenkins-browser--refresh-later ()
  "Refresh the current Jenkins buffer in a couple of seconds."
  (when (derived-mode-p 'jenkins-browser-mode 'jenkins-browser-build-history-mode)
    (let ((buf (current-buffer)))
      (run-at-time 2 nil
                   (lambda ()
                     (when (buffer-live-p buf)
                       (with-current-buffer buf
                         (condition-case err
                             (jenkins-browser--refresh-current)
                           (error (message "jenkins-browser refresh failed: %s"
                                           (error-message-string err)))))))))))

(defun jenkins-browser--timer-tick ()
  "Refresh all visible Jenkins buffers; stop the timer when none are left.
The refreshes run in the background, see `jenkins-browser--refresh-current'."
  (let (found)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (derived-mode-p 'jenkins-browser-mode 'jenkins-browser-build-history-mode)
          (setq found t)
          (when (get-buffer-window buf 'visible)
            (condition-case err
                (jenkins-browser--refresh-current)
              (error (message "jenkins-browser auto-refresh failed: %s"
                              (error-message-string err))))))))
    (unless found
      (jenkins-browser--stop-timer))))

(defun jenkins-browser--stop-timer ()
  "Cancel the auto-refresh timer."
  (when (timerp jenkins-browser--refresh-timer)
    (cancel-timer jenkins-browser--refresh-timer))
  (setq jenkins-browser--refresh-timer nil))

(defun jenkins-browser--ensure-timer ()
  "Start the auto-refresh timer if enabled and not already running."
  (when (and (integerp jenkins-browser-auto-refresh-interval)
             (> jenkins-browser-auto-refresh-interval 0)
             (not (timerp jenkins-browser--refresh-timer)))
    (setq jenkins-browser--refresh-timer
          (run-at-time jenkins-browser-auto-refresh-interval
                       jenkins-browser-auto-refresh-interval
                       #'jenkins-browser--timer-tick))))

;;; --- Tabulated List UI for Jobs ---

(defun jenkins-browser--job-entries ()
  "Fetch the jobs of the current folder and return their list entries."
  (jenkins-browser--build-job-entries (jenkins-browser--fetch-jobs jenkins-browser--folder)))

(defun jenkins-browser--build-job-entries (jobs)
  "Generate tabulated list entries from the job hash-tables JOBS.
Each entry id is a cons (NAME . FOLDER-P)."
  (let (entries)
    (dolist (job (if (listp jobs) jobs nil))
      (when (hash-table-p job)
        (let* ((name (jenkins-browser--get "name" job))
               (folder-p (jenkins-browser--folder-p job))
               (color (jenkins-browser--get "color" job))
               (last-build (jenkins-browser--get "lastBuild" job))
               (num (jenkins-browser--get "number" last-build))
               (building (jenkins-browser--get "building" last-build))
               (result (jenkins-browser--get "result" last-build))
               (duration (jenkins-browser--get "duration" last-build)))
          (when (and name
                     (or folder-p
                         (not jenkins-browser--filter-running-only)
                         building
                         (and (stringp color) (string-match-p "_anime$" color))))
            (push (list (cons name (and folder-p t))
                        (vector (propertize (if folder-p (concat name "/") name)
                                            'face (if folder-p
                                                      'font-lock-type-face
                                                    'font-lock-function-name-face))
                                (if folder-p
                                    (propertize "FOLDER" 'face 'font-lock-type-face)
                                  (jenkins-browser--format-status color building result))
                                (if num (format "#%s" num) "-")
                                (jenkins-browser--format-duration duration)))
                  entries)))))
    (nreverse entries)))

;;; --- Interactive Commands for Jobs ---

(defun jenkins-browser-refresh ()
  "Refresh the Jenkins jobs list."
  (interactive)
  (setq tabulated-list-entries (jenkins-browser--job-entries))
  (tabulated-list-print t))

(defun jenkins-browser-toggle-running-filter ()
  "Toggle between showing all jobs vs only running jobs.
Folders are always shown so that they can still be opened."
  (interactive)
  (setq jenkins-browser--filter-running-only (not jenkins-browser--filter-running-only))
  (message (if jenkins-browser--filter-running-only
               "Showing RUNNING jobs only"
             "Showing ALL jobs"))
  (jenkins-browser-refresh))

(defun jenkins-browser--job-names ()
  "Return full paths of the non-folder jobs in the current folder."
  (delq nil
        (mapcar (lambda (j)
                  (and (hash-table-p j)
                       (not (jenkins-browser--folder-p j))
                       (let ((name (jenkins-browser--get "name" j)))
                         (and name (jenkins-browser--join-path jenkins-browser--folder name)))))
                (jenkins-browser--fetch-jobs jenkins-browser--folder))))

(defun jenkins-browser--read-job (prompt)
  "Return the full path of the job at point, or ask for one using PROMPT.
Signal a `user-error' when point is on a folder."
  (let ((id (and (derived-mode-p 'jenkins-browser-mode) (tabulated-list-get-id))))
    (cond
     ((and (consp id) (cdr id))
      (user-error "'%s' is a folder; press RET to open it" (car id)))
     ((consp id)
      (jenkins-browser--join-path jenkins-browser--folder (car id)))
     (t
      (let ((job (completing-read prompt (jenkins-browser--job-names))))
        (if (string-empty-p job) (user-error "No job selected") job))))))

(defun jenkins-browser--open-buffer (name setup display)
  "Create or reuse the buffer NAME, run SETUP in it and show it with DISPLAY.
SETUP loads the buffer's contents.  If it signals an error and the buffer
was created by this call, kill the buffer so that no empty Jenkins buffer
is left behind, and re-signal.  A buffer that already existed is kept."
  (let* ((existing (get-buffer name))
         (buf (or existing (get-buffer-create name))))
    (condition-case err
        (with-current-buffer buf
          (funcall setup))
      (error
       (unless existing
         (kill-buffer buf))
       (signal (car err) (cdr err))))
    (funcall display buf)))

(defun jenkins-browser-open-folder (folder)
  "Open a jobs buffer listing the jobs in FOLDER (a slash-separated path)."
  (jenkins-browser--open-buffer
   (format "*Jenkins: %s*" folder)
   (lambda ()
     (jenkins-browser-mode)
     (setq jenkins-browser--folder folder)
     (jenkins-browser-refresh))
   #'pop-to-buffer-same-window))

(defun jenkins-browser-enter ()
  "Open the folder at point, or the build history of the job at point."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (unless (consp id)
      (user-error "No job selected"))
    (if (cdr id)
        (jenkins-browser-open-folder (jenkins-browser--join-path jenkins-browser--folder (car id)))
      (jenkins-browser-view-build-history (jenkins-browser--join-path jenkins-browser--folder (car id))))))

(defun jenkins-browser--boolean-parameter-p (param)
  "Return non-nil if the parameter definition hash-table PARAM is a boolean.
Jenkins expects the strings \"true\" and \"false\" for these, not Lisp values."
  (let ((class (or (jenkins-browser--get "_class" param) (jenkins-browser--get "type" param))))
    (and (stringp class)
         (string-match-p "BooleanParameterDefinition" class))))

(defun jenkins-browser--password-parameter-p (param)
  "Return non-nil if the parameter definition hash-table PARAM is a password."
  (let ((class (or (jenkins-browser--get "_class" param) (jenkins-browser--get "type" param))))
    (and (stringp class)
         (string-match-p "PasswordParameterDefinition" class))))

(defun jenkins-browser--extract-queue-item (headers)
  "Extract the queue item ID from HTTP response HEADERS, or nil."
  (let ((loc (cdr (assoc "location" headers))))
    (when (and (stringp loc)
               (string-match "/queue/item/\\([0-9]+\\)" loc))
      (match-string 1 loc))))

(defun jenkins-browser-trigger-job (job &optional override-defaults)
  "Interactively trigger JOB, prompting for parameters if defined.
OVERRIDE-DEFAULTS is an optional alist mapping parameter names to
default values (used when re-triggering builds).  JOB is a
slash-separated path such as \"folder/job\"."
  (interactive (list (jenkins-browser--read-job "Trigger Job: ")))
  (let* ((info (jenkins-browser--request "GET" (jenkins-browser--job-url job "/api/json")))
         (props (when (hash-table-p info) (jenkins-browser--get "property" info)))
         (props-list (if (listp props) props nil))
         (param-def-prop (cl-find-if (lambda (p)
                                       (and (hash-table-p p)
                                            (jenkins-browser--get "parameterDefinitions" p)))
                                     props-list))
         (param-defs (when param-def-prop (jenkins-browser--get "parameterDefinitions" param-def-prop)))
         (defs-list (if (listp param-defs) param-defs nil)))
    (if (null defs-list)
        ;; Simple non-parameterized trigger
        (let* ((resp (jenkins-browser--http-full "POST" (jenkins-browser--job-url job "/build")))
               (headers (and (consp resp) (cdr resp)))
               (queue-id (jenkins-browser--extract-queue-item headers)))
          (if queue-id
              (message "Triggered '%s' (queue item #%s)" job queue-id)
            (message "Triggered '%s'" job)))
      ;; Parameterized trigger
      (let (query-params)
        (dolist (p defs-list)
          (when (hash-table-p p)
            (let* ((p-name (jenkins-browser--get "name" p))
                   (p-desc (or (jenkins-browser--get "description" p) ""))
                   (default-obj (jenkins-browser--get "defaultParameterValue" p))
                   (override-val (when (and override-defaults p-name)
                                   (if (hash-table-p override-defaults)
                                       (gethash p-name override-defaults)
                                     (cdr (assoc p-name override-defaults)))))
                   (boolean-p (jenkins-browser--boolean-parameter-p p))
                   (password-p (jenkins-browser--password-parameter-p p))
                   (p-default (cond
                               ((and boolean-p override-val)
                                (if (member override-val '(t "true" "True" 1)) "true" "false"))
                               (override-val (format "%s" override-val))
                               (boolean-p
                                (if (and (hash-table-p default-obj)
                                         (jenkins-browser--get "value" default-obj))
                                    "true"
                                  "false"))
                               ((hash-table-p default-obj)
                                (let ((val (jenkins-browser--get "value" default-obj)))
                                  (when val (format "%s" val))))))
                   (choices (if boolean-p
                                '("true" "false")
                              (jenkins-browser--get "choices" p)))
                   (val (cond
                         ((and choices (listp choices))
                          (completing-read (format "%s (%s): " p-name p-desc) choices nil t p-default))
                         (password-p
                          (read-passwd (if (string-empty-p p-desc)
                                           (format "%s: " p-name)
                                         (format "%s (%s): " p-name p-desc))
                                       nil p-default))
                         (t
                          (read-string (format "%s [%s] (%s): " p-name (or p-default "") p-desc)
                                       nil nil p-default)))))
              (when p-name
                (push (format "%s=%s" (url-hexify-string p-name) (url-hexify-string (or val "")))
                      query-params)))))
        (let* ((post-data (string-join (nreverse query-params) "&"))
               (resp (jenkins-browser--http-full
                      "POST"
                      (jenkins-browser--job-url job "/buildWithParameters")
                      post-data
                      "application/x-www-form-urlencoded"))
               (headers (and (consp resp) (cdr resp)))
               (queue-id (jenkins-browser--extract-queue-item headers)))
          (if queue-id
              (message "Triggered '%s' with parameters (queue item #%s)" job queue-id)
            (message "Triggered '%s' with parameters." job)))))
    (jenkins-browser--refresh-later)))

(defcustom jenkins-browser-console-poll-interval 2
  "Seconds between requests for new output while following a running build."
  :type 'number
  :group 'jenkins-browser)

(defvar-local jenkins-browser--console-job nil
  "Slash-separated path of the job whose console this buffer shows.")

(defvar-local jenkins-browser--console-build nil
  "Number (as a string) of the build whose console this buffer shows.")

(defvar-local jenkins-browser--console-offset 0
  "Byte offset in the build log of the first byte not yet fetched.")

(defvar-local jenkins-browser--console-pending ""
  "Undecoded unfinished last line of the log, held back until it is complete.")

(defvar-local jenkins-browser--console-more-data nil
  "Non-nil if Jenkins said the build may still write more output.")

(defvar-local jenkins-browser--console-in-flight nil
  "Non-nil while a request for more output is waiting for Jenkins.")

(defvar-local jenkins-browser--console-timer nil
  "Timer polling for new output while following the build, or nil.")

(define-derived-mode jenkins-browser-console-mode special-mode "Jenkins-Console"
  "Major mode for viewing a Jenkins console log.
While the build is running the buffer follows it, fetching new output
every `jenkins-browser-console-poll-interval' seconds.

\\{jenkins-browser-console-mode-map}"
  (add-hook 'kill-buffer-hook #'jenkins-browser--console-stop-follow nil t))

(defconst jenkins-browser--console-note-regexp
  "\r\\|\e\\[8mha:[A-Za-z0-9+/=]*\e\\[0m"
  "Match what is removed from console text.
That is carriage returns and the hidden `ConsoleNote' annotations that
Jenkins mixes into the progressive log.")

(defun jenkins-browser--console-text (text)
  "Strip CR characters and Jenkins console annotations from console TEXT."
  (replace-regexp-in-string jenkins-browser--console-note-regexp "" text))

(defun jenkins-browser--console-split (bytes final)
  "Split the undecoded log text BYTES into (COMPLETE . REST).
COMPLETE ends at the last newline, so that no line, annotation or
multibyte character is cut in half.  REST is the unfinished last line,
to be put in front of the next chunk.  When FINAL is non-nil the log is
complete and REST is empty."
  (if final
      (cons bytes "")
    (let ((i (length bytes)))
      (while (and (> i 0) (/= (aref bytes (1- i)) ?\n))
        (setq i (1- i)))
      (cons (substring bytes 0 i) (substring bytes i)))))

(defun jenkins-browser--console-insert (bytes)
  "Append the undecoded log text BYTES to the current console buffer.
Windows and point that were at the end of the buffer stay there."
  (when (> (length bytes) 0)
    (let ((windows (cl-remove-if-not
                    (lambda (w) (= (window-point w) (point-max)))
                    (get-buffer-window-list (current-buffer) nil t)))
          (at-end (= (point) (point-max)))
          (inhibit-read-only t)
          (text (ansi-color-apply
                 (jenkins-browser--console-text
                  (jenkins-browser--decode bytes)))))
      (save-excursion
        (goto-char (point-max))
        (insert text))
      (when at-end
        (goto-char (point-max)))
      (dolist (w windows)
        (set-window-point w (point-max))))))

(defun jenkins-browser--console-url (job build offset)
  "Return the URL of the log of BUILD of JOB from byte OFFSET on."
  (jenkins-browser--job-url job (format "/%s/logText/progressiveText?start=%d"
					build offset)))

(defun jenkins-browser--console-apply (body headers)
  "Add the undecoded log chunk BODY, with response HEADERS, to the buffer.
Move the fetch offset on and remember whether the build is still running.
Stop following when Jenkins reports that there is no more data."
  (let* ((size (cdr (assoc "x-text-size" headers)))
         (more (equal (cdr (assoc "x-more-data" headers)) "true"))
         (split (jenkins-browser--console-split (concat jenkins-browser--console-pending body)
						(not more))))
    (setq jenkins-browser--console-offset (if size
					      (string-to-number size)
					    (+ jenkins-browser--console-offset (length body)))
          jenkins-browser--console-pending (cdr split)
          jenkins-browser--console-more-data more)
    (jenkins-browser--console-insert (car split))
    (unless more
      (jenkins-browser--console-stop-follow))))

(defun jenkins-browser--console-fetch ()
  "Fetch the next part of the log of the current console buffer.
The request is sent in the background.  Do nothing if one is already
under way.  On failure, report it and stop following."
  (unless jenkins-browser--console-in-flight
    (let* ((buf (current-buffer))
           (offset jenkins-browser--console-offset)
           (url (jenkins-browser--console-url jenkins-browser--console-job
					      jenkins-browser--console-build offset)))
      (setq jenkins-browser--console-in-flight t)
      (condition-case err
          (jenkins-browser--request-async
           url
           (lambda (resp error-message)
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (setq jenkins-browser--console-in-flight nil)
                 (cond
                  (error-message
                   (jenkins-browser--console-stop-follow)
                   (message "jenkins-browser console: %s; press f to resume following"
                            error-message))
                  ;; The buffer was reloaded while this request was away.
                  ((/= offset jenkins-browser--console-offset))
                  (t (jenkins-browser--console-apply (plist-get resp :body)
						     (plist-get resp :headers)))))))
           t)
        (error
         (setq jenkins-browser--console-in-flight nil)
         (signal (car err) (cdr err)))))))

(defun jenkins-browser--console-start-follow ()
  "Start polling for new output in the current console buffer."
  (unless (timerp jenkins-browser--console-timer)
    (let* ((buf (current-buffer))
           (interval jenkins-browser-console-poll-interval)
           timer)
      (setq timer
            (run-at-time
             interval interval
             (lambda ()
               (if (and (buffer-live-p buf)
                        (eq (buffer-local-value 'jenkins-browser--console-timer buf)
                            timer))
                   (with-current-buffer buf
                     (jenkins-browser--console-fetch))
                 (cancel-timer timer)))))
      (setq jenkins-browser--console-timer timer
            mode-line-process " follow")
      (force-mode-line-update))))

(defun jenkins-browser--console-stop-follow ()
  "Stop polling for new output in the current console buffer."
  (when (timerp jenkins-browser--console-timer)
    (cancel-timer jenkins-browser--console-timer))
  (setq jenkins-browser--console-timer nil
        mode-line-process nil)
  (force-mode-line-update))

(defun jenkins-browser-console-refresh ()
  "Fetch any new output of the build shown in this console buffer."
  (interactive)
  (if jenkins-browser--console-more-data
      (jenkins-browser--console-fetch)
    (message "The build has finished; there is no more output")))

(defun jenkins-browser-console-toggle-follow ()
  "Start or stop following the build shown in this console buffer."
  (interactive)
  (cond
   ((timerp jenkins-browser--console-timer)
    (jenkins-browser--console-stop-follow)
    (message "Stopped following the build"))
   ((not jenkins-browser--console-more-data)
    (message "The build has finished; there is nothing to follow"))
   (t
    (jenkins-browser--console-start-follow)
    (jenkins-browser--console-fetch)
    (message "Following the build"))))

(define-key jenkins-browser-console-mode-map (kbd "g") #'jenkins-browser-console-refresh)
(define-key jenkins-browser-console-mode-map (kbd "f") #'jenkins-browser-console-toggle-follow)

(defun jenkins-browser--resolve-build (job build-id)
  "Return the number, as a string, of the build BUILD-ID of JOB.
BUILD-ID may be \"lastBuild\", which moves on when a new build starts."
  (if (string-match-p "\\`[0-9]+\\'" build-id)
      build-id
    (let* ((info (jenkins-browser--request
                  "GET" (jenkins-browser--job-url
                         job (format "/%s/api/json?tree=number" build-id))))
           (number (jenkins-browser--get "number" info)))
      (unless number
        (error "Jenkins has no %s for %s" build-id job))
      (format "%s" number))))

(defun jenkins-browser-view-console (job &optional build-number)
  "View the console log for BUILD-NUMBER (default \"lastBuild\") of JOB.
If the build is still running the buffer follows it, see
`jenkins-browser-console-toggle-follow'."
  (interactive (list (jenkins-browser--read-job "Console for job: ")))
  (let ((build-id (or (and build-number (format "%s" build-number)) "lastBuild")))
    (jenkins-browser--open-buffer
     (format "*Jenkins-Console: %s #%s*" job build-id)
     (lambda ()
       (jenkins-browser--console-stop-follow)
       (let ((build (jenkins-browser--resolve-build job build-id)))
         (let ((resp (jenkins-browser--http-full
                      "GET" (jenkins-browser--console-url job build 0) nil nil t)))
           (jenkins-browser-console-mode)
           (setq jenkins-browser--console-job job
                 jenkins-browser--console-build build)
           (let ((inhibit-read-only t))
             (erase-buffer))
           (jenkins-browser--console-apply (car resp) (cdr resp))
           (goto-char (point-max))
           (when jenkins-browser--console-more-data
             (jenkins-browser--console-start-follow)))))
     #'pop-to-buffer)))

(defun jenkins-browser-abort-build (job)
  "Abort the running build for JOB."
  (interactive (list (jenkins-browser--read-job "Abort job: ")))
  (when (yes-or-no-p (format "Abort active build for %s? " job))
    (jenkins-browser--request "POST" (jenkins-browser--job-url job "/lastBuild/stop"))
    (message "Requested abort for %s" job)
    (jenkins-browser--refresh-later)))

(defun jenkins-browser-open-in-browser (job)
  "Open JOB in external web browser."
  (interactive (list (jenkins-browser--read-job "Open job: ")))
  (browse-url (jenkins-browser--job-url job)))

;;; --- Build History Mode ---

(defun jenkins-browser--history-url (job)
  "Return the API URL listing the recent builds of JOB."
  (let ((tree (format "builds[number,result,building,duration,timestamp,displayName,description,culprits[fullName]]{0,%d}"
                      jenkins-browser-history-limit)))
    (jenkins-browser--job-url job (format "/api/json?tree=%s" (url-hexify-string tree)))))

(defun jenkins-browser--builds-from-response (resp)
  "Return the list of build hash-tables in the parsed history response RESP."
  (when (hash-table-p resp)
    (jenkins-browser--get "builds" resp)))

(defun jenkins-browser--fetch-build-history (job)
  "Fetch builds list for JOB."
  (jenkins-browser--builds-from-response
   (jenkins-browser--request "GET" (jenkins-browser--history-url job))))

(defun jenkins-browser--history-entries (job)
  "Fetch the builds of JOB and return their list entries."
  (jenkins-browser--build-history-entries (jenkins-browser--fetch-build-history job)))

(defun jenkins-browser--build-history-entries (builds)
  "Generate tabulated list entries from the build hash-tables BUILDS."
  (let (entries)
    (dolist (b (if (listp builds) builds nil))
      (when (hash-table-p b)
        (let* ((num (jenkins-browser--get "number" b))
               (display-name (jenkins-browser--get "displayName" b))
               (result (jenkins-browser--get "result" b))
               (building (jenkins-browser--get "building" b))
               (duration (jenkins-browser--get "duration" b))
               (timestamp (jenkins-browser--get "timestamp" b))
               (status-str (jenkins-browser--format-status nil building result))
               (build-label (if (and (stringp display-name)
                                     (not (string-empty-p display-name)))
                                display-name
                              (if num (format "#%d" num) "-"))))
          (when num
            (push (list num
                        (vector (propertize build-label 'face 'font-lock-keyword-face)
                                status-str
                                (jenkins-browser--format-timestamp timestamp)
                                (jenkins-browser--format-culprits (jenkins-browser--get "culprits" b))
                                (jenkins-browser--format-duration duration)
                                (jenkins-browser--format-description (jenkins-browser--get "description" b))))
                  entries)))))
    (nreverse entries)))

(defun jenkins-browser-history-refresh ()
  "Refresh the current build history buffer."
  (interactive)
  (when jenkins-browser--history-job
    (setq tabulated-list-entries (jenkins-browser--history-entries jenkins-browser--history-job))
    (tabulated-list-print t)))

(defun jenkins-browser-current-build-number ()
  "Get the build number at point in a build history buffer."
  (tabulated-list-get-id))

(defun jenkins-browser-history-view-console (&optional build-num)
  "View console output for BUILD-NUM of the current job."
  (interactive (list (or (jenkins-browser-current-build-number) (user-error "No build selected"))))
  (unless (and jenkins-browser--history-job build-num)
    (user-error "Cannot view console: missing job or build number"))
  (jenkins-browser-view-console jenkins-browser--history-job build-num))

(defun jenkins-browser-history-abort-build (&optional build-num)
  "Abort BUILD-NUM for the current job."
  (interactive (list (or (jenkins-browser-current-build-number) (user-error "No build selected"))))
  (unless (and jenkins-browser--history-job build-num)
    (user-error "Cannot abort: missing job or build number"))
  (when (yes-or-no-p (format "Abort %s #%s? " jenkins-browser--history-job build-num))
    (jenkins-browser--request "POST" (jenkins-browser--job-url jenkins-browser--history-job (format "/%s/stop" build-num)))
    (message "Requested abort for %s #%s" jenkins-browser--history-job build-num)
    (jenkins-browser--refresh-later)))

(defun jenkins-browser-history-rebuild (&optional build-num)
  "Re-trigger the current job with parameters from BUILD-NUM pre-filled."
  (interactive (list (or (jenkins-browser-current-build-number) (user-error "No build selected"))))
  (unless (and jenkins-browser--history-job build-num)
    (user-error "Cannot rebuild: missing job or build number"))
  (let* ((info (jenkins-browser--request
                "GET"
                (jenkins-browser--job-url
                 jenkins-browser--history-job
                 (format "/%s/api/json?tree=actions[parameters[name,value]]" build-num))))
         (actions (and (hash-table-p info) (jenkins-browser--get "actions" info)))
         (params-action (cl-find-if (lambda (a)
                                      (and (hash-table-p a)
                                           (jenkins-browser--get "parameters" a)))
                                    (if (listp actions) actions nil)))
         (params-list (and params-action (jenkins-browser--get "parameters" params-action)))
         (defaults (when (listp params-list)
                     (delq nil
                           (mapcar (lambda (p)
                                     (when (hash-table-p p)
                                       (let ((n (jenkins-browser--get "name" p))
                                             (v (jenkins-browser--get "value" p)))
                                         (when n (cons n v)))))
                                   params-list)))))
    (jenkins-browser-trigger-job jenkins-browser--history-job defaults)))

(defun jenkins-browser-history-open-in-browser (&optional build-num)
  "Open BUILD-NUM in external browser."
  (interactive (list (or (jenkins-browser-current-build-number) (user-error "No build selected"))))
  (browse-url (jenkins-browser--job-url jenkins-browser--history-job (format "/%s" (or build-num "")))))

(defun jenkins-browser-view-build-history (&optional job)
  "View the build history for JOB (a slash-separated path)."
  (interactive (list (jenkins-browser--read-job "Job: ")))
  (unless job
    (user-error "No job selected"))
  (jenkins-browser--open-buffer
   (format "*Jenkins-History: %s*" job)
   (lambda ()
     (jenkins-browser-build-history-mode)
     (setq jenkins-browser--history-job job)
     (jenkins-browser-history-refresh))
   #'pop-to-buffer))

;;; --- Mode Definitions and Keymaps ---

(defvar jenkins-browser-build-history-mode-map (make-sparse-keymap)
  "Keymap for `jenkins-browser-build-history-mode` buffers.")
(set-keymap-parent jenkins-browser-build-history-mode-map tabulated-list-mode-map)
(define-key jenkins-browser-build-history-mode-map (kbd "g")   #'jenkins-browser-history-refresh)
(define-key jenkins-browser-build-history-mode-map (kbd "RET") #'jenkins-browser-history-view-console)
(define-key jenkins-browser-build-history-mode-map [return]    #'jenkins-browser-history-view-console)
(define-key jenkins-browser-build-history-mode-map (kbd "c")   #'jenkins-browser-history-view-console)
(define-key jenkins-browser-build-history-mode-map (kbd "k")   #'jenkins-browser-history-abort-build)
(define-key jenkins-browser-build-history-mode-map (kbd "R")   #'jenkins-browser-history-rebuild)
(define-key jenkins-browser-build-history-mode-map (kbd "s")   #'jenkins-browser-history-view-stages)
(define-key jenkins-browser-build-history-mode-map (kbd "a")   #'jenkins-browser-history-view-artifacts)
(define-key jenkins-browser-build-history-mode-map (kbd "Q")   #'jenkins-browser-queue)
(define-key jenkins-browser-build-history-mode-map (kbd "o")   #'jenkins-browser-history-open-in-browser)

(define-derived-mode jenkins-browser-build-history-mode tabulated-list-mode "Jenkins-History"
  "Major mode for browsing Jenkins build history.

\\{jenkins-browser-build-history-mode-map}"
  :keymap jenkins-browser-build-history-mode-map
  (setq tabulated-list-format
        [("Build"     10 t)
         ("Status"    12 t)
         ("Timestamp" 18 t)
         ("Author"    24 nil)
         ("Duration"  12 nil)
         ("Description" 0 nil)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Build" t))
  (add-hook 'tabulated-list-revert-hook #'jenkins-browser-history-refresh nil t)
  (hl-line-mode 1)
  (tabulated-list-init-header)
  (jenkins-browser--ensure-timer))

(defvar jenkins-browser-mode-map (make-sparse-keymap)
  "Keymap for `jenkins-browser-mode` buffers.")
(set-keymap-parent jenkins-browser-mode-map tabulated-list-mode-map)
(define-key jenkins-browser-mode-map (kbd "g")   #'jenkins-browser-refresh)
(define-key jenkins-browser-mode-map (kbd "b")   #'jenkins-browser-trigger-job)
(define-key jenkins-browser-mode-map (kbd "RET") #'jenkins-browser-enter)
(define-key jenkins-browser-mode-map [return]    #'jenkins-browser-enter)
(define-key jenkins-browser-mode-map (kbd "h")   #'jenkins-browser-view-build-history)
(define-key jenkins-browser-mode-map (kbd "c")   #'jenkins-browser-view-console)
(define-key jenkins-browser-mode-map (kbd "k")   #'jenkins-browser-abort-build)
(define-key jenkins-browser-mode-map (kbd "s")   #'jenkins-browser-view-stages)
(define-key jenkins-browser-mode-map (kbd "a")   #'jenkins-browser-view-artifacts)
(define-key jenkins-browser-mode-map (kbd "Q")   #'jenkins-browser-queue)
(define-key jenkins-browser-mode-map (kbd "f")   #'jenkins-browser-toggle-running-filter)
(define-key jenkins-browser-mode-map (kbd "o")   #'jenkins-browser-open-in-browser)

(define-derived-mode jenkins-browser-mode tabulated-list-mode "Jenkins"
  "Major mode for browsing and triggering Jenkins jobs.

\\{jenkins-browser-mode-map}"
  :keymap jenkins-browser-mode-map
  (setq tabulated-list-format
        [("Job Name" 40 t)
         ("Status"   12 t)
         ("Last #"   8  nil)
         ("Duration" 12 nil)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Job Name" nil))
  (add-hook 'tabulated-list-revert-hook #'jenkins-browser-refresh nil t)
  (hl-line-mode 1)
  (tabulated-list-init-header)
  (jenkins-browser--ensure-timer))

;;; --- Build Queue Mode ---

(defvar jenkins-browser-queue-mode-map (make-sparse-keymap)
  "Keymap for `jenkins-browser-queue-mode` buffers.")
(set-keymap-parent jenkins-browser-queue-mode-map tabulated-list-mode-map)
(define-key jenkins-browser-queue-mode-map (kbd "g")   #'jenkins-browser-queue-refresh)
(define-key jenkins-browser-queue-mode-map (kbd "k")   #'jenkins-browser-queue-cancel-item)
(define-key jenkins-browser-queue-mode-map (kbd "d")   #'jenkins-browser-queue-cancel-item)
(define-key jenkins-browser-queue-mode-map (kbd "RET") #'jenkins-browser-queue-open-task)
(define-key jenkins-browser-queue-mode-map [return]    #'jenkins-browser-queue-open-task)
(define-key jenkins-browser-queue-mode-map (kbd "h")   #'jenkins-browser-queue-open-task)
(define-key jenkins-browser-queue-mode-map (kbd "o")   #'jenkins-browser-queue-open-in-browser)

(define-derived-mode jenkins-browser-queue-mode tabulated-list-mode "Jenkins-Queue"
  "Major mode for browsing the Jenkins build queue.

\\{jenkins-browser-queue-mode-map}"
  :keymap jenkins-browser-queue-mode-map
  (setq tabulated-list-format
        [("ID"       8 t)
         ("Task"    35 t)
         ("Reason"  45 nil)
         ("In Queue" 14 nil)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "ID" nil))
  (add-hook 'tabulated-list-revert-hook #'jenkins-browser-queue-refresh nil t)
  (hl-line-mode 1)
  (tabulated-list-init-header))

(defun jenkins-browser--queue-url ()
  "Return the API URL listing queue items."
  (concat (jenkins-browser-base-url)
          "/queue/api/json?tree="
          (url-hexify-string "items[id,why,blocked,buildable,stuck,inQueueSince,task[name,url,_class]]")))

(defun jenkins-browser--fetch-queue ()
  "Fetch queue items from Jenkins."
  (let ((resp (jenkins-browser--request "GET" (jenkins-browser--queue-url))))
    (when (hash-table-p resp)
      (jenkins-browser--get "items" resp))))

(defun jenkins-browser--format-in-queue (since-millis)
  "Format SINCE-MILLIS epoch timestamp as elapsed time in queue."
  (if (or (null since-millis) (not (numberp since-millis)) (<= since-millis 0))
      "-"
    (let* ((now (* 1000.0 (float-time)))
           (elapsed (max 0 (- now since-millis))))
      (jenkins-browser--format-duration elapsed))))

(defun jenkins-browser--queue-entries (items)
  "Generate tabulated list entries from queue ITEMS."
  (let (entries)
    (dolist (item (if (listp items) items nil))
      (when (hash-table-p item)
        (let* ((id (jenkins-browser--get "id" item))
               (why (or (jenkins-browser--get "why" item) "-"))
               (task (jenkins-browser--get "task" item))
               (task-name (if (hash-table-p task)
                              (or (jenkins-browser--get "name" task) "Unknown")
                            "Unknown"))
               (since (jenkins-browser--get "inQueueSince" item))
               (blocked (jenkins-browser--get "blocked" item))
               (stuck (jenkins-browser--get "stuck" item))
               (reason-str (cond
                            (stuck (concat "[STUCK] " why))
                            (blocked (concat "[BLOCKED] " why))
                            (t why))))
          (when id
            (push (list id
                        (vector (propertize (format "%s" id) 'face 'font-lock-keyword-face)
                                (propertize task-name 'face 'font-lock-function-name-face)
                                (jenkins-browser--format-description reason-str)
                                (jenkins-browser--format-in-queue since)))
                  entries)))))
    (nreverse entries)))

(defun jenkins-browser-queue-refresh ()
  "Refresh the build queue buffer."
  (interactive)
  (let ((items (jenkins-browser--fetch-queue)))
    (setq tabulated-list-entries (jenkins-browser--queue-entries items))
    (tabulated-list-print t)))

(defun jenkins-browser-queue-cancel-item ()
  "Cancel the queue item at point."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (unless id
      (user-error "No queue item selected"))
    (when (yes-or-no-p (format "Cancel queue item #%s? " id))
      (jenkins-browser--http-full "POST" (concat (jenkins-browser-base-url)
                                                 "/queue/cancelItem?id="
                                                 (url-hexify-string (format "%s" id))))
      (message "Cancelled queue item #%s" id)
      (jenkins-browser-queue-refresh))))

(defun jenkins-browser-queue-open-task ()
  "Open build history for the task at point in the queue."
  (interactive)
  (let* ((id (tabulated-list-get-id))
         (entry (and id (cl-find-if (lambda (e) (equal (car e) id)) tabulated-list-entries)))
         (task-name (and entry (aref (cadr entry) 1))))
    (if (and task-name (not (string-empty-p task-name)))
        (jenkins-browser-view-build-history task-name)
      (user-error "Cannot find task name for queue item"))))

(defun jenkins-browser-queue-open-in-browser ()
  "Open the queue item or task in the web browser."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (if id
        (browse-url (concat (jenkins-browser-base-url) "/queue/item/" (format "%s" id)))
      (browse-url (concat (jenkins-browser-base-url) "/queue/")))))

;;;###autoload
(defun jenkins-browser-queue ()
  "Open the Jenkins build queue viewer."
  (interactive)
  (jenkins-browser--open-buffer
   "*Jenkins-Queue*"
   (lambda ()
     (jenkins-browser-queue-mode)
     (jenkins-browser-queue-refresh))
   #'pop-to-buffer))

;;; --- Pipeline Stages Mode ---

(defvar-local jenkins-browser--stages-job nil
  "Job path for the current stages buffer.")

(defvar-local jenkins-browser--stages-build nil
  "Build number for the current stages buffer.")

(defvar jenkins-browser-stages-mode-map (make-sparse-keymap)
  "Keymap for `jenkins-browser-stages-mode` buffers.")
(set-keymap-parent jenkins-browser-stages-mode-map tabulated-list-mode-map)
(define-key jenkins-browser-stages-mode-map (kbd "g")   #'jenkins-browser-stages-refresh)
(define-key jenkins-browser-stages-mode-map (kbd "RET") #'jenkins-browser-stages-view-console)
(define-key jenkins-browser-stages-mode-map [return]    #'jenkins-browser-stages-view-console)
(define-key jenkins-browser-stages-mode-map (kbd "c")   #'jenkins-browser-stages-view-console)
(define-key jenkins-browser-stages-mode-map (kbd "l")   #'jenkins-browser-stages-view-stage-log)
(define-key jenkins-browser-stages-mode-map (kbd "o")   #'jenkins-browser-stages-open-in-browser)

(define-derived-mode jenkins-browser-stages-mode tabulated-list-mode "Jenkins-Stages"
  "Major mode for viewing Pipeline stages.

\\{jenkins-browser-stages-mode-map}"
  :keymap jenkins-browser-stages-mode-map
  (setq tabulated-list-format
        [("Stage"     32 t)
         ("Status"    14 t)
         ("Duration"  12 nil)
         ("Started"   18 nil)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Stage" nil))
  (add-hook 'tabulated-list-revert-hook #'jenkins-browser-stages-refresh nil t)
  (hl-line-mode 1)
  (tabulated-list-init-header))

(defun jenkins-browser--fetch-stages (job build-num)
  "Fetch pipeline stage descriptions for BUILD-NUM of JOB via wfapi."
  (let* ((url (jenkins-browser--job-url job (format "/%s/wfapi/describe" build-num)))
         (resp (condition-case nil
                   (jenkins-browser--request "GET" url)
                 (error nil))))
    (when (hash-table-p resp)
      (jenkins-browser--get "stages" resp))))

(defun jenkins-browser--stages-entries (stages)
  "Generate tabulated list entries from STAGES list."
  (let (entries)
    (dolist (st (if (listp stages) stages nil))
      (when (hash-table-p st)
        (let* ((id (jenkins-browser--get "id" st))
               (name (or (jenkins-browser--get "name" st) "Unknown"))
               (status (or (jenkins-browser--get "status" st) "UNKNOWN"))
               (duration (jenkins-browser--get "durationMillis" st))
               (start (jenkins-browser--get "startTimeMillis" st))
               (status-prop (cond
                             ((equal status "SUCCESS")
                              (propertize "SUCCESS" 'face '(:foreground "forest green" :weight bold)))
                             ((member status '("IN_PROGRESS" "EXECUTING"))
                              (propertize "RUNNING" 'face '(:foreground "deep sky blue" :weight bold)))
                             ((equal status "FAILED")
                              (propertize "FAILED" 'face '(:foreground "red" :weight bold)))
                             ((equal status "PAUSED_PENDING_INPUT")
                              (propertize "PAUSED" 'face '(:foreground "gold" :weight bold)))
                             ((equal status "ABORTED")
                              (propertize "ABORTED" 'face '(:foreground "dim gray")))
                             (t
                              (propertize status 'face 'font-lock-comment-face)))))
          (when id
            (push (list id
                        (vector (propertize name 'face 'font-lock-function-name-face)
                                status-prop
                                (jenkins-browser--format-duration duration)
                                (jenkins-browser--format-timestamp start)))
                  entries)))))
    (nreverse entries)))

(defun jenkins-browser-stages-refresh ()
  "Refresh the pipeline stages buffer."
  (interactive)
  (when (and jenkins-browser--stages-job jenkins-browser--stages-build)
    (let ((stages (jenkins-browser--fetch-stages
                   jenkins-browser--stages-job
                   jenkins-browser--stages-build)))
      (setq tabulated-list-entries (jenkins-browser--stages-entries stages))
      (tabulated-list-print t))))

(defun jenkins-browser-stages-view-console ()
  "View full console for the current build."
  (interactive)
  (when (and jenkins-browser--stages-job jenkins-browser--stages-build)
    (jenkins-browser-view-console jenkins-browser--stages-job jenkins-browser--stages-build)))

(defun jenkins-browser-stages-view-stage-log ()
  "View the log for the stage at point."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (unless id
      (user-error "No stage selected"))
    (let* ((url (jenkins-browser--job-url
                 jenkins-browser--stages-job
                 (format "/%s/execution/node/%s/wfapi/log"
                         jenkins-browser--stages-build id)))
           (resp (jenkins-browser--request "GET" url))
           (text (if (hash-table-p resp) (jenkins-browser--get "text" resp) nil)))
      (if (and (stringp text) (not (string-empty-p text)))
          (jenkins-browser--open-buffer
           (format "*Jenkins-Stage-Log: %s #%s (%s)*"
                   jenkins-browser--stages-job jenkins-browser--stages-build id)
           (lambda ()
             (jenkins-browser-console-mode)
             (let ((inhibit-read-only t))
               (erase-buffer)
               (insert (ansi-color-apply (jenkins-browser--console-text text)))
               (goto-char (point-min))))
           #'pop-to-buffer)
        (message "No specific log for stage '%s'" id)))))

(defun jenkins-browser-stages-open-in-browser ()
  "Open the pipeline run in the web browser."
  (interactive)
  (when (and jenkins-browser--stages-job jenkins-browser--stages-build)
    (browse-url (jenkins-browser--job-url
                 jenkins-browser--stages-job
                 (format "/%s" jenkins-browser--stages-build)))))

(defun jenkins-browser-history-view-stages (&optional build-num)
  "View pipeline stages for BUILD-NUM of the current job."
  (interactive (list (or (jenkins-browser-current-build-number) (user-error "No build selected"))))
  (unless (and jenkins-browser--history-job build-num)
    (user-error "Cannot view stages: missing job or build number"))
  (jenkins-browser-view-stages jenkins-browser--history-job build-num))

(defun jenkins-browser-view-stages (job &optional build-number)
  "View pipeline stages for BUILD-NUMBER (default \"lastBuild\") of JOB."
  (interactive (list (jenkins-browser--read-job "Stages for job: ")))
  (let* ((build-id (or (and build-number (format "%s" build-number)) "lastBuild"))
         (build (jenkins-browser--resolve-build job build-id)))
    (jenkins-browser--open-buffer
     (format "*Jenkins-Stages: %s #%s*" job build)
     (lambda ()
       (jenkins-browser-stages-mode)
       (setq jenkins-browser--stages-job job
             jenkins-browser--stages-build build)
       (jenkins-browser-stages-refresh))
     #'pop-to-buffer)))

;;; --- Build Artifacts Mode ---

(defvar-local jenkins-browser--artifacts-job nil
  "Job path for the current artifacts buffer.")

(defvar-local jenkins-browser--artifacts-build nil
  "Build number for the current artifacts buffer.")

(defvar jenkins-browser-artifacts-mode-map (make-sparse-keymap)
  "Keymap for `jenkins-browser-artifacts-mode` buffers.")
(set-keymap-parent jenkins-browser-artifacts-mode-map tabulated-list-mode-map)
(define-key jenkins-browser-artifacts-mode-map (kbd "g")   #'jenkins-browser-artifacts-refresh)
(define-key jenkins-browser-artifacts-mode-map (kbd "RET") #'jenkins-browser-artifacts-view-file)
(define-key jenkins-browser-artifacts-mode-map [return]    #'jenkins-browser-artifacts-view-file)
(define-key jenkins-browser-artifacts-mode-map (kbd "v")   #'jenkins-browser-artifacts-view-file)
(define-key jenkins-browser-artifacts-mode-map (kbd "d")   #'jenkins-browser-artifacts-download-file)
(define-key jenkins-browser-artifacts-mode-map (kbd "o")   #'jenkins-browser-artifacts-open-in-browser)

(define-derived-mode jenkins-browser-artifacts-mode tabulated-list-mode "Jenkins-Artifacts"
  "Major mode for browsing artifacts of a Jenkins build.

\\{jenkins-browser-artifacts-mode-map}"
  :keymap jenkins-browser-artifacts-mode-map
  (setq tabulated-list-format
        [("File Name"     35 t)
         ("Relative Path"  0 nil)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "File Name" nil))
  (add-hook 'tabulated-list-revert-hook #'jenkins-browser-artifacts-refresh nil t)
  (hl-line-mode 1)
  (tabulated-list-init-header))

(defun jenkins-browser--fetch-artifacts (job build-num)
  "Fetch artifacts list for BUILD-NUM of JOB."
  (let* ((tree (url-hexify-string "artifacts[displayPath,fileName,relativePath]"))
         (url (jenkins-browser--job-url job (format "/%s/api/json?tree=%s" build-num tree)))
         (resp (jenkins-browser--request "GET" url)))
    (when (hash-table-p resp)
      (jenkins-browser--get "artifacts" resp))))

(defun jenkins-browser--artifacts-entries (artifacts)
  "Generate tabulated list entries from ARTIFACTS list."
  (let (entries)
    (dolist (art (if (listp artifacts) artifacts nil))
      (when (hash-table-p art)
        (let ((name (or (jenkins-browser--get "fileName" art)
                        (jenkins-browser--get "displayPath" art)
                        "file"))
              (path (jenkins-browser--get "relativePath" art)))
          (when path
            (push (list path
                        (vector (propertize name 'face 'font-lock-keyword-face)
                                (propertize path 'face 'font-lock-type-face)))
                  entries)))))
    (nreverse entries)))

(defun jenkins-browser-artifacts-refresh ()
  "Refresh the artifacts buffer."
  (interactive)
  (when (and jenkins-browser--artifacts-job jenkins-browser--artifacts-build)
    (let ((artifacts (jenkins-browser--fetch-artifacts
                      jenkins-browser--artifacts-job
                      jenkins-browser--artifacts-build)))
      (setq tabulated-list-entries (jenkins-browser--artifacts-entries artifacts))
      (tabulated-list-print t))))

(defun jenkins-browser-artifacts-view-file ()
  "View the artifact at point in an Emacs buffer."
  (interactive)
  (let ((rel-path (tabulated-list-get-id)))
    (unless rel-path
      (user-error "No artifact selected"))
    (let* ((url (jenkins-browser--job-url
                 jenkins-browser--artifacts-job
                 (format "/%s/artifact/%s"
                         jenkins-browser--artifacts-build
                         (url-hexify-string rel-path))))
           (raw-body (jenkins-browser--http "GET" url)))
      (jenkins-browser--open-buffer
       (format "*Jenkins-Artifact: %s*" (file-name-nondirectory rel-path))
       (lambda ()
         (let ((inhibit-read-only t))
           (erase-buffer)
           (insert raw-body)
           (goto-char (point-min))
           (set-buffer-modified-p nil)
           (view-mode 1)))
       #'pop-to-buffer))))

(defun jenkins-browser-artifacts-download-file (dest-path)
  "Download the artifact at point to DEST-PATH."
  (interactive
   (let* ((rel-path (tabulated-list-get-id))
          (fname (if rel-path (file-name-nondirectory rel-path) "artifact")))
     (list (read-file-name "Save artifact as: " default-directory nil nil fname))))
  (let ((rel-path (tabulated-list-get-id)))
    (unless rel-path
      (user-error "No artifact selected"))
    (let* ((url (jenkins-browser--job-url
                 jenkins-browser--artifacts-job
                 (format "/%s/artifact/%s"
                         jenkins-browser--artifacts-build
                         (url-hexify-string rel-path))))
           (raw-bytes (car (jenkins-browser--http-full "GET" url nil nil t))))
      (with-temp-file dest-path
        (set-buffer-multibyte nil)
        (insert raw-bytes))
      (message "Saved %s to %s" rel-path dest-path))))

(defun jenkins-browser-artifacts-open-in-browser ()
  "Open the artifact at point in the web browser."
  (interactive)
  (let ((rel-path (tabulated-list-get-id)))
    (unless rel-path
      (user-error "No artifact selected"))
    (browse-url (jenkins-browser--job-url
                 jenkins-browser--artifacts-job
                 (format "/%s/artifact/%s"
                         jenkins-browser--artifacts-build
                         (url-hexify-string rel-path))))))

(defun jenkins-browser-history-view-artifacts (&optional build-num)
  "View artifacts for BUILD-NUM of the current job."
  (interactive (list (or (jenkins-browser-current-build-number) (user-error "No build selected"))))
  (unless (and jenkins-browser--history-job build-num)
    (user-error "Cannot view artifacts: missing job or build number"))
  (jenkins-browser-view-artifacts jenkins-browser--history-job build-num))

(defun jenkins-browser-view-artifacts (job &optional build-number)
  "View artifacts for BUILD-NUMBER (default \"lastBuild\") of JOB."
  (interactive (list (jenkins-browser--read-job "Artifacts for job: ")))
  (let* ((build-id (or (and build-number (format "%s" build-number)) "lastBuild"))
         (build (jenkins-browser--resolve-build job build-id)))
    (jenkins-browser--open-buffer
     (format "*Jenkins-Artifacts: %s #%s*" job build)
     (lambda ()
       (jenkins-browser-artifacts-mode)
       (setq jenkins-browser--artifacts-job job
             jenkins-browser--artifacts-build build)
       (jenkins-browser-artifacts-refresh))
     #'pop-to-buffer)))

;;;###autoload
(defun jenkins-browser ()
  "Open the Jenkins jobs overview buffer."
  (interactive)
  (jenkins-browser--open-buffer
   "*Jenkins*"
   (lambda ()
     (jenkins-browser-mode)
     (jenkins-browser-refresh))
   #'pop-to-buffer))

;;;###autoload
(defun jenkins-browser-reload ()
  "Force reload `jenkins-browser' and re-initialize the root Jenkins buffer."
  (interactive)
  (load-file (find-library-name "jenkins-browser"))
  (when (get-buffer "*Jenkins*")
    (with-current-buffer "*Jenkins*"
      (jenkins-browser-mode)
      (jenkins-browser-refresh)))
  (message "jenkins-browser-mode reloaded."))

(provide 'jenkins-browser)
;;; jenkins-browser.el ends here
