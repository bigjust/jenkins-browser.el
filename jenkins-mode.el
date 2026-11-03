;;; jenkins-mode.el --- Interactive Jenkins job viewer and trigger -*- lexical-binding: t; -*-

;; Copyright (C) 2026 JCaratzas

;; Author: JCaratzas
;; Keywords: tools, jenkins, ci
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (cl-lib "0.5"))

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
(require 'json)
(require 'url)
(require 'url-http)
(require 'subr-x)
(require 'cl-lib)

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
  "Jenkins username. If nil, attempts to read from `~/.jenkins_jobs.ini`."
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
  "Name of a Jenkins view to use as the top-level job list.
If nil, the jobs of the Jenkins root are listed.  The view only applies to
the top-level buffer, not to folders opened from it."
  :type '(choice (const :tag "No view" nil) string)
  :group 'jenkins)

(defcustom jenkins-auto-refresh-interval 15
  "Auto-refresh interval in seconds when in `jenkins-mode`.
Set to 0 or nil to disable auto-refresh."
  :type '(choice (const :tag "Disabled" nil) integer)
  :group 'jenkins)

(defcustom jenkins-request-timeout 30
  "Timeout in seconds for each HTTP request to Jenkins."
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

(defun jenkins--http (method url-str &optional post-data content-type)
  "Perform a synchronous HTTP request and return the response body string.
METHOD is the HTTP verb and URL-STR the target.  POST-DATA and CONTENT-TYPE
are sent with the request when non-nil.  A CSRF crumb is attached to
state-changing methods.  Signal an error on HTTP status 400 or above."
  (let* ((auth (jenkins--auth-header))
         (url-request-method method)
         (url-request-extra-headers
          (delq nil
                (list (when auth (cons "Authorization" auth))
                      (when content-type (cons "Content-Type" content-type)))))
         (url-request-data post-data))
    (when (member method '("POST" "PUT" "DELETE"))
      (let ((crumb (jenkins--fetch-crumb)))
        (when crumb
          (push crumb url-request-extra-headers))))
    (let ((buf (url-retrieve-synchronously url-str t t jenkins-request-timeout)))
      (unless buf
        (error "No response from Jenkins for %s" url-str))
      (with-current-buffer buf
        (unwind-protect
            (let ((status (bound-and-true-p url-http-response-status)))
              (goto-char (point-min))
              (re-search-forward "^$" nil t)
              (forward-char 1)
              (when (and (integerp status) (>= status 400))
                (error "Jenkins returned HTTP %d for %s" status url-str))
              (decode-coding-string
               (buffer-substring-no-properties (point) (point-max)) 'utf-8))
          (kill-buffer buf))))))

(defun jenkins--request (method url-str &optional post-data content-type)
  "Make a synchronous request; return parsed JSON or the raw body string.
METHOD, URL-STR, POST-DATA and CONTENT-TYPE are as for `jenkins--http'."
  (let ((body (jenkins--http method url-str post-data content-type)))
    (condition-case nil
        (json-parse-string body
                           :object-type 'hash-table
                           :array-type 'list
                           :null-object nil
                           :false-object nil)
      (error body))))

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

(defun jenkins--fetch-jobs (&optional folder)
  "Fetch all jobs in FOLDER (nil for the root) and their last build metadata."
  (let ((resp (jenkins--request "GET" (jenkins--jobs-url folder))))
    (when (hash-table-p resp)
      (jenkins--get "jobs" resp))))

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

(defun jenkins--format-status (color building result)
  "Format build status with text properties."
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
   ((and (stringp color) (string-prefix-p "anime" color))
    (propertize "RUNNING" 'face '(:foreground "deep sky blue" :weight bold)))
   ((and (stringp color) (string-match-p "_anime$" color))
    (propertize "RUNNING" 'face '(:foreground "deep sky blue" :weight bold)))
   (t
    (propertize (or result (and (stringp color) color) "NOT BUILT") 'face 'font-lock-comment-face))))

;;; --- Tabulated List UI for Jobs ---

(defun jenkins--job-entries ()
  "Generate tabulated list entries from Jenkins jobs.
Each entry id is a cons (NAME . FOLDER-P)."
  (let ((jobs (jenkins--fetch-jobs jenkins--folder))
        entries)
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

(defun jenkins-current-job ()
  "Get the job name at point, or nil."
  (let ((id (tabulated-list-get-id)))
    (when (consp id) (car id))))

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

(defun jenkins-open-folder (folder)
  "Open a jobs buffer listing the jobs in FOLDER (a slash-separated path)."
  (let ((buf (get-buffer-create (format "*Jenkins: %s*" folder))))
    (with-current-buffer buf
      (jenkins-mode)
      (setq jenkins--folder folder)
      (jenkins-refresh))
    (pop-to-buffer-same-window buf)))

(defun jenkins-enter ()
  "Open the folder at point, or the build history of the job at point."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (unless (consp id)
      (user-error "No job selected"))
    (if (cdr id)
        (jenkins-open-folder (jenkins--join-path jenkins--folder (car id)))
      (jenkins-view-build-history (jenkins--join-path jenkins--folder (car id))))))

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
                   (p-default (when (hash-table-p default-obj)
                                (let ((val (jenkins--get "value" default-obj)))
                                  (when val (format "%s" val)))))
                   (choices (jenkins--get "choices" p))
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
    (run-at-time 2 nil #'jenkins-refresh)))

(defun jenkins-view-console (job &optional build-number)
  "View the console log for BUILD-NUMBER (default \"lastBuild\") of JOB."
  (interactive (list (jenkins--read-job "Console for job: ")))
  (let* ((build-id (or (and build-number (format "%s" build-number)) "lastBuild"))
         (url (jenkins--job-url job (format "/%s/consoleText" build-id)))
         (buf (get-buffer-create (format "*Jenkins-Console: %s #%s*" job build-id)))
         (output (jenkins--request "GET" url)))
    (with-current-buffer buf
      (read-only-mode -1)
      (erase-buffer)
      (insert (if (stringp output) output (format "%s" output)))
      (goto-char (point-max))
      (special-mode))
    (pop-to-buffer buf)))

(defun jenkins-abort-build (job)
  "Abort the running build for JOB."
  (interactive (list (jenkins--read-job "Abort job: ")))
  (when (yes-or-no-p (format "Abort active build for %s? " job))
    (jenkins--request "POST" (jenkins--job-url job "/lastBuild/stop"))
    (message "Requested abort for %s" job)
    (run-at-time 2 nil #'jenkins-refresh)))

(defun jenkins-open-in-browser (job)
  "Open JOB in external web browser."
  (interactive (list (jenkins--read-job "Open job: ")))
  (browse-url (jenkins--job-url job)))

;;; --- Build History Mode ---

(defun jenkins--fetch-build-history (job)
  "Fetch builds list for JOB."
  (let* ((tree "builds[number,result,building,duration,timestamp,displayName,description]")
         (resp (jenkins--request
                "GET" (jenkins--job-url job (format "/api/json?tree=%s"
                                                    (url-hexify-string tree))))))
    (when (hash-table-p resp)
      (jenkins--get "builds" resp))))

(defun jenkins--history-entries (job)
  "Generate tabulated list entries for build history of JOB."
  (let ((builds (jenkins--fetch-build-history job))
        entries)
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
                                (jenkins--format-duration duration)))
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
    (run-at-time 2 nil #'jenkins-history-refresh)))

(defun jenkins-history-open-in-browser (&optional build-num)
  "Open BUILD-NUM in external browser."
  (interactive (list (or (jenkins-current-build-number) (user-error "No build selected"))))
  (browse-url (jenkins--job-url jenkins--history-job (format "/%s" (or build-num "")))))

(defun jenkins-view-build-history (&optional job)
  "View the build history for JOB (a slash-separated path)."
  (interactive (list (jenkins--read-job "Job: ")))
  (unless job
    (user-error "No job selected"))
  (let ((buf (get-buffer-create (format "*Jenkins-History: %s*" job))))
    (with-current-buffer buf
      (jenkins-build-history-mode)
      (setq jenkins--history-job job)
      (jenkins-history-refresh))
    (pop-to-buffer buf)))

;;; --- Mode Definitions and Keymaps ---

(defvar jenkins-build-history-mode-map (make-sparse-keymap)
  "Keymap for `jenkins-build-history-mode` buffers.")
(set-keymap-parent jenkins-build-history-mode-map tabulated-list-mode-map)
(define-key jenkins-build-history-mode-map (kbd "g")   #'jenkins-history-refresh)
(define-key jenkins-build-history-mode-map (kbd "RET") #'jenkins-history-view-console)
(define-key jenkins-build-history-mode-map [return]    #'jenkins-history-view-console)
(define-key jenkins-build-history-mode-map (kbd "C-m") #'jenkins-history-view-console)
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
         ("Duration"  12 nil)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Build" t))
  (add-hook 'tabulated-list-revert-hook #'jenkins-history-refresh nil t)
  (tabulated-list-init-header))

(defvar jenkins-mode-map (make-sparse-keymap)
  "Keymap for `jenkins-mode` buffers.")
(set-keymap-parent jenkins-mode-map tabulated-list-mode-map)
(define-key jenkins-mode-map (kbd "g")   #'jenkins-refresh)
(define-key jenkins-mode-map (kbd "b")   #'jenkins-trigger-job)
(define-key jenkins-mode-map (kbd "RET") #'jenkins-enter)
(define-key jenkins-mode-map [return]    #'jenkins-enter)
(define-key jenkins-mode-map (kbd "C-m") #'jenkins-enter)
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
  (tabulated-list-init-header))

;;;###autoload
(defun jenkins ()
  "Open the Jenkins jobs overview buffer."
  (interactive)
  (let ((buf (get-buffer-create "*Jenkins*")))
    (with-current-buffer buf
      (jenkins-mode)
      (jenkins-refresh))
    (pop-to-buffer buf)))

;;;###autoload
(defun jenkins-reload ()
  "Force reload `jenkins-mode` and re-initialize any open Jenkins buffers."
  (interactive)
  (load-file (expand-file-name "~/code/jenkins-mode.el/jenkins-mode.el"))
  (when (get-buffer "*Jenkins*")
    (with-current-buffer "*Jenkins*"
      (jenkins-mode)
      (jenkins-refresh)))
  (message "jenkins-mode reloaded."))

(provide 'jenkins-mode)
;;; jenkins-mode.el ends here
