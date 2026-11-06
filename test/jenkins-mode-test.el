;;; jenkins-mode-test.el --- Tests for jenkins-mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Justin Caratzas

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; ERT tests.  The HTTP layer is stubbed, so no Jenkins server is needed.
;;
;; Run with:
;;   emacs -Q --batch -L . -l test/jenkins-mode-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'jenkins-mode)

(defun jenkins-test--json (string)
  "Parse STRING the same way `jenkins--request' does."
  (json-parse-string string :object-type 'hash-table :array-type 'list
                     :null-object nil :false-object nil))

(defmacro jenkins-test--with-config (&rest body)
  "Run BODY with a fixed URL and credentials."
  `(let ((jenkins-url "https://ci.example.com/")
         (jenkins-username "bob")
         (jenkins-api-token "tok")
         (jenkins-view-name nil)
         (jenkins--crumb-cache nil))
     ,@body))

;;; Config

(ert-deftest jenkins-test-parse-ini ()
  (let ((file (make-temp-file "jenkins-ini")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "[other]\nurl=wrong\n[jenkins]\nurl = https://j.example.com\n"
                    "user=alice\npassword = s3cret\n"))
          (let ((ini (jenkins--parse-ini-file file)))
            (should (equal (cdr (assoc "url" ini)) "https://j.example.com"))
            (should (equal (cdr (assoc "user" ini)) "alice"))
            (should (equal (cdr (assoc "password" ini)) "s3cret"))))
      (delete-file file))))

(ert-deftest jenkins-test-config-prefers-custom-vars ()
  (let ((jenkins-url "https://custom")
        (jenkins-ini-path "/nonexistent"))
    (should (equal (jenkins--get-config "url") "https://custom"))
    (should (null (jenkins--get-config "user")))))

(ert-deftest jenkins-test-base-url-strips-slash ()
  (jenkins-test--with-config
   (should (equal (jenkins-base-url) "https://ci.example.com"))))

(ert-deftest jenkins-test-base-url-unconfigured ()
  (let ((jenkins-url nil) (jenkins-ini-path "/nonexistent"))
    (should-error (jenkins-base-url))))

(ert-deftest jenkins-test-auth-header ()
  (jenkins-test--with-config
   (should (equal (jenkins--auth-header)
                  (concat "Basic " (base64-encode-string "bob:tok" t))))))

;;; Paths

(ert-deftest jenkins-test-job-path ()
  (should (equal (jenkins--job-path nil) ""))
  (should (equal (jenkins--job-path "") ""))
  (should (equal (jenkins--job-path "a") "/job/a"))
  (should (equal (jenkins--job-path "a/b/c") "/job/a/job/b/job/c")))

(ert-deftest jenkins-test-job-path-encodes ()
  (should (equal (jenkins--job-path "my job/x&y") "/job/my%20job/job/x%26y"))
  ;; Multibranch job names already contain %2F; it must be encoded again.
  (should (equal (jenkins--job-path "proj/feature%2Ffoo")
                 "/job/proj/job/feature%252Ffoo")))

(ert-deftest jenkins-test-job-url ()
  (jenkins-test--with-config
   (should (equal (jenkins--job-url "f/j" "/build")
                  "https://ci.example.com/job/f/job/j/build"))
   (should (equal (jenkins--job-url nil) "https://ci.example.com"))))

(ert-deftest jenkins-test-join-path ()
  (should (equal (jenkins--join-path nil "a") "a"))
  (should (equal (jenkins--join-path "f" "j") "f/j"))
  (should (equal (jenkins--join-path "" "j") "j")))

(ert-deftest jenkins-test-jobs-url-root-folder-view ()
  (jenkins-test--with-config
   (should (string-prefix-p "https://ci.example.com/api/json?tree="
                            (jenkins--jobs-url nil)))
   (should (string-prefix-p "https://ci.example.com/job/f/job/g/api/json?tree="
                            (jenkins--jobs-url "f/g")))
   (let ((jenkins-view-name "My View"))
     (should (string-prefix-p "https://ci.example.com/view/My%20View/api/json"
                              (jenkins--jobs-url nil)))
     ;; Views only apply at the root.
     (should (string-prefix-p "https://ci.example.com/job/f/api/json"
                              (jenkins--jobs-url "f"))))))

(ert-deftest jenkins-test-jobs-url-requests-class ()
  (jenkins-test--with-config
   (should (string-match-p "_class" (url-unhex-string (jenkins--jobs-url nil))))))

;;; Formatting

(ert-deftest jenkins-test-get-nulls ()
  (let ((h (jenkins-test--json "{\"a\":null,\"b\":false,\"c\":1}")))
    (should (null (jenkins--get "a" h)))
    (should (null (jenkins--get "b" h)))
    (should (equal (jenkins--get "c" h) 1))
    (should (null (jenkins--get "x" nil)))))

(ert-deftest jenkins-test-format-duration ()
  (should (equal (jenkins--format-duration nil) "-"))
  (should (equal (jenkins--format-duration 0) "-"))
  (should (equal (jenkins--format-duration 5000) "5s"))
  (should (equal (jenkins--format-duration 125000) "2m 05s"))
  (should (equal (jenkins--format-duration 3725000) "1h 02m")))

(ert-deftest jenkins-test-format-timestamp ()
  (should (equal (jenkins--format-timestamp nil) "-"))
  (should (string-match-p "\\`[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]\\'"
                          (jenkins--format-timestamp 1700000000000))))

