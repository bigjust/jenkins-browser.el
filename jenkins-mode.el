;;; jenkins-mode.el --- Interactive Jenkins job viewer and trigger -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Justin Caratzas

;; Author: Justin Caratzas
;; Keywords: tools, jenkins, ci
;; Version: 0.2.0
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
;; Start with `M-x jenkins'.
;;
;; Credentials and Jenkins URL can be configured via customize options or
;; automatically loaded from `~/.jenkins_jobs.ini'.
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

(defgroup jenkins nil
  "Interact with Jenkins from Emacs."
  :group 'tools
  :prefix "jenkins-")

(defcustom jenkins-url nil
  "Base URL for Jenkins (e.g., https://jenkins.example.com).
If nil, attempts to read from `~/.jenkins_jobs.ini`."
  :type '(choice (const :tag "Auto from ini" nil) string)
  :group 'jenkins)

(defcustom jenkins-username nil
  "Jenkins username.  If nil, attempts to read from `~/.jenkins_jobs.ini`."
  :type '(choice (const :tag "Auto from ini" nil) string)
  :group 'jenkins)

(defcustom jenkins-api-token nil
  "Jenkins API token or password.
If nil, attempts to read from `~/.jenkins_jobs.ini`."
  :type '(choice (const :tag "Auto from ini" nil) string)
  :group 'jenkins)

(defcustom jenkins-ini-path (expand-file-name "~/.jenkins_jobs.ini")
  "Path to jenkins_jobs.ini configuration file."
  :type 'file
  :group 'jenkins)

(defcustom jenkins-view-name nil
  "Name of a Jenkins view to use as the root job list.
If nil, the jobs of the Jenkins root are listed.  The view only applies to
the root buffer, not to folders opened from it."
  :type '(choice (const :tag "No view" nil) string)
  :group 'jenkins)

(defcustom jenkins-auto-refresh-interval nil
  "Auto-refresh interval in seconds for visible Jenkins buffers.
Set to nil or 0 to disable auto-refresh.  Refreshes run in the
background and do not block Emacs; a buffer whose previous refresh is
still waiting for Jenkins is skipped.  The value is read when a Jenkins
buffer is created."
  :type '(choice (const :tag "Disabled" nil) integer)
  :group 'jenkins)

(defcustom jenkins-request-timeout 30
  "Timeout in seconds for each HTTP request to Jenkins."
  :type 'integer
  :group 'jenkins)

(defcustom jenkins-history-limit 50
  "Maximum number of builds to show in a build history buffer."
  :type 'integer
  :group 'jenkins)

(defcustom jenkins-folder-class-regexp "Folder\\|MultiBranchProject"
  "Regexp matching the Jenkins `_class' of jobs that contain other jobs."
  :type 'regexp
  :group 'jenkins)

(defvar-local jenkins--filter-running-only nil
  "Non-nil if only running builds are displayed.")

(defvar-local jenkins--folder nil
  "Slash-separated folder path shown in this buffer, or nil for the root.")

(defvar-local jenkins--history-job nil
  "The slash-separated job path for the current build history buffer.")

(defvar jenkins--refresh-timer nil
  "Timer object for periodic refresh.")

;;; --- Configuration & Credentials ---

(defun jenkins--parse-ini-file (path)
  "Parse [jenkins] section from PATH and return an alist."
  (when (file-readable-p path)
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      (let (result in-jenkins-section)
        (while (not (eobp))
          (let ((line (string-trim (buffer-substring-no-properties
                                    (line-beginning-position)
                                    (line-end-position)))))
            (cond
             ((string-match-p "^\\[jenkins\\]" line)
              (setq in-jenkins-section t))
             ((string-match-p "^\\[" line)
              (setq in-jenkins-section nil))
             ((and in-jenkins-section (string-match "^\\([^=]+\\)=\\(.*\\)$" line))
              (push (cons (string-trim (match-string 1 line))
                          (string-trim (match-string 2 line)))
                    result))))
          (forward-line 1))
        result))))

(defun jenkins--get-config (key)
  "Retrieve KEY (\"url\", \"user\", or \"password\") from custom vars or INI file."
  (let ((custom-val (pcase key
                      ("url" jenkins-url)
                      ("user" jenkins-username)
                      ("password" jenkins-api-token))))
    (if (and custom-val (not (string-empty-p custom-val)))
        custom-val
      (let ((ini (jenkins--parse-ini-file jenkins-ini-path)))
        (cdr (assoc key ini))))))

(defun jenkins-base-url ()
  "Get sanitized Jenkins base URL without trailing slash."
  (let ((url (jenkins--get-config "url")))
    (unless url
      (error "Jenkins URL not configured.  Set `jenkins-url' or configure %s"
             jenkins-ini-path))
    (directory-file-name url)))

(defun jenkins--auth-header ()
  "Construct HTTP Basic Auth header."
  (let ((user (jenkins--get-config "user"))
        (pass (jenkins--get-config "password")))
    (when (and user pass)
      (format "Basic %s" (base64-encode-string (format "%s:%s" user pass) t)))))

;;; --- Job paths ---

(defun jenkins--join-path (&rest parts)
  "Join the non-empty strings in PARTS with a slash."
  (string-join (cl-remove-if (lambda (p) (or (null p) (string-empty-p p))) parts)
               "/"))

(defun jenkins--job-path (job)
  "Return the URL path fragment for JOB, e.g. \"/job/a/job/b\".
JOB is a slash-separated string such as \"a/b\".  Each component is
URL-encoded.  Return the empty string when JOB is nil or empty."
  (mapconcat (lambda (name) (concat "/job/" (url-hexify-string name)))
             (split-string (or job "") "/" t)
             ""))

(defun jenkins--job-url (job &optional suffix)
  "Return the full URL of JOB, optionally followed by SUFFIX."
  (concat (jenkins-base-url) (jenkins--job-path job) (or suffix "")))

;;; --- API & HTTP Helper ---

(defun jenkins--get (key obj)
  "Safely retrieve KEY from OBJ if OBJ is a hash-table, else nil.
Converts `:null` and `:json-false` values to nil."
  (when (hash-table-p obj)
    (let ((val (gethash key obj)))
      (if (memq val '(:null :json-false)) nil val))))

(defvar jenkins--crumb-cache nil
  "Cached CSRF crumb as (KEY . CRUMB), or nil.
KEY identifies the server and user the crumb was issued for, see
`jenkins--crumb-key'.  CRUMB is a cons (HEADER . VALUE).")

(defun jenkins--crumb-key ()
  "Return a string identifying the current server and user."
  (concat (or (jenkins--get-config "user") "") "@" (jenkins-base-url)))

(defun jenkins--crumb ()
  "Return the CSRF crumb for the current server, fetching it if needed.
A crumb fetched successfully is cached until `jenkins--crumb-cache' is
cleared.  Return nil when the server does not issue crumbs."
  (let ((key (jenkins--crumb-key)))
    (if (equal (car jenkins--crumb-cache) key)
        (cdr jenkins--crumb-cache)
      (let ((crumb (jenkins--fetch-crumb)))
        (when crumb
          (setq jenkins--crumb-cache (cons key crumb)))
        crumb))))

(defun jenkins--parse-headers ()
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

(defun jenkins--parse-response ()
  "Return (STATUS BODY HEADERS) for the HTTP response in the current buffer.
STATUS is the HTTP status code or nil.  BODY is the undecoded body, see
`jenkins--decode'.  HEADERS is an alist as returned by
`jenkins--parse-headers'."
  (let ((status (bound-and-true-p url-http-response-status))
        (headers (jenkins--parse-headers)))
    (goto-char (point-min))
    (re-search-forward "^$" nil t)
    (unless (eobp)
      (forward-char 1))
    (list status
          (buffer-substring-no-properties (point) (point-max))
          headers)))

(defun jenkins--decode (bytes)
  "Decode the undecoded response body BYTES as UTF-8."
  (decode-coding-string bytes 'utf-8))

(defun jenkins--send (method url-str post-data content-type crumb)
  "Perform a synchronous HTTP request; return (STATUS BODY HEADERS).
METHOD, URL-STR, POST-DATA and CONTENT-TYPE are as for `jenkins--http'.
CRUMB is a cons (HEADER . VALUE) to send as a header, or nil.  The body
is returned undecoded, see `jenkins--parse-response'.  Never signal an
error because of the HTTP status."
  (let* ((auth (jenkins--auth-header))
         (url-request-method method)
         (url-request-extra-headers
          (delq nil
                (list (when auth (cons "Authorization" auth))
                      (when content-type (cons "Content-Type" content-type))
                      crumb)))
         (url-request-data post-data)
         (buf (url-retrieve-synchronously url-str t t jenkins-request-timeout)))
    (unless buf
      (error "No response from Jenkins for %s" url-str))
    (with-current-buffer buf
      (unwind-protect
          (jenkins--parse-response)
        (kill-buffer buf)))))

(defun jenkins--http-full (method url-str &optional post-data content-type raw)
  "Perform a synchronous HTTP request; return (BODY . HEADERS).
METHOD is the HTTP verb and URL-STR the target.  POST-DATA and CONTENT-TYPE
are sent with the request when non-nil.  BODY is the response body string,
decoded as UTF-8 unless RAW is non-nil, and HEADERS the response headers,
see `jenkins--parse-headers'.  A CSRF
crumb is attached to state-changing methods; it is cached, and if the
server rejects the request with HTTP 403 the crumb is refreshed and the
request retried once.  Signal an error on HTTP status 400 or above."
  (let* ((state-changing (member method '("POST" "PUT" "DELETE")))
         (crumb (and state-changing (jenkins--crumb)))
         (resp (jenkins--send method url-str post-data content-type crumb)))
    (when (and crumb (eql (nth 0 resp) 403))
      (setq jenkins--crumb-cache nil)
      (let ((fresh (jenkins--crumb)))
        (when (and fresh (not (equal fresh crumb)))
          (setq resp (jenkins--send method url-str post-data content-type fresh)))))
    (when (and (integerp (nth 0 resp)) (>= (nth 0 resp) 400))
      (error "Jenkins returned HTTP %d for %s" (nth 0 resp) url-str))
    (cons (if raw (nth 1 resp) (jenkins--decode (nth 1 resp)))
          (nth 2 resp))))

(defun jenkins--http (method url-str &optional post-data content-type)
  "Perform a synchronous HTTP request and return the response body string.
METHOD, URL-STR, POST-DATA and CONTENT-TYPE are as for `jenkins--http-full',
which also describes the CSRF crumb handling.  Signal an error on HTTP
status 400 or above."
  (car (jenkins--http-full method url-str post-data content-type)))

(defun jenkins--parse-json (body)
  "Parse BODY as JSON into hash-tables and lists, or return BODY unchanged.
JSON null and false both become nil."
  (condition-case nil
      (json-parse-string body
                         :object-type 'hash-table
                         :array-type 'list
                         :null-object nil
                         :false-object nil)
    (error body)))

(defun jenkins--request (method url-str &optional post-data content-type)
  "Make a synchronous request; return parsed JSON or the raw body string.
METHOD, URL-STR, POST-DATA and CONTENT-TYPE are as for `jenkins--http'."
  (jenkins--parse-json (jenkins--http method url-str post-data content-type)))

(defun jenkins--request-async (url-str callback &optional raw)
  "Send a GET request to URL-STR without blocking Emacs.
CALLBACK is called exactly once, with arguments (RESULT ERROR).  On
success RESULT is the parsed JSON or raw body, as for `jenkins--request',
and ERROR is nil.  With RAW non-nil, RESULT is instead the plist
\(:body STRING :headers ALIST), where the body is neither decoded nor
parsed.  On failure (connection problem, HTTP status 400 or
above, or `jenkins-request-timeout' seconds without an answer) RESULT is
nil and ERROR is a message string.  Only GET is supported, so no CSRF
crumb is involved."
  (let* ((auth (jenkins--auth-header))
         (url-request-method "GET")
         (url-request-extra-headers
          (when auth (list (cons "Authorization" auth))))
         (url-request-data nil)
         (timeout jenkins-request-timeout)
         (done nil)
         (timer nil)
         (buf nil))
    (cl-flet ((finish (result err)
                (unless done
                  (setq done t)
                  (when timer (cancel-timer timer))
                  (condition-case cb-err
                      (funcall callback result err)
                    (error (message "jenkins: callback failed: %s"
                                    (error-message-string cb-err)))))))
      (setq buf
            (url-retrieve
             url-str
             (lambda (status)
               (let ((resp-buf (current-buffer)))
                 (unwind-protect
                     (let* ((resp (jenkins--parse-response))
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
                                     (jenkins--parse-json
                                      (jenkins--decode (nth 1 resp))))
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

(defun jenkins--fetch-crumb ()
  "Fetch the CSRF protection crumb as a cons (HEADER . VALUE), or nil."
  (condition-case nil
      (let* ((url (format "%s/crumbIssuer/api/json" (jenkins-base-url)))
             (res (jenkins--request "GET" url)))
        (when (hash-table-p res)
          (let ((field (jenkins--get "crumbRequestField" res))
                (crumb (jenkins--get "crumb" res)))
            (when (and field crumb)
              (cons field crumb)))))
    (error nil)))

;;; --- Core Jenkins Queries ---

(defun jenkins--jobs-url (folder)
  "Return the API URL listing the jobs in FOLDER (nil for the root)."
  (let ((tree "jobs[name,color,_class,lastBuild[number,building,result,duration,timestamp,estimatedDuration]]"))
    (concat (jenkins-base-url)
            (if (and (null folder) jenkins-view-name)
                (concat "/view/" (url-hexify-string jenkins-view-name))
              (jenkins--job-path folder))
            "/api/json?tree=" (url-hexify-string tree))))

(defun jenkins--jobs-from-response (resp)
  "Return the list of job hash-tables in the parsed jobs response RESP."
  (when (hash-table-p resp)
    (jenkins--get "jobs" resp)))

(defun jenkins--fetch-jobs (&optional folder)
  "Fetch all jobs in FOLDER (nil for the root) and their last build metadata."
  (jenkins--jobs-from-response
   (jenkins--request "GET" (jenkins--jobs-url folder))))

(defun jenkins--folder-p (job)
  "Return non-nil if the job hash-table JOB can contain other jobs."
  (let ((class (jenkins--get "_class" job)))
    (and (stringp class)
         (string-match-p jenkins-folder-class-regexp class))))

(defun jenkins--format-duration (millis)
  "Convert MILLIS to a human-readable duration."
  (if (or (null millis) (not (numberp millis)) (<= millis 0))
      "-"
    (let* ((secs (/ millis 1000))
           (mins (/ secs 60))
           (hours (/ mins 60)))
      (cond
       ((> hours 0) (format "%dh %02dm" hours (% mins 60)))
       ((> mins 0)  (format "%dm %02ds" mins (% secs 60)))
       (t           (format "%ds" secs))))))

(defun jenkins--format-timestamp (millis)
  "Convert MILLIS epoch timestamp to formatted date/time string."
  (if (or (null millis) (not (numberp millis)) (<= millis 0))
      "-"
    (format-time-string "%Y-%m-%d %H:%M" (seconds-to-time (/ millis 1000.0)))))

(defun jenkins--format-description (description)
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

(defun jenkins--format-culprits (culprits)
  "Format the list of CULPRITS hash-tables as a comma-separated author string."
  (let ((names (when (listp culprits)
                 (delq nil (mapcar (lambda (c) (jenkins--get "fullName" c))
                                   culprits)))))
    (if names (string-join names ", ") "-")))

(defun jenkins--format-status (color building result)
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

(defvar-local jenkins--refresh-in-flight nil
  "Non-nil while a background refresh of this buffer is waiting for Jenkins.")

(defun jenkins--apply-refresh (resp)
  "Replace the entries of the current buffer using the parsed response RESP."
  (setq tabulated-list-entries
        (if (derived-mode-p 'jenkins-build-history-mode)
            (jenkins--build-history-entries (jenkins--builds-from-response resp))
          (jenkins--build-job-entries (jenkins--jobs-from-response resp))))
  (tabulated-list-print t))

(defun jenkins--refresh-current ()
  "Refresh the current Jenkins buffer in the background, without blocking.
The request is sent asynchronously and the buffer is updated when the
answer arrives; a failure is reported with `message' and the old contents
are kept.  Do nothing if a refresh of this buffer is already under way."
  (let ((history (derived-mode-p 'jenkins-build-history-mode)))
    (when (and (not jenkins--refresh-in-flight)
               (or (not history) jenkins--history-job))
      (let ((buf (current-buffer))
            (url (if history
                     (jenkins--history-url jenkins--history-job)
                   (jenkins--jobs-url jenkins--folder))))
        (setq jenkins--refresh-in-flight t)
        (condition-case err
            (jenkins--request-async
             url
             (lambda (resp error-message)
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (setq jenkins--refresh-in-flight nil)
                   (if error-message
                       (message "jenkins refresh failed: %s" error-message)
                     (jenkins--apply-refresh resp))))))
          (error
           (setq jenkins--refresh-in-flight nil)
           (signal (car err) (cdr err))))))))

(defun jenkins--refresh-later ()
  "Refresh the current Jenkins buffer in a couple of seconds."
  (when (derived-mode-p 'jenkins-mode 'jenkins-build-history-mode)
    (let ((buf (current-buffer)))
      (run-at-time 2 nil
                   (lambda ()
                     (when (buffer-live-p buf)
                       (with-current-buffer buf
                         (condition-case err
                             (jenkins--refresh-current)
                           (error (message "jenkins refresh failed: %s"
                                           (error-message-string err)))))))))))

(defun jenkins--timer-tick ()
  "Refresh all visible Jenkins buffers; stop the timer when none are left.
The refreshes run in the background, see `jenkins--refresh-current'."
  (let (found)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (derived-mode-p 'jenkins-mode 'jenkins-build-history-mode)
          (setq found t)
          (when (get-buffer-window buf 'visible)
            (condition-case err
                (jenkins--refresh-current)
              (error (message "jenkins auto-refresh failed: %s"
                              (error-message-string err))))))))
    (unless found
      (jenkins--stop-timer))))

(defun jenkins--stop-timer ()
  "Cancel the auto-refresh timer."
  (when (timerp jenkins--refresh-timer)
    (cancel-timer jenkins--refresh-timer))
  (setq jenkins--refresh-timer nil))

(defun jenkins--ensure-timer ()
  "Start the auto-refresh timer if enabled and not already running."
  (when (and (integerp jenkins-auto-refresh-interval)
             (> jenkins-auto-refresh-interval 0)
             (not (timerp jenkins--refresh-timer)))
    (setq jenkins--refresh-timer
          (run-at-time jenkins-auto-refresh-interval
                       jenkins-auto-refresh-interval
                       #'jenkins--timer-tick))))

;;; --- Tabulated List UI for Jobs ---

(defun jenkins--job-entries ()
  "Fetch the jobs of the current folder and return their list entries."
  (jenkins--build-job-entries (jenkins--fetch-jobs jenkins--folder)))

(defun jenkins--build-job-entries (jobs)
  "Generate tabulated list entries from the job hash-tables JOBS.
Each entry id is a cons (NAME . FOLDER-P)."
  (let (entries)
    (dolist (job (if (listp jobs) jobs nil))
      (when (hash-table-p job)
        (let* ((name (jenkins--get "name" job))
               (folder-p (jenkins--folder-p job))
               (color (jenkins--get "color" job))
               (last-build (jenkins--get "lastBuild" job))
               (num (jenkins--get "number" last-build))
               (building (jenkins--get "building" last-build))
               (result (jenkins--get "result" last-build))
               (duration (jenkins--get "duration" last-build)))
          (when (and name
                     (or folder-p
                         (not jenkins--filter-running-only)
                         building
                         (and (stringp color) (string-match-p "_anime$" color))))
            (push (list (cons name (and folder-p t))
                        (vector (propertize (if folder-p (concat name "/") name)
                                            'face (if folder-p
                                                      'font-lock-type-face
                                                    'font-lock-function-name-face))
                                (if folder-p
                                    (propertize "FOLDER" 'face 'font-lock-type-face)
                                  (jenkins--format-status color building result))
                                (if num (format "#%s" num) "-")
                                (jenkins--format-duration duration)))
                  entries)))))
    (nreverse entries)))

;;; --- Interactive Commands for Jobs ---

(defun jenkins-refresh ()
  "Refresh the Jenkins jobs list."
  (interactive)
  (setq tabulated-list-entries (jenkins--job-entries))
  (tabulated-list-print t))

(defun jenkins-toggle-running-filter ()
  "Toggle between showing all jobs vs only running jobs.
Folders are always shown so that they can still be opened."
  (interactive)
  (setq jenkins--filter-running-only (not jenkins--filter-running-only))
  (message (if jenkins--filter-running-only
               "Showing RUNNING jobs only"
             "Showing ALL jobs"))
  (jenkins-refresh))

(defun jenkins--job-names ()
  "Return full paths of the non-folder jobs in the current folder."
  (delq nil
        (mapcar (lambda (j)
                  (and (hash-table-p j)
                       (not (jenkins--folder-p j))
                       (let ((name (jenkins--get "name" j)))
                         (and name (jenkins--join-path jenkins--folder name)))))
                (jenkins--fetch-jobs jenkins--folder))))

(defun jenkins--read-job (prompt)
  "Return the full path of the job at point, or ask for one using PROMPT.
Signal a `user-error' when point is on a folder."
  (let ((id (and (derived-mode-p 'jenkins-mode) (tabulated-list-get-id))))
    (cond
     ((and (consp id) (cdr id))
      (user-error "'%s' is a folder; press RET to open it" (car id)))
     ((consp id)
      (jenkins--join-path jenkins--folder (car id)))
     (t
      (let ((job (completing-read prompt (jenkins--job-names))))
        (if (string-empty-p job) (user-error "No job selected") job))))))

(defun jenkins--open-buffer (name setup display)
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

(defun jenkins-open-folder (folder)
  "Open a jobs buffer listing the jobs in FOLDER (a slash-separated path)."
  (jenkins--open-buffer
   (format "*Jenkins: %s*" folder)
   (lambda ()
     (jenkins-mode)
     (setq jenkins--folder folder)
     (jenkins-refresh))
   #'pop-to-buffer-same-window))

(defun jenkins-enter ()
  "Open the folder at point, or the build history of the job at point."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (unless (consp id)
      (user-error "No job selected"))
    (if (cdr id)
        (jenkins-open-folder (jenkins--join-path jenkins--folder (car id)))
      (jenkins-view-build-history (jenkins--join-path jenkins--folder (car id))))))

(defun jenkins--boolean-parameter-p (param)
  "Return non-nil if the parameter definition hash-table PARAM is a boolean.
Jenkins expects the strings \"true\" and \"false\" for these, not Lisp values."
  (let ((class (or (jenkins--get "_class" param) (jenkins--get "type" param))))
    (and (stringp class)
         (string-match-p "BooleanParameterDefinition" class))))

(defun jenkins-trigger-job (job)
  "Interactively trigger JOB, prompting for parameters if defined.
JOB is a slash-separated path such as \"folder/job\"."
  (interactive (list (jenkins--read-job "Trigger Job: ")))
  (let* ((info (jenkins--request "GET" (jenkins--job-url job "/api/json")))
         (props (when (hash-table-p info) (jenkins--get "property" info)))
         (props-list (if (listp props) props nil))
         (param-def-prop (cl-find-if (lambda (p)
                                       (and (hash-table-p p)
                                            (jenkins--get "parameterDefinitions" p)))
                                     props-list))
         (param-defs (when param-def-prop (jenkins--get "parameterDefinitions" param-def-prop)))
         (defs-list (if (listp param-defs) param-defs nil)))
    (if (null defs-list)
        ;; Simple non-parameterized trigger
        (progn
          (jenkins--request "POST" (jenkins--job-url job "/build"))
          (message "Triggered '%s'" job))
      ;; Parameterized trigger
      (let (query-params)
        (dolist (p defs-list)
          (when (hash-table-p p)
            (let* ((p-name (jenkins--get "name" p))
                   (p-desc (or (jenkins--get "description" p) ""))
                   (default-obj (jenkins--get "defaultParameterValue" p))
                   (boolean-p (jenkins--boolean-parameter-p p))
                   (p-default (if boolean-p
                                  (if (and (hash-table-p default-obj)
                                           (jenkins--get "value" default-obj))
                                      "true"
                                    "false")
                                (when (hash-table-p default-obj)
                                  (let ((val (jenkins--get "value" default-obj)))
                                    (when val (format "%s" val))))))
                   (choices (if boolean-p
                                '("true" "false")
                              (jenkins--get "choices" p)))
                   (val (if (and choices (listp choices))
                            (completing-read (format "%s (%s): " p-name p-desc) choices nil t p-default)
                          (read-string (format "%s [%s] (%s): " p-name (or p-default "") p-desc)
                                       nil nil p-default))))
              (when p-name
                (push (format "%s=%s" (url-hexify-string p-name) (url-hexify-string (or val "")))
                      query-params)))))
        (jenkins--request
         "POST"
         (jenkins--job-url job (format "/buildWithParameters?%s"
                                       (string-join (nreverse query-params) "&"))))
        (message "Triggered '%s' with parameters." job)))
    (jenkins--refresh-later)))

(defcustom jenkins-console-poll-interval 2
  "Seconds between requests for new output while following a running build."
  :type 'number
  :group 'jenkins)

(defvar-local jenkins--console-job nil
  "Slash-separated path of the job whose console this buffer shows.")

(defvar-local jenkins--console-build nil
  "Number (as a string) of the build whose console this buffer shows.")

(defvar-local jenkins--console-offset 0
  "Byte offset in the build log of the first byte not yet fetched.")

(defvar-local jenkins--console-pending ""
  "Undecoded unfinished last line of the log, held back until it is complete.")

(defvar-local jenkins--console-more-data nil
  "Non-nil if Jenkins said the build may still write more output.")

(defvar-local jenkins--console-in-flight nil
  "Non-nil while a request for more output is waiting for Jenkins.")

(defvar-local jenkins--console-timer nil
  "Timer polling for new output while following the build, or nil.")

(define-derived-mode jenkins-console-mode special-mode "Jenkins-Console"
  "Major mode for viewing a Jenkins console log.
While the build is running the buffer follows it, fetching new output
every `jenkins-console-poll-interval' seconds.

\\{jenkins-console-mode-map}"
  (add-hook 'kill-buffer-hook #'jenkins--console-stop-follow nil t))

(defconst jenkins--console-note-regexp
  "\r\\|\e\\[8mha:[A-Za-z0-9+/=]*\e\\[0m"
  "Match what is removed from console text.
That is carriage returns and the hidden `ConsoleNote' annotations that
Jenkins mixes into the progressive log.")

(defun jenkins--console-text (text)
  "Strip CR characters and Jenkins console annotations from console TEXT."
  (replace-regexp-in-string jenkins--console-note-regexp "" text))

(defun jenkins--console-split (bytes final)
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

(defun jenkins--console-insert (bytes)
  "Append the undecoded log text BYTES to the current console buffer.
Windows and point that were at the end of the buffer stay there."
  (when (> (length bytes) 0)
    (let ((windows (cl-remove-if-not
                    (lambda (w) (= (window-point w) (point-max)))
                    (get-buffer-window-list (current-buffer) nil t)))
          (at-end (= (point) (point-max)))
          (inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (insert (jenkins--console-text (jenkins--decode bytes))))
      (when at-end
        (goto-char (point-max)))
      (dolist (w windows)
        (set-window-point w (point-max))))))

(defun jenkins--console-url (job build offset)
  "Return the URL of the log of BUILD of JOB from byte OFFSET on."
  (jenkins--job-url job (format "/%s/logText/progressiveText?start=%d"
                                build offset)))

(defun jenkins--console-apply (body headers)
  "Add the undecoded log chunk BODY, with response HEADERS, to the buffer.
Move the fetch offset on and remember whether the build is still running.
Stop following when Jenkins reports that there is no more data."
  (let* ((size (cdr (assoc "x-text-size" headers)))
         (more (equal (cdr (assoc "x-more-data" headers)) "true"))
         (split (jenkins--console-split (concat jenkins--console-pending body)
                                        (not more))))
    (setq jenkins--console-offset (if size
                                      (string-to-number size)
                                    (+ jenkins--console-offset (length body)))
          jenkins--console-pending (cdr split)
          jenkins--console-more-data more)
    (jenkins--console-insert (car split))
    (unless more
      (jenkins--console-stop-follow))))

(defun jenkins--console-fetch ()
  "Fetch the next part of the log of the current console buffer.
The request is sent in the background.  Do nothing if one is already
under way.  On failure, report it and stop following."
  (unless jenkins--console-in-flight
    (let* ((buf (current-buffer))
           (offset jenkins--console-offset)
           (url (jenkins--console-url jenkins--console-job
                                      jenkins--console-build offset)))
      (setq jenkins--console-in-flight t)
      (condition-case err
          (jenkins--request-async
           url
           (lambda (resp error-message)
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (setq jenkins--console-in-flight nil)
                 (cond
                  (error-message
                   (jenkins--console-stop-follow)
                   (message "jenkins console: %s; press f to resume following"
                            error-message))
                  ;; The buffer was reloaded while this request was away.
                  ((/= offset jenkins--console-offset))
                  (t (jenkins--console-apply (plist-get resp :body)
                                             (plist-get resp :headers)))))))
           t)
        (error
         (setq jenkins--console-in-flight nil)
         (signal (car err) (cdr err)))))))

(defun jenkins--console-start-follow ()
  "Start polling for new output in the current console buffer."
  (unless (timerp jenkins--console-timer)
    (let* ((buf (current-buffer))
           (interval jenkins-console-poll-interval)
           timer)
      (setq timer
            (run-at-time
             interval interval
             (lambda ()
               (if (and (buffer-live-p buf)
                        (eq (buffer-local-value 'jenkins--console-timer buf)
                            timer))
                   (with-current-buffer buf
                     (jenkins--console-fetch))
                 (cancel-timer timer)))))
      (setq jenkins--console-timer timer
            mode-line-process " follow")
      (force-mode-line-update))))

(defun jenkins--console-stop-follow ()
  "Stop polling for new output in the current console buffer."
  (when (timerp jenkins--console-timer)
    (cancel-timer jenkins--console-timer))
  (setq jenkins--console-timer nil
        mode-line-process nil)
  (force-mode-line-update))

(defun jenkins-console-refresh ()
  "Fetch any new output of the build shown in this console buffer."
  (interactive)
  (if jenkins--console-more-data
      (jenkins--console-fetch)
    (message "The build has finished; there is no more output")))

(defun jenkins-console-toggle-follow ()
  "Start or stop following the build shown in this console buffer."
  (interactive)
  (cond
   ((timerp jenkins--console-timer)
    (jenkins--console-stop-follow)
    (message "Stopped following the build"))
   ((not jenkins--console-more-data)
    (message "The build has finished; there is nothing to follow"))
   (t
    (jenkins--console-start-follow)
    (jenkins--console-fetch)
    (message "Following the build"))))

(define-key jenkins-console-mode-map (kbd "g") #'jenkins-console-refresh)
(define-key jenkins-console-mode-map (kbd "f") #'jenkins-console-toggle-follow)

(defun jenkins--resolve-build (job build-id)
  "Return the number, as a string, of the build BUILD-ID of JOB.
BUILD-ID may be \"lastBuild\", which moves on when a new build starts."
  (if (string-match-p "\\`[0-9]+\\'" build-id)
      build-id
    (let* ((info (jenkins--request
                  "GET" (jenkins--job-url
                         job (format "/%s/api/json?tree=number" build-id))))
           (number (jenkins--get "number" info)))
      (unless number
        (error "Jenkins has no %s for %s" build-id job))
      (format "%s" number))))

(defun jenkins-view-console (job &optional build-number)
  "View the console log for BUILD-NUMBER (default \"lastBuild\") of JOB.
If the build is still running the buffer follows it, see
`jenkins-console-toggle-follow'."
  (interactive (list (jenkins--read-job "Console for job: ")))
  (let ((build-id (or (and build-number (format "%s" build-number)) "lastBuild")))
    (jenkins--open-buffer
     (format "*Jenkins-Console: %s #%s*" job build-id)
     (lambda ()
       (jenkins--console-stop-follow)
       (let ((build (jenkins--resolve-build job build-id)))
         (let ((resp (jenkins--http-full
                      "GET" (jenkins--console-url job build 0) nil nil t)))
           (jenkins-console-mode)
           (setq jenkins--console-job job
                 jenkins--console-build build)
           (let ((inhibit-read-only t))
             (erase-buffer))
           (jenkins--console-apply (car resp) (cdr resp))
           (goto-char (point-max))
           (when jenkins--console-more-data
             (jenkins--console-start-follow)))))
     #'pop-to-buffer)))

(defun jenkins-abort-build (job)
  "Abort the running build for JOB."
  (interactive (list (jenkins--read-job "Abort job: ")))
  (when (yes-or-no-p (format "Abort active build for %s? " job))
    (jenkins--request "POST" (jenkins--job-url job "/lastBuild/stop"))
    (message "Requested abort for %s" job)
    (jenkins--refresh-later)))

(defun jenkins-open-in-browser (job)
  "Open JOB in external web browser."
  (interactive (list (jenkins--read-job "Open job: ")))
  (browse-url (jenkins--job-url job)))

;;; --- Build History Mode ---

(defun jenkins--history-url (job)
  "Return the API URL listing the recent builds of JOB."
  (let ((tree (format "builds[number,result,building,duration,timestamp,displayName,description,culprits[fullName]]{0,%d}"
                      jenkins-history-limit)))
    (jenkins--job-url job (format "/api/json?tree=%s" (url-hexify-string tree)))))

(defun jenkins--builds-from-response (resp)
  "Return the list of build hash-tables in the parsed history response RESP."
  (when (hash-table-p resp)
    (jenkins--get "builds" resp)))

(defun jenkins--fetch-build-history (job)
  "Fetch builds list for JOB."
  (jenkins--builds-from-response
   (jenkins--request "GET" (jenkins--history-url job))))

(defun jenkins--history-entries (job)
  "Fetch the builds of JOB and return their list entries."
  (jenkins--build-history-entries (jenkins--fetch-build-history job)))

(defun jenkins--build-history-entries (builds)
  "Generate tabulated list entries from the build hash-tables BUILDS."
  (let (entries)
    (dolist (b (if (listp builds) builds nil))
      (when (hash-table-p b)
        (let* ((num (jenkins--get "number" b))
               (result (jenkins--get "result" b))
               (building (jenkins--get "building" b))
               (duration (jenkins--get "duration" b))
               (timestamp (jenkins--get "timestamp" b))
               (status-str (jenkins--format-status nil building result)))
          (when num
            (push (list num
                        (vector (propertize (format "#%d" num) 'face 'font-lock-keyword-face)
                                status-str
                                (jenkins--format-timestamp timestamp)
                                (jenkins--format-culprits (jenkins--get "culprits" b))
                                (jenkins--format-duration duration)
                                (jenkins--format-description (jenkins--get "description" b))))
                  entries)))))
    (nreverse entries)))

(defun jenkins-history-refresh ()
  "Refresh the current build history buffer."
  (interactive)
  (when jenkins--history-job
    (setq tabulated-list-entries (jenkins--history-entries jenkins--history-job))
    (tabulated-list-print t)))

(defun jenkins-current-build-number ()
  "Get the build number at point in a build history buffer."
  (tabulated-list-get-id))

(defun jenkins-history-view-console (&optional build-num)
  "View console output for BUILD-NUM of the current job."
  (interactive (list (or (jenkins-current-build-number) (user-error "No build selected"))))
  (unless (and jenkins--history-job build-num)
    (user-error "Cannot view console: missing job or build number"))
  (jenkins-view-console jenkins--history-job build-num))

(defun jenkins-history-abort-build (&optional build-num)
  "Abort BUILD-NUM for the current job."
  (interactive (list (or (jenkins-current-build-number) (user-error "No build selected"))))
  (unless (and jenkins--history-job build-num)
    (user-error "Cannot abort: missing job or build number"))
  (when (yes-or-no-p (format "Abort %s #%s? " jenkins--history-job build-num))
    (jenkins--request "POST" (jenkins--job-url jenkins--history-job (format "/%s/stop" build-num)))
    (message "Requested abort for %s #%s" jenkins--history-job build-num)
    (jenkins--refresh-later)))

(defun jenkins-history-open-in-browser (&optional build-num)
  "Open BUILD-NUM in external browser."
  (interactive (list (or (jenkins-current-build-number) (user-error "No build selected"))))
  (browse-url (jenkins--job-url jenkins--history-job (format "/%s" (or build-num "")))))

(defun jenkins-view-build-history (&optional job)
  "View the build history for JOB (a slash-separated path)."
  (interactive (list (jenkins--read-job "Job: ")))
  (unless job
    (user-error "No job selected"))
  (jenkins--open-buffer
   (format "*Jenkins-History: %s*" job)
   (lambda ()
     (jenkins-build-history-mode)
     (setq jenkins--history-job job)
     (jenkins-history-refresh))
   #'pop-to-buffer))

;;; --- Mode Definitions and Keymaps ---

(defvar jenkins-build-history-mode-map (make-sparse-keymap)
  "Keymap for `jenkins-build-history-mode` buffers.")
(set-keymap-parent jenkins-build-history-mode-map tabulated-list-mode-map)
(define-key jenkins-build-history-mode-map (kbd "g")   #'jenkins-history-refresh)
(define-key jenkins-build-history-mode-map (kbd "RET") #'jenkins-history-view-console)
(define-key jenkins-build-history-mode-map [return]    #'jenkins-history-view-console)
(define-key jenkins-build-history-mode-map (kbd "c")   #'jenkins-history-view-console)
(define-key jenkins-build-history-mode-map (kbd "k")   #'jenkins-history-abort-build)
(define-key jenkins-build-history-mode-map (kbd "o")   #'jenkins-history-open-in-browser)

(define-derived-mode jenkins-build-history-mode tabulated-list-mode "Jenkins-History"
  "Major mode for browsing Jenkins build history.

\\{jenkins-build-history-mode-map}"
  :keymap jenkins-build-history-mode-map
  (setq tabulated-list-format
        [("Build"     10 t)
         ("Status"    12 t)
         ("Timestamp" 18 t)
         ("Author"    24 nil)
         ("Duration"  12 nil)
         ("Description" 0 nil)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Build" t))
  (add-hook 'tabulated-list-revert-hook #'jenkins-history-refresh nil t)
  (hl-line-mode 1)
  (tabulated-list-init-header)
  (jenkins--ensure-timer))

(defvar jenkins-mode-map (make-sparse-keymap)
  "Keymap for `jenkins-mode` buffers.")
(set-keymap-parent jenkins-mode-map tabulated-list-mode-map)
(define-key jenkins-mode-map (kbd "g")   #'jenkins-refresh)
(define-key jenkins-mode-map (kbd "b")   #'jenkins-trigger-job)
(define-key jenkins-mode-map (kbd "RET") #'jenkins-enter)
(define-key jenkins-mode-map [return]    #'jenkins-enter)
(define-key jenkins-mode-map (kbd "h")   #'jenkins-view-build-history)
(define-key jenkins-mode-map (kbd "c")   #'jenkins-view-console)
(define-key jenkins-mode-map (kbd "k")   #'jenkins-abort-build)
(define-key jenkins-mode-map (kbd "f")   #'jenkins-toggle-running-filter)
(define-key jenkins-mode-map (kbd "o")   #'jenkins-open-in-browser)

(define-derived-mode jenkins-mode tabulated-list-mode "Jenkins"
  "Major mode for browsing and triggering Jenkins jobs.

\\{jenkins-mode-map}"
  :keymap jenkins-mode-map
  (setq tabulated-list-format
        [("Job Name" 40 t)
         ("Status"   12 t)
         ("Last #"   8  nil)
         ("Duration" 12 nil)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Job Name" nil))
  (add-hook 'tabulated-list-revert-hook #'jenkins-refresh nil t)
  (hl-line-mode 1)
  (tabulated-list-init-header)
  (jenkins--ensure-timer))

;;;###autoload
(defun jenkins ()
  "Open the Jenkins jobs overview buffer."
  (interactive)
  (jenkins--open-buffer
   "*Jenkins*"
   (lambda ()
     (jenkins-mode)
     (jenkins-refresh))
   #'pop-to-buffer))

;;;###autoload
(defun jenkins-reload ()
  "Force reload `jenkins-mode` and re-initialize the root Jenkins buffer."
  (interactive)
  (load-file (find-library-name "jenkins-mode"))
  (when (get-buffer "*Jenkins*")
    (with-current-buffer "*Jenkins*"
      (jenkins-mode)
      (jenkins-refresh)))
  (message "jenkins-mode reloaded."))

(provide 'jenkins-mode)
;;; jenkins-mode.el ends here
