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
;; An interactive major mode to list jobs, filter running builds, trigger
;; parameterized and non-parameterized jobs, view build history, inspect
;; console logs, and abort builds.
;;
;; Credentials and Jenkins URL can be configured via customize options or
;; automatically loaded from `~/.jenkins_jobs.ini`.

;;; Code:

(require 'tabulated-list)
(require 'json)
(require 'url)
(require 'url-http)
(require 'auth-source)
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

(defcustom jenkins-auto-refresh-interval 15
  "Auto-refresh interval in seconds when in `jenkins-mode`.
Set to 0 or nil to disable auto-refresh."
  :type '(choice (const :tag "Disabled" nil) integer)
  :group 'jenkins)

(defvar-local jenkins--filter-running-only nil
  "Non-nil if only running builds are displayed.")

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
      (error "Jenkins URL not configured. Set `jenkins-url` or configure %s" jenkins-ini-path))
    (directory-file-name url)))

(defun jenkins--auth-header ()
  "Construct HTTP Basic Auth header."
  (let ((user (jenkins--get-config "user"))
        (pass (jenkins--get-config "password")))
    (when (and user pass)
      (format "Basic %s" (base64-encode-string (format "%s:%s" user pass) t)))))

;;; --- API & HTTP Helper ---

(defun jenkins--get (key obj)
  "Safely retrieve KEY from OBJ if OBJ is a hash-table, else nil.
Converts `:null` and `:json-false` values to nil."
  (when (hash-table-p obj)
    (let ((val (gethash key obj)))
      (if (memq val '(:null :json-false)) nil val))))

(defun jenkins--fetch-crumb ()
  "Fetch CSRF protection crumb, returns cons of (HEADER . VALUE) or nil."
  (condition-case nil
      (let* ((url (format "%s/crumbIssuer/api/json" (jenkins-base-url)))
             (res (jenkins--request "GET" url)))
        (when (hash-table-p res)
          (let ((field (jenkins--get "crumbRequestField" res))
                (crumb (jenkins--get "crumb" res)))
            (when (and field crumb)
              (cons field crumb)))))
    (error nil)))

(defun jenkins--request (method url-str &optional post-data content-type)
  "Synchronous HTTP request returning parsed JSON or raw string."
  (let ((url-request-method method)
        (url-request-extra-headers
         (delq nil
               (list (cons "Authorization" (jenkins--auth-header))
                     (when content-type (cons "Content-Type" content-type)))))
        (url-request-data post-data))
    (when (member method '("POST" "PUT" "DELETE"))
      (let ((crumb (jenkins--fetch-crumb)))
        (when crumb
          (push crumb url-request-extra-headers))))
    (with-current-buffer (url-retrieve-synchronously url-str t t)
      (goto-char (point-min))
      (re-search-forward "^$" nil t)
      (forward-char 1)
      (let ((body (buffer-substring-no-properties (point) (point-max))))
        (kill-buffer (current-buffer))
        (condition-case nil
            (json-parse-string body
                               :object-type 'hash-table
                               :array-type 'list
                               :null-object nil
                               :false-object nil)
          (error body))))))

;;; --- Core Jenkins Queries ---

(defun jenkins--fetch-jobs ()
  "Fetch all jobs and their last build metadata."
  (let* ((tree "jobs[name,color,lastBuild[number,building,result,duration,timestamp,estimatedDuration]]")
         (url (format "%s/api/json?tree=%s" (jenkins-base-url) (url-hexify-string tree)))
         (resp (jenkins--request "GET" url)))
    (if (hash-table-p resp)
        (jenkins--get "jobs" resp)
      nil)))

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
  "Generate tabulated list entries from Jenkins jobs."
  (let ((jobs (jenkins--fetch-jobs))
        entries)
    (dolist (job (if (listp jobs) jobs nil))
      (when (hash-table-p job)
        (let* ((name (jenkins--get "name" job))
               (color (jenkins--get "color" job))
               (last-build (jenkins--get "lastBuild" job))
               (num (jenkins--get "number" last-build))
               (building (jenkins--get "building" last-build))
               (result (jenkins--get "result" last-build))
               (duration (jenkins--get "duration" last-build))
               (status-str (jenkins--format-status color building result)))
          (when (and name
                     (or (not jenkins--filter-running-only)
                         building
                         (and (stringp color) (string-match-p "_anime$" color))))
            (push (list name
                        (vector (propertize name 'face 'font-lock-function-name-face)
                                status-str
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
  "Toggle between showing all jobs vs only running jobs."
  (interactive)
  (setq jenkins--filter-running-only (not jenkins--filter-running-only))
  (message (if jenkins--filter-running-only
               "Showing RUNNING jobs only"
             "Showing ALL jobs"))
  (jenkins-refresh))

(defun jenkins-current-job ()
  "Get the job name at point."
  (tabulated-list-get-id))

(defun jenkins-trigger-job (job-name)
  "Interactively trigger JOB-NAME, prompting for parameters if defined."
  (interactive
   (list (or (jenkins-current-job)
             (completing-read "Trigger Job: "
                              (delq nil
                                    (mapcar (lambda (j)
                                              (and (hash-table-p j)
                                                   (jenkins--get "name" j)))
                                            (jenkins--fetch-jobs)))))))
  (unless job-name
    (user-error "No job selected"))
  (let* ((url (format "%s/job/%s/api/json" (jenkins-base-url) job-name))
         (info (jenkins--request "GET" url))
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
        (let ((build-url (format "%s/job/%s/build" (jenkins-base-url) job-name)))
          (jenkins--request "POST" build-url)
          (message "Triggered '%s'" job-name))
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
        (let ((build-url (format "%s/job/%s/buildWithParameters?%s"
                                 (jenkins-base-url) job-name (string-join (nreverse query-params) "&"))))
          (jenkins--request "POST" build-url)
          (message "Triggered '%s' with parameters." job-name))))
    (run-at-time 2 nil #'jenkins-refresh)))

(defun jenkins-view-console (job-name &optional build-number)
  "View the console log for BUILD-NUMBER (default \"lastBuild\") of JOB-NAME."
  (interactive (list (or (jenkins-current-job) (user-error "No job selected"))))
  (let* ((build-id (or (and build-number (format "%s" build-number)) "lastBuild"))
         (url (format "%s/job/%s/%s/consoleText" (jenkins-base-url) job-name build-id))
         (buf (get-buffer-create (format "*Jenkins-Console: %s #%s*" job-name build-id)))
         (output (jenkins--request "GET" url)))
    (with-current-buffer buf
      (read-only-mode -1)
      (erase-buffer)
      (insert (if (stringp output) output (format "%s" output)))
      (goto-char (point-max))
      (special-mode))
    (pop-to-buffer buf)))

(defun jenkins-abort-build (job-name)
  "Abort the running build for JOB-NAME."
  (interactive (list (or (jenkins-current-job) (user-error "No job selected"))))
  (when (yes-or-no-p (format "Abort active build for %s? " job-name))
    (let ((url (format "%s/job/%s/lastBuild/stop" (jenkins-base-url) job-name)))
      (jenkins--request "POST" url)
      (message "Requested abort for %s" job-name)
      (run-at-time 2 nil #'jenkins-refresh))))

(defun jenkins-open-in-browser (job-name)
  "Open JOB-NAME in external web browser."
  (interactive (list (or (jenkins-current-job) (user-error "No job selected"))))
  (browse-url (format "%s/job/%s" (jenkins-base-url) job-name)))

;;; --- Build History Mode ---

(defvar-local jenkins--history-job-name nil
  "The job name for the current build history buffer.")

(defun jenkins--fetch-build-history (job-name)
  "Fetch builds list for JOB-NAME."
  (let* ((tree "builds[number,result,building,duration,timestamp,displayName,description]")
         (url (format "%s/job/%s/api/json?tree=%s"
                      (jenkins-base-url)
                      (url-hexify-string job-name)
                      (url-hexify-string tree)))
         (resp (jenkins--request "GET" url)))
    (if (hash-table-p resp)
        (jenkins--get "builds" resp)
      nil)))

(defun jenkins--history-entries (job-name)
  "Generate tabulated list entries for build history of JOB-NAME."
  (let ((builds (jenkins--fetch-build-history job-name))
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
  (when jenkins--history-job-name
    (setq tabulated-list-entries (jenkins--history-entries jenkins--history-job-name))
    (tabulated-list-print t)))

(defun jenkins-current-build-number ()
  "Get the build number at point in a build history buffer."
  (tabulated-list-get-id))

(defun jenkins-history-view-console (&optional build-num)
  "View console output for BUILD-NUM of the current job."
  (interactive (list (or (jenkins-current-build-number) (user-error "No build selected"))))
  (unless (and jenkins--history-job-name build-num)
    (user-error "Cannot view console: missing job or build number"))
  (jenkins-view-console jenkins--history-job-name build-num))

(defun jenkins-history-abort-build (&optional build-num)
  "Abort BUILD-NUM for the current job."
  (interactive (list (or (jenkins-current-build-number) (user-error "No build selected"))))
  (unless (and jenkins--history-job-name build-num)
    (user-error "Cannot abort: missing job or build number"))
  (when (yes-or-no-p (format "Abort %s #%s? " jenkins--history-job-name build-num))
    (let ((url (format "%s/job/%s/%s/stop" (jenkins-base-url) jenkins--history-job-name build-num)))
      (jenkins--request "POST" url)
      (message "Requested abort for %s #%s" jenkins--history-job-name build-num)
      (run-at-time 2 nil #'jenkins-history-refresh))))

(defun jenkins-history-open-in-browser (&optional build-num)
  "Open BUILD-NUM in external browser."
  (interactive (list (or (jenkins-current-build-number) (user-error "No build selected"))))
  (browse-url (format "%s/job/%s/%s" (jenkins-base-url) jenkins--history-job-name (or build-num ""))))

(defun jenkins-view-build-history (&optional job-name)
  "View the build history for JOB-NAME."
  (interactive (list (or (jenkins-current-job)
                         (completing-read "Job: "
                                          (delq nil
                                                (mapcar (lambda (j)
                                                          (and (hash-table-p j)
                                                               (jenkins--get "name" j)))
                                                        (jenkins--fetch-jobs)))))))
  (unless job-name
    (user-error "No job selected"))
  (let ((buf (get-buffer-create (format "*Jenkins-History: %s*" job-name))))
    (with-current-buffer buf
      (jenkins-build-history-mode)
      (setq jenkins--history-job-name job-name)
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
(define-key jenkins-mode-map (kbd "RET") #'jenkins-view-build-history)
(define-key jenkins-mode-map [return]    #'jenkins-view-build-history)
(define-key jenkins-mode-map (kbd "C-m") #'jenkins-view-build-history)
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