(ert-deftest jenkins-test-format-status ()
  (should (equal (substring-no-properties (jenkins--format-status nil t nil)) "RUNNING"))
  (should (equal (substring-no-properties (jenkins--format-status nil nil "SUCCESS")) "SUCCESS"))
  (should (equal (substring-no-properties (jenkins--format-status nil nil "FAILURE")) "FAILURE"))
  (should (equal (substring-no-properties (jenkins--format-status "blue_anime" nil nil)) "RUNNING"))
  (should (equal (substring-no-properties (jenkins--format-status nil nil nil)) "NOT BUILT")))

(ert-deftest jenkins-test-format-culprits ()
  (should (equal (jenkins--format-culprits nil) "-"))
  (should (equal (jenkins--format-culprits
                  (jenkins-test--json "[{\"fullName\":\"Ann\"},{\"fullName\":\"Bo\"}]"))
                 "Ann, Bo"))
  (should (equal (jenkins--format-culprits (jenkins-test--json "[{\"x\":1}]")) "-")))

(ert-deftest jenkins-test-console-text-strips-cr ()
  (should (equal (jenkins--console-text "a\r\nb\rc") "a\nbc")))

;;; Folders

(ert-deftest jenkins-test-folder-p ()
  (should (jenkins--folder-p (jenkins-test--json "{\"_class\":\"com.cloudbees.hudson.plugins.folder.Folder\"}")))
  (should (jenkins--folder-p (jenkins-test--json "{\"_class\":\"jenkins.branch.OrganizationFolder\"}")))
  (should (jenkins--folder-p (jenkins-test--json "{\"_class\":\"org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject\"}")))
  (should-not (jenkins--folder-p (jenkins-test--json "{\"_class\":\"hudson.model.FreeStyleProject\"}")))
  (should-not (jenkins--folder-p (jenkins-test--json "{\"name\":\"x\"}"))))

(defconst jenkins-test--jobs-json
  "{\"jobs\":[
     {\"_class\":\"com.cloudbees.hudson.plugins.folder.Folder\",\"name\":\"team\",\"color\":null},
     {\"_class\":\"hudson.model.FreeStyleProject\",\"name\":\"idle\",\"color\":\"blue\",
      \"lastBuild\":{\"number\":3,\"building\":false,\"result\":\"SUCCESS\",\"duration\":4000}},
     {\"_class\":\"hudson.model.FreeStyleProject\",\"name\":\"busy\",\"color\":\"red_anime\",
      \"lastBuild\":{\"number\":9,\"building\":true,\"result\":null,\"duration\":0}}]}")

(ert-deftest jenkins-test-job-entries ()
  (jenkins-test--with-config
   (cl-letf (((symbol-function 'jenkins--request)
              (lambda (&rest _) (jenkins-test--json jenkins-test--jobs-json))))
     (with-temp-buffer
       (let ((entries (jenkins--job-entries)))
         (should (= (length entries) 3))
         (should (equal (car (nth 0 entries)) '("team" . t)))
         (should (equal (car (nth 1 entries)) '("idle")))
         (should (equal (aref (cadr (nth 0 entries)) 0) "team/"))
         (should (equal (substring-no-properties (aref (cadr (nth 1 entries)) 2)) "#3")))
       (setq jenkins--filter-running-only t)
       (let ((entries (jenkins--job-entries)))
         ;; Folder stays visible, idle job is hidden.
         (should (equal (mapcar (lambda (e) (car (car e))) entries)
                        '("team" "busy"))))))))

(ert-deftest jenkins-test-job-entries-fetches-folder ()
  (jenkins-test--with-config
   (let (requested)
     (cl-letf (((symbol-function 'jenkins--request)
                (lambda (_m url &rest _) (setq requested url)
                  (jenkins-test--json "{\"jobs\":[]}"))))
       (with-temp-buffer
         (setq jenkins--folder "team/sub")
         (jenkins--job-entries)
         (should (string-prefix-p "https://ci.example.com/job/team/job/sub/api/json"
                                  requested)))))))

(ert-deftest jenkins-test-read-job-at-point ()
  (with-temp-buffer
    (jenkins-mode)
    (setq jenkins--folder "team")
    (setq tabulated-list-entries
          (list (list '("job1") (vector "job1" "" "" ""))
                (list '("sub" . t) (vector "sub/" "" "" ""))))
    (tabulated-list-print)
    (goto-char (point-min))
    (should (equal (jenkins--read-job "x: ") "team/job1"))
    (forward-line 1)
    (should-error (jenkins--read-job "x: ") :type 'user-error)))

(ert-deftest jenkins-test-enter-dispatch ()
  (with-temp-buffer
    (jenkins-mode)
    (setq tabulated-list-entries
          (list (list '("job1") (vector "job1" "" "" ""))
                (list '("sub" . t) (vector "sub/" "" "" ""))))
    (tabulated-list-print)
    (goto-char (point-min))
    (let (called)
      (cl-letf (((symbol-function 'jenkins-view-build-history)
                 (lambda (job) (push (list 'history job) called)))
                ((symbol-function 'jenkins-open-folder)
                 (lambda (f) (push (list 'folder f) called))))
        (jenkins-enter)
        (forward-line 1)
        (jenkins-enter))
      (should (equal (nreverse called)
                     '((history "job1") (folder "sub")))))))

;;; History

(ert-deftest jenkins-test-format-description ()
  (should (equal (jenkins--format-description nil) "-"))
  (should (equal (jenkins--format-description "") "-"))
  (should (equal (jenkins--format-description "  \n ") "-"))
  (should (equal (jenkins--format-description "plain text") "plain text"))
  (should (equal (jenkins--format-description "line1\nline2\r\n  line3") "line1 line2 line3"))
  (should (equal (jenkins--format-description "<b>Deploy</b> to <a href=\"/x\">prod</a><br/>now<br>ok")
                 "Deploy to prod now ok"))
  (should (equal (jenkins--format-description "a &lt;b&gt; &amp; &quot;c&quot; &#39;d&#39;&nbsp;e")
                 "a <b> & \"c\" 'd' e"))
  ;; &amp;lt; must decode to the literal text &lt;, not to <.
  (should (equal (jenkins--format-description "&amp;lt;") "&lt;")))

(ert-deftest jenkins-test-history-entries-include-author-and-description ()
  (jenkins-test--with-config
   (cl-letf (((symbol-function 'jenkins--request)
              (lambda (&rest _)
                (jenkins-test--json
                 "{\"builds\":[
                    {\"number\":7,\"result\":\"FAILURE\",\"building\":false,
                     \"duration\":65000,\"timestamp\":1700000000000,
                     \"culprits\":[{\"fullName\":\"Ann\"}],
                     \"description\":\"<b>hotfix</b> for #12\"},
                    {\"number\":6,\"result\":\"SUCCESS\",\"building\":false,
                     \"duration\":1000,\"timestamp\":1700000000000,
                     \"culprits\":[],\"description\":null}]}"))))
     (let* ((entries (jenkins--history-entries "team/job"))
            (row (cadr (car entries)))
            (row2 (cadr (cadr entries))))
       (should (= (car (car entries)) 7))
       (should (= (length row) 6))
       (should (equal (aref row 3) "Ann"))
       (should (equal (aref row 4) "1m 05s"))
       (should (equal (aref row 5) "hotfix for #12"))
       (should (equal (aref row2 5) "-"))))))

(ert-deftest jenkins-test-history-url-has-limit-and-culprits ()
  (jenkins-test--with-config
   (let ((jenkins-history-limit 12) requested)
     (cl-letf (((symbol-function 'jenkins--request)
                (lambda (_m url &rest _) (setq requested url) nil)))
       (jenkins--fetch-build-history "team/job")
       (should (string-prefix-p "https://ci.example.com/job/team/job/job/api/json?tree="
                                requested))
       (let ((tree (url-unhex-string (cadr (split-string requested "tree=")))))
         (should (string-match-p "culprits\\[fullName\\]" tree))
         (should (string-match-p "{0,12}" tree)))))))

(ert-deftest jenkins-test-history-mode-has-author-column ()
  (with-temp-buffer
    (jenkins-build-history-mode)
    (should (equal (mapcar #'car (append tabulated-list-format nil))
                   '("Build" "Status" "Timestamp" "Author" "Duration" "Description")))))

;;; Actions

(ert-deftest jenkins-test-trigger-simple-job ()
  (jenkins-test--with-config
   (let (calls)
     (cl-letf (((symbol-function 'jenkins--request)
                (lambda (method url &rest _)
                  (push (cons method url) calls)
                  (if (string-suffix-p "/api/json" url)
                      (jenkins-test--json "{\"property\":[{}]}")
                    ""))))
       (jenkins-trigger-job "team/job")
       (should (member '("POST" . "https://ci.example.com/job/team/job/job/build") calls))))))

(ert-deftest jenkins-test-trigger-parameterized-job ()
  (jenkins-test--with-config
   (let (calls)
     (cl-letf (((symbol-function 'jenkins--request)
                (lambda (method url &rest _)
                  (push (cons method url) calls)
                  (if (string-suffix-p "/api/json" url)
                      (jenkins-test--json
                       "{\"property\":[{\"parameterDefinitions\":[
                          {\"name\":\"BRANCH\",\"description\":\"b\",
                           \"defaultParameterValue\":{\"value\":\"main\"}},
                          {\"name\":\"ENV\",\"choices\":[\"dev\",\"prod\"]}]}]}")
                    "")))
               ((symbol-function 'read-string) (lambda (&rest _) "feat x"))
               ((symbol-function 'completing-read) (lambda (&rest _) "prod")))
       (jenkins-trigger-job "job")
       (should (member '("POST" . "https://ci.example.com/job/job/buildWithParameters?BRANCH=feat%20x&ENV=prod")
                       calls))))))

(ert-deftest jenkins-test-trigger-boolean-parameter ()
  (jenkins-test--with-config
   (let (calls prompts)
     (cl-letf (((symbol-function 'jenkins--request)
                (lambda (method url &rest _)
                  (push (cons method url) calls)
                  (if (string-suffix-p "/api/json" url)
                      (jenkins-test--json
                       "{\"property\":[{\"parameterDefinitions\":[
                          {\"_class\":\"hudson.model.BooleanParameterDefinition\",
                           \"name\":\"DRY\",\"defaultParameterValue\":{\"value\":true}},
                          {\"_class\":\"hudson.model.BooleanParameterDefinition\",
                           \"name\":\"CLEAN\",\"defaultParameterValue\":{\"value\":false}}]}]}")
                    "")))
               ((symbol-function 'completing-read)
                (lambda (_prompt coll _p _r default &rest _)
                  (push (cons coll default) prompts)
                  default)))
       (jenkins-trigger-job "job")
       (should (member '("POST" . "https://ci.example.com/job/job/buildWithParameters?DRY=true&CLEAN=false")
                       calls))
       (should (equal (reverse prompts)
                      '((("true" "false") . "true") (("true" "false") . "false"))))))))

(ert-deftest jenkins-test-abort-urls ()
  (jenkins-test--with-config
   (let (calls)
     (cl-letf (((symbol-function 'jenkins--request)
                (lambda (method url &rest _) (push (cons method url) calls) ""))
               ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
       (jenkins-abort-build "f/j")
       (with-temp-buffer
         (jenkins-build-history-mode)
         (setq jenkins--history-job "f/j")
         (jenkins-history-abort-build 12))
       (should (member '("POST" . "https://ci.example.com/job/f/job/j/lastBuild/stop") calls))
       (should (member '("POST" . "https://ci.example.com/job/f/job/j/12/stop") calls))))))

(ert-deftest jenkins-test-view-console-strips-cr ()
  (jenkins-test--with-config
   (cl-letf (((symbol-function 'jenkins--http)
              (lambda (&rest _) "line1\r\nline2\r\n"))
             ((symbol-function 'pop-to-buffer) #'ignore))
     (jenkins-view-console "f/j" 5)
     (with-current-buffer "*Jenkins-Console: f/j #5*"
       (unwind-protect
           (progn
             (should (equal (buffer-string) "line1\nline2\n"))
             (should (derived-mode-p 'jenkins-console-mode))
             (should buffer-read-only))
         (kill-buffer))))))

;;; Failed loads

(defun jenkins-test--jenkins-buffers ()
  "Return the names of live buffers that start with \"*Jenkins\"."
  (sort (cl-loop for b in (buffer-list)
                 when (string-prefix-p "*Jenkins" (buffer-name b))
                 collect (buffer-name b))
        #'string<))

(ert-deftest jenkins-test-failed-first-load-leaves-no-buffer ()
  (jenkins-test--with-config
   (let ((before (jenkins-test--jenkins-buffers)))
     (cl-letf (((symbol-function 'jenkins--request)
                (lambda (&rest _) (error "Jenkins returned HTTP 401")))
               ((symbol-function 'pop-to-buffer) #'ignore)
               ((symbol-function 'pop-to-buffer-same-window) #'ignore))
       (dolist (open (list #'jenkins
                           (lambda () (jenkins-open-folder "a/b"))
                           (lambda () (jenkins-view-build-history "a/b"))))
         (let ((err (should-error (funcall open))))
           (should (string-match-p "HTTP 401" (error-message-string err))))))
     (should (equal (jenkins-test--jenkins-buffers) before)))))

(ert-deftest jenkins-test-failed-reopen-keeps-existing-buffer ()
  (jenkins-test--with-config
   (let ((fail nil))
     (cl-letf (((symbol-function 'jenkins--request)
                (lambda (&rest _)
                  (if fail
                      (error "Jenkins returned HTTP 503")
                    (jenkins-test--json
                     "{\"jobs\":[{\"_class\":\"hudson.model.FreeStyleProject\",\"name\":\"j1\"}]}"))))
               ((symbol-function 'pop-to-buffer) #'ignore))
       (unwind-protect
           (progn
             (jenkins)
             (setq fail t)
             (should-error (jenkins))
             (with-current-buffer "*Jenkins*"
               (should (derived-mode-p 'jenkins-mode))
               (should (= (length tabulated-list-entries) 1))))
         (when (get-buffer "*Jenkins*")
           (kill-buffer "*Jenkins*")))))))

;;; HTTP layer

(defvar jenkins-test--http-calls nil
  "Requests seen by the stubbed `url-retrieve-synchronously'.
Each element is a plist (:method :url :headers :data), newest first.")

(defun jenkins-test--response-buffer (status body)
  "Return a unibyte buffer holding an HTTP response with STATUS and BODY.
Header lines end in a bare newline, as `url-http' leaves them."
  (let ((buf (generate-new-buffer " *jenkins-test-response*")))
    (with-current-buffer buf
      (set-buffer-multibyte nil)
      (insert (format "HTTP/1.1 %d X\nContent-Type: text/plain\n\n" status)
              (encode-coding-string body 'utf-8))
      (setq-local url-http-response-status status))
    buf))

(defmacro jenkins-test--with-http (responses &rest body)
  "Run BODY with `url-retrieve-synchronously' stubbed.
RESPONSES is a form evaluating to an alist of (URL-SUFFIX STATUS . BODY).
The first entry whose suffix matches the request URL is used; a URL with
no match gets a 404.  Requests are recorded in `jenkins-test--http-calls'."
  (declare (indent 1))
  `(let ((jenkins-test--http-calls nil)
         (responses ,responses))
     (cl-letf (((symbol-function 'url-retrieve-synchronously)
                (lambda (url &rest _)
                  (push (list :method url-request-method
                              :url url
                              :headers url-request-extra-headers
                              :data url-request-data)
                        jenkins-test--http-calls)
                  (let ((hit (cl-find-if (lambda (r) (string-suffix-p (car r) url))
                                         responses)))
                    (jenkins-test--response-buffer
                     (if hit (cadr hit) 404)
                     (if hit (cddr hit) ""))))))
       ,@body)))

(defun jenkins-test--calls-to (suffix)
  "Return the recorded requests whose URL ends with SUFFIX, oldest first."
  (nreverse (cl-remove-if-not (lambda (c) (string-suffix-p suffix (plist-get c :url)))
                              jenkins-test--http-calls)))

(ert-deftest jenkins-test-http-get-sends-auth-without-crumb ()
  (jenkins-test--with-config
   (jenkins-test--with-http '(("/x" 200 . "hello"))
     (should (equal (jenkins--http "GET" "https://ci.example.com/x") "hello"))
     (should (= (length jenkins-test--http-calls) 1))
     (let ((call (car jenkins-test--http-calls)))
       (should (equal (plist-get call :method) "GET"))
       (should (equal (cdr (assoc "Authorization" (plist-get call :headers)))
                      (jenkins--auth-header)))
       (should-not (assoc "Jenkins-Crumb" (plist-get call :headers)))))))

(ert-deftest jenkins-test-http-post-attaches-crumb ()
  (jenkins-test--with-config
   (jenkins-test--with-http
       '(("/crumbIssuer/api/json" 200 . "{\"crumbRequestField\":\"Jenkins-Crumb\",\"crumb\":\"abc123\"}")
         ("/build" 201 . ""))
     (should (equal (jenkins--http "POST" "https://ci.example.com/job/j/build") ""))
     (let ((post (car (jenkins-test--calls-to "/build"))))
       (should (equal (plist-get post :method) "POST"))
       (should (equal (cdr (assoc "Jenkins-Crumb" (plist-get post :headers))) "abc123"))
       (should (assoc "Authorization" (plist-get post :headers))))
     ;; The crumb itself is fetched with GET.
     (should (equal (plist-get (car (jenkins-test--calls-to "/crumbIssuer/api/json")) :method)
                    "GET")))))

(ert-deftest jenkins-test-http-post-without-crumb-endpoint ()
  (jenkins-test--with-config
   (jenkins-test--with-http '(("/build" 201 . ""))
     (should (equal (jenkins--http "POST" "https://ci.example.com/job/j/build") ""))
     (let ((post (car (jenkins-test--calls-to "/build"))))
       (should (equal (plist-get post :method) "POST"))
       (should (assoc "Authorization" (plist-get post :headers)))
       (should (= (length (plist-get post :headers)) 1))))))

(ert-deftest jenkins-test-http-crumb-is-cached ()
  (jenkins-test--with-config
   (jenkins-test--with-http
       '(("/crumbIssuer/api/json" 200 . "{\"crumbRequestField\":\"Jenkins-Crumb\",\"crumb\":\"abc123\"}")
         ("/build" 201 . ""))
     (dotimes (_ 3)
       (jenkins--http "POST" "https://ci.example.com/job/j/build"))
     (should (= (length (jenkins-test--calls-to "/crumbIssuer/api/json")) 1))
     (should (= (length (jenkins-test--calls-to "/build")) 3))
     (dolist (post (jenkins-test--calls-to "/build"))
       (should (equal (cdr (assoc "Jenkins-Crumb" (plist-get post :headers))) "abc123"))))))

(ert-deftest jenkins-test-http-crumb-cache-is-per-server-and-user ()
  (jenkins-test--with-config
   (jenkins-test--with-http
       '(("/crumbIssuer/api/json" 200 . "{\"crumbRequestField\":\"Jenkins-Crumb\",\"crumb\":\"abc123\"}")
         ("/build" 201 . ""))
     (jenkins--http "POST" "https://ci.example.com/job/j/build")
     (let ((jenkins-username "alice"))
       (jenkins--http "POST" "https://ci.example.com/job/j/build"))
     (let ((jenkins-url "https://other.example.com"))
       (jenkins--http "POST" "https://other.example.com/job/j/build"))
     (should (= (length (jenkins-test--calls-to "/crumbIssuer/api/json")) 3)))))

(ert-deftest jenkins-test-http-missing-crumb-endpoint-is-not-cached ()
  (jenkins-test--with-config
   (jenkins-test--with-http '(("/build" 201 . ""))
     (jenkins--http "POST" "https://ci.example.com/job/j/build")
     (jenkins--http "POST" "https://ci.example.com/job/j/build")
     (should (null jenkins--crumb-cache))
     (should (= (length (jenkins-test--calls-to "/crumbIssuer/api/json")) 2)))))

(ert-deftest jenkins-test-http-get-does-not-fetch-crumb ()
  (jenkins-test--with-config
   (jenkins-test--with-http '(("/x" 200 . "ok"))
     (jenkins--http "GET" "https://ci.example.com/x")
     (should (null (jenkins-test--calls-to "/crumbIssuer/api/json"))))))

(ert-deftest jenkins-test-http-403-refreshes-crumb-and-retries-once ()
  (jenkins-test--with-config
   (let ((issued 1) (posts nil))        ; c1 is already in the cache
     (cl-letf (((symbol-function 'url-retrieve-synchronously)
                (lambda (url &rest _)
                  (cond
                   ((string-suffix-p "/crumbIssuer/api/json" url)
                    (setq issued (1+ issued))
                    (jenkins-test--response-buffer
                     200 (format "{\"crumbRequestField\":\"Jenkins-Crumb\",\"crumb\":\"c%d\"}" issued)))
                   (t
                    (let ((sent (cdr (assoc "Jenkins-Crumb" url-request-extra-headers))))
                      (push sent posts)
                      ;; Only the second crumb is accepted.
                      (jenkins-test--response-buffer (if (equal sent "c2") 201 403) "")))))))
       ;; Prime the cache with c1, then it goes stale.
       (setq jenkins--crumb-cache (cons (jenkins--crumb-key) '("Jenkins-Crumb" . "c1")))
       (should (equal (jenkins--http "POST" "https://ci.example.com/job/j/build") ""))
       (should (equal (reverse posts) '("c1" "c2")))
       (should (equal (cdr (cdr jenkins--crumb-cache)) "c2"))))))

(ert-deftest jenkins-test-http-403-does-not-retry-forever ()
  (jenkins-test--with-config
   (let ((posts 0))
     (cl-letf (((symbol-function 'url-retrieve-synchronously)
                (lambda (url &rest _)
                  (if (string-suffix-p "/crumbIssuer/api/json" url)
                      (jenkins-test--response-buffer
                       200 "{\"crumbRequestField\":\"Jenkins-Crumb\",\"crumb\":\"same\"}")
                    (setq posts (1+ posts))
                    (jenkins-test--response-buffer 403 "")))))
       (let ((err (should-error (jenkins--http "POST" "https://ci.example.com/job/j/build"))))
         (should (string-match-p "403" (error-message-string err))))
       ;; Same crumb comes back, so there is nothing to retry with.
       (should (= posts 1))))))

(ert-deftest jenkins-test-http-sends-data-and-content-type ()
  (jenkins-test--with-config
   (jenkins-test--with-http '(("/x" 200 . "ok"))
     (jenkins--http "PUT" "https://ci.example.com/x" "a=1" "application/x-www-form-urlencoded")
     (let ((call (car (jenkins-test--calls-to "/x"))))
       (should (equal (plist-get call :data) "a=1"))
       (should (equal (cdr (assoc "Content-Type" (plist-get call :headers)))
                      "application/x-www-form-urlencoded"))))))

(ert-deftest jenkins-test-http-error-statuses ()
  (jenkins-test--with-config
   (dolist (status '(400 401 403 404 500 503))
     (jenkins-test--with-http `(("/x" ,status . "nope"))
       (let ((err (should-error (jenkins--http "GET" "https://ci.example.com/x"))))
         (should (string-match-p (number-to-string status) (error-message-string err))))))))

(ert-deftest jenkins-test-http-no-response-buffer ()
  (jenkins-test--with-config
   (cl-letf (((symbol-function 'url-retrieve-synchronously) (lambda (&rest _) nil)))
     (should-error (jenkins--http "GET" "https://ci.example.com/x")))))

(ert-deftest jenkins-test-http-decodes-utf-8 ()
  (jenkins-test--with-config
   (jenkins-test--with-http '(("/x" 200 . "caf\u00e9 \u2713"))
     (should (equal (jenkins--http "GET" "https://ci.example.com/x") "caf\u00e9 \u2713")))))

(ert-deftest jenkins-test-http-kills-response-buffer ()
  (jenkins-test--with-config
   (let ((before (buffer-list)))
     (jenkins-test--with-http '(("/x" 200 . "hi") ("/y" 500 . "no"))
       (jenkins--http "GET" "https://ci.example.com/x")
       (ignore-errors (jenkins--http "GET" "https://ci.example.com/y")))
     (should (equal (buffer-list) before)))))

(ert-deftest jenkins-test-request-parses-json-or-returns-raw ()
  (jenkins-test--with-config
   (jenkins-test--with-http '(("/j" 200 . "{\"a\":[1,null,false]}")
                              ("/t" 200 . "plain text\nlog")
                              ("/e" 201 . ""))
     (let ((parsed (jenkins--request "GET" "https://ci.example.com/j")))
       (should (hash-table-p parsed))
       (should (equal (gethash "a" parsed) '(1 nil nil))))
     (should (equal (jenkins--request "GET" "https://ci.example.com/t") "plain text\nlog"))
     (should (equal (jenkins--request "POST" "https://ci.example.com/e") "")))))

;;; Async requests

(defun jenkins-test--stub-retrieve (status body &optional error-plist)
  "Return a stand-in for `url-retrieve' that answers with STATUS and BODY.
The callback runs immediately, in a fresh response buffer, with
ERROR-PLIST as its status argument."
  (lambda (url callback &rest _)
    (push (list :url url
                :method url-request-method
                :headers url-request-extra-headers)
          jenkins-test--http-calls)
    (let ((buf (jenkins-test--response-buffer status body)))
      (with-current-buffer buf
        (funcall callback error-plist))
      buf)))

(defun jenkins-test--async (stub &optional url)
  "Run `jenkins--request-async' with the `url-retrieve' replacement STUB.
Return the list of callback invocations, each (RESULT ERROR)."
  (let (calls (jenkins-test--http-calls nil))
    (cl-letf (((symbol-function 'url-retrieve) stub))
      (jenkins--request-async (or url "https://ci.example.com/x")
                              (lambda (r e) (push (list r e) calls))))
    (nreverse calls)))

(ert-deftest jenkins-test-async-success-parses-json ()
  (jenkins-test--with-config
   (let ((calls (jenkins-test--async
                 (jenkins-test--stub-retrieve 200 "{\"a\":1}"))))
     (should (= (length calls) 1))
     (should (null (cadr (car calls))))
     (should (= (gethash "a" (car (car calls))) 1)))))

(ert-deftest jenkins-test-async-returns-raw-text-when-not-json ()
  (jenkins-test--with-config
   (should (equal (jenkins-test--async (jenkins-test--stub-retrieve 200 "plain"))
                  '(("plain" nil))))))

(ert-deftest jenkins-test-async-sends-auth-header-with-get ()
  (jenkins-test--with-config
   (let ((jenkins-test--http-calls nil))
     (cl-letf (((symbol-function 'url-retrieve) (jenkins-test--stub-retrieve 200 "{}")))
       (jenkins--request-async "https://ci.example.com/x" #'ignore))
     (let ((call (car jenkins-test--http-calls)))
       (should (equal (plist-get call :method) "GET"))
       (should (equal (cdr (assoc "Authorization" (plist-get call :headers)))
                      (jenkins--auth-header)))))))

(ert-deftest jenkins-test-async-http-error-reaches-callback ()
  (jenkins-test--with-config
   (dolist (status '(401 403 404 500))
     (let* ((calls (jenkins-test--async (jenkins-test--stub-retrieve status "no")))
            (call (car calls)))
       (should (= (length calls) 1))
       (should (null (car call)))
       (should (string-match-p (format "HTTP %d" status) (cadr call)))))))

(ert-deftest jenkins-test-async-connection-error-reaches-callback ()
  (jenkins-test--with-config
   (let ((calls (jenkins-test--async
                 (jenkins-test--stub-retrieve 0 "" '(:error (error connection-failed "refused"))))))
     (should (= (length calls) 1))
     (should (null (car (car calls))))
     (should (string-match-p "connection-failed" (cadr (car calls)))))))

(ert-deftest jenkins-test-async-kills-response-buffer ()
  (jenkins-test--with-config
   (let ((before (buffer-list)))
     (jenkins-test--async (jenkins-test--stub-retrieve 200 "{}"))
     (jenkins-test--async (jenkins-test--stub-retrieve 500 ""))
     (should (equal (buffer-list) before)))))

(ert-deftest jenkins-test-async-callback-error-does-not-escape ()
  (jenkins-test--with-config
   (cl-letf (((symbol-function 'url-retrieve) (jenkins-test--stub-retrieve 200 "{}")))
     (jenkins--request-async "https://ci.example.com/x"
                             (lambda (&rest _) (error "boom")))
     (should t))))

(ert-deftest jenkins-test-async-times-out-once ()
  (jenkins-test--with-config
   (let ((jenkins-request-timeout 0.05)
         (late nil)
         (calls nil)
         (buf (generate-new-buffer " *jenkins-test-pending*")))
     (cl-letf (((symbol-function 'url-retrieve)
                (lambda (_url callback &rest _)
                  (setq late (lambda ()
                               (with-current-buffer
                                   (jenkins-test--response-buffer 200 "{}")
                                 (funcall callback nil))))
                  buf)))
       (jenkins--request-async "https://ci.example.com/x"
                               (lambda (r e) (push (list r e) calls))))
     (accept-process-output nil 0.3)
     (should (= (length calls) 1))
     (should (null (car (car calls))))
     (should (string-match-p "timed out" (cadr (car calls))))
     (should-not (buffer-live-p buf))
     ;; A response that shows up after the timeout is ignored.
     (funcall late)
     (should (= (length calls) 1)))))

(ert-deftest jenkins-test-async-leaves-no-timer-when-answer-is-immediate ()
  (jenkins-test--with-config
   (let ((jenkins-request-timeout 600)
         (before (copy-sequence timer-list)))
     (cl-letf (((symbol-function 'url-retrieve) (jenkins-test--stub-retrieve 200 "{}")))
       (jenkins--request-async "https://ci.example.com/x" #'ignore))
     (should (equal timer-list before)))))

(ert-deftest jenkins-test-async-cancels-timer-when-answer-comes-later ()
  (jenkins-test--with-config
   (let ((jenkins-request-timeout 600)
         (before (copy-sequence timer-list))
         callback)
     (cl-letf (((symbol-function 'url-retrieve)
                (lambda (_url cb &rest _)
                  (setq callback cb)
                  (generate-new-buffer " *jenkins-test-pending*"))))
       (jenkins--request-async "https://ci.example.com/x" #'ignore))
     (should-not (equal timer-list before))
     (with-current-buffer (jenkins-test--response-buffer 200 "{}")
       (funcall callback nil))
     (should (equal timer-list before)))))

;;; Background refresh

(defvar jenkins-test--async-urls nil
  "URLs requested through the stubbed `jenkins--request-async', newest first.")

(defun jenkins-test--async-answering (body &optional error-message)
  "Return a `jenkins--request-async' replacement that answers with BODY.
It records the requested URLs in `jenkins-test--async-urls'.  With
ERROR-MESSAGE the callback gets an error instead."
  (lambda (url callback)
    (push url jenkins-test--async-urls)
    (funcall callback
             (and (not error-message) (jenkins-test--json body))
             error-message)))

(ert-deftest jenkins-test-refresh-current-updates-jobs-buffer ()
  (jenkins-test--with-config
   (let ((jenkins-test--async-urls nil))
     (cl-letf (((symbol-function 'jenkins--request-async)
                (jenkins-test--async-answering jenkins-test--jobs-json)))
       (with-temp-buffer
         (jenkins-mode)
         (setq jenkins--folder "team")
         (jenkins--refresh-current)
         (should (= (length tabulated-list-entries) 3))
         (should (null jenkins--refresh-in-flight))
         (should (string-prefix-p "https://ci.example.com/job/team/api/json"
                                  (car jenkins-test--async-urls))))))))

(ert-deftest jenkins-test-refresh-current-updates-history-buffer ()
  (jenkins-test--with-config
   (let ((jenkins-test--async-urls nil))
     (cl-letf (((symbol-function 'jenkins--request-async)
                (jenkins-test--async-answering
                 "{\"builds\":[{\"number\":4,\"result\":\"SUCCESS\",\"building\":false}]}")))
       (with-temp-buffer
         (jenkins-build-history-mode)
         (setq jenkins--history-job "team/job")
         (jenkins--refresh-current)
         (should (equal (mapcar #'car tabulated-list-entries) '(4)))
         (should (string-prefix-p "https://ci.example.com/job/team/job/job/api/json?tree="
                                  (car jenkins-test--async-urls))))))))

(ert-deftest jenkins-test-refresh-current-keeps-rows-on-error ()
  (jenkins-test--with-config
   (cl-letf (((symbol-function 'jenkins--request-async)
              (jenkins-test--async-answering nil "Jenkins returned HTTP 503")))
     (with-temp-buffer
       (jenkins-mode)
       (setq tabulated-list-entries (list (list '("old") (vector "old" "" "" ""))))
       (let ((before tabulated-list-entries))
         (jenkins--refresh-current)
         (should (eq tabulated-list-entries before))
         (should (null jenkins--refresh-in-flight)))))))

(ert-deftest jenkins-test-refresh-current-skips-while-in-flight ()
  (jenkins-test--with-config
   (let (pending (calls 0))
     (cl-letf (((symbol-function 'jenkins--request-async)
                (lambda (_url callback) (cl-incf calls) (setq pending callback))))
       (with-temp-buffer
         (jenkins-mode)
         (jenkins--refresh-current)
         (jenkins--refresh-current)
         (should (= calls 1))
         (should jenkins--refresh-in-flight)
         ;; Once the answer arrives the next refresh goes through again.
         (funcall pending (jenkins-test--json jenkins-test--jobs-json) nil)
         (should-not jenkins--refresh-in-flight)
         (jenkins--refresh-current)
         (should (= calls 2)))))))

(ert-deftest jenkins-test-refresh-current-ignores-killed-buffer ()
  (jenkins-test--with-config
   (let (pending)
     (cl-letf (((symbol-function 'jenkins--request-async)
                (lambda (_url callback) (setq pending callback))))
       (with-temp-buffer
         (jenkins-mode)
         (jenkins--refresh-current))
       (funcall pending (jenkins-test--json jenkins-test--jobs-json) nil)
       (should t)))))

(ert-deftest jenkins-test-refresh-current-clears-flag-when-send-fails ()
  (jenkins-test--with-config
   (cl-letf (((symbol-function 'jenkins--request-async)
              (lambda (&rest _) (error "cannot send"))))
     (with-temp-buffer
       (jenkins-mode)
       (should-error (jenkins--refresh-current))
       (should-not jenkins--refresh-in-flight)))))

(ert-deftest jenkins-test-refresh-current-needs-history-job ()
  (jenkins-test--with-config
   (let ((calls 0))
     (cl-letf (((symbol-function 'jenkins--request-async)
                (lambda (&rest _) (cl-incf calls))))
       (with-temp-buffer
         (jenkins-build-history-mode)
         (jenkins--refresh-current)
         (should (= calls 0)))))))

;;; Auto refresh

(ert-deftest jenkins-test-timer-lifecycle ()
  (let ((jenkins--refresh-timer nil)
        (jenkins-auto-refresh-interval 600))
    (unwind-protect
        (progn
          (jenkins--ensure-timer)
          (should (timerp jenkins--refresh-timer))
          (let ((first jenkins--refresh-timer))
            (jenkins--ensure-timer)
            (should (eq first jenkins--refresh-timer)))
          ;; No Jenkins buffers exist, so a tick stops the timer.
          (jenkins--timer-tick)
          (should (null jenkins--refresh-timer)))
      (jenkins--stop-timer))))

(ert-deftest jenkins-test-timer-disabled ()
  (let ((jenkins--refresh-timer nil))
    (dolist (v '(nil 0))
      (let ((jenkins-auto-refresh-interval v))
        (jenkins--ensure-timer)
        (should (null jenkins--refresh-timer))))))

(provide 'jenkins-mode-test)
;;; jenkins-mode-test.el ends here
