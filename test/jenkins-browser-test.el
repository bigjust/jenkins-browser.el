;;; jenkins-browser-test.el --- Tests for jenkins-browser -*- lexical-binding: t; -*-

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
;;   emacs -Q --batch -L . -l test/jenkins-browser-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'jenkins-browser)

(defun jenkins-browser-test--json (string)
  "Parse STRING the same way `jenkins-browser--request' does."
  (json-parse-string string :object-type 'hash-table :array-type 'list
                     :null-object nil :false-object nil))

(defmacro jenkins-browser-test--with-config (&rest body)
  "Run BODY with a fixed URL and credentials."
  `(let ((jenkins-browser-url "https://ci.example.com/")
         (jenkins-browser-username "bob")
         (jenkins-browser-api-token "tok")
         (jenkins-browser-view-name nil)
         (jenkins-browser--crumb-cache nil)
         (auth-sources nil))
     ,@body))

(defmacro jenkins-browser-test--with-authinfo (contents &rest body)
  "Run BODY with CONTENTS as the only `auth-source' file and no INI file."
  (declare (indent 1))
  `(let ((file (make-temp-file "jenkins-browser-authinfo"))
         (auth-source-do-cache nil)
         (jenkins-browser-url "https://ci.example.com/")
         (jenkins-browser-username nil)
         (jenkins-browser-api-token nil)
         (jenkins-browser-ini-path "/nonexistent"))
     (unwind-protect
         (progn
           (with-temp-file file (insert ,contents))
           (let ((auth-sources (list file)))
             ,@body))
       (delete-file file))))

;;; Config

(ert-deftest jenkins-browser-test-parse-ini ()
  (let ((file (make-temp-file "jenkins-browser-ini")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "[other]\nurl=wrong\n[jenkins]\nurl = https://j.example.com\n"
                    "user=alice\npassword = s3cret\n"))
          (let ((ini (jenkins-browser--parse-ini-file file)))
            (should (equal (cdr (assoc "url" ini)) "https://j.example.com"))
            (should (equal (cdr (assoc "user" ini)) "alice"))
            (should (equal (cdr (assoc "password" ini)) "s3cret"))))
      (delete-file file))))

(ert-deftest jenkins-browser-test-parse-ini-comments-and-colons ()
  (let ((file (make-temp-file "jenkins-browser-ini")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# top comment\n[jenkins] \n; url=https://commented\n"
                    "# user = nobody\nurl: https://j.example.com:8080\n"
                    "user = alice\n   password = tok#en;1:2   \n"
                    "[other]\nuser=zed\n"))
          (let ((ini (jenkins-browser--parse-ini-file file)))
            (should (equal (cdr (assoc "url" ini)) "https://j.example.com:8080"))
            (should (equal (cdr (assoc "user" ini)) "alice"))
            ;; Only the first delimiter splits; # and ; inside a value stay.
            (should (equal (cdr (assoc "password" ini)) "tok#en;1:2"))
            (should (= (length ini) 3))))
      (delete-file file))))

(ert-deftest jenkins-browser-test-parse-ini-multi-section ()
  (let ((file (make-temp-file "jenkins-browser-ini")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "[jenkins]\nurl = https://ci.example.com\nuser = alice\n"
                    "[staging]\nurl = https://staging.example.com\nuser = bob\n"))
          (let ((jenkins-browser-ini-path file)
                (jenkins-browser-server-profile "staging"))
            (should (equal (jenkins-browser-server-profiles) '("jenkins" "staging")))
            (should (equal (jenkins-browser--get-config "url") "https://staging.example.com"))
            (should (equal (jenkins-browser--get-config "user") "bob"))))
      (delete-file file))))

(ert-deftest jenkins-browser-test-switch-server ()
  (let ((file (make-temp-file "jenkins-browser-ini")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "[jenkins]\nurl = https://ci.example.com\nuser = alice\n"
                    "[prod]\nurl = https://prod.example.com\nuser = admin\n"))
          (let ((jenkins-browser-ini-path file)
                (jenkins-browser-server-profile "jenkins")
                (jenkins-browser-url nil)
                (jenkins-browser-username nil)
                (jenkins-browser-api-token nil))
            (should (equal (jenkins-browser--get-config "url") "https://ci.example.com"))
            (jenkins-browser-switch-server "prod")
            (should (equal jenkins-browser-server-profile "prod"))
            (should (equal (jenkins-browser--get-config "url") "https://prod.example.com"))))
      (delete-file file))))

(defmacro jenkins-browser-test--with-ini-mode (mode &rest body)
  "Run BODY with an INI file holding a password, created with MODE.
Collect the text of `display-warning' calls in the variable `warnings'."
  (declare (indent 1))
  `(let ((file (make-temp-file "jenkins-browser-ini"))
         (jenkins-browser-url nil) (jenkins-browser-username nil)
         (jenkins-browser-api-token nil)
         (jenkins-browser--warned-ini-paths nil)
         (auth-sources nil)
         (warnings nil))
     (unwind-protect
         (progn
           (with-temp-file file (insert "[jenkins]\nuser=a\npassword=b\n"))
           (set-file-modes file ,mode)
           (let ((jenkins-browser-ini-path file))
             (cl-letf (((symbol-function 'display-warning)
                        (lambda (_type message &rest _) (push message warnings))))
               ,@body)))
       (delete-file file))))

(ert-deftest jenkins-browser-test-ini-permissions-warns-once ()
  (skip-unless (not (eq system-type 'windows-nt)))
  (jenkins-browser-test--with-ini-mode #o644
    (should (equal (jenkins-browser--get-config "password") "b"))
    (should (equal (jenkins-browser--get-config "password") "b"))
    (should (= (length warnings) 1))
    (should (string-match-p "chmod 600" (car warnings)))))

(ert-deftest jenkins-browser-test-ini-permissions-private-file-is-silent ()
  (skip-unless (not (eq system-type 'windows-nt)))
  (jenkins-browser-test--with-ini-mode #o600
    (should (equal (jenkins-browser--get-config "password") "b"))
    (should (null warnings))))

(ert-deftest jenkins-browser-test-ini-permissions-only-for-password ()
  (skip-unless (not (eq system-type 'windows-nt)))
  (jenkins-browser-test--with-ini-mode #o644
    (should (equal (jenkins-browser--get-config "user") "a"))
    (should (null warnings))))

(ert-deftest jenkins-browser-test-config-prefers-custom-vars ()
  (let ((jenkins-browser-url "https://custom")
        (jenkins-browser-ini-path "/nonexistent")
        (auth-sources nil))
    (should (equal (jenkins-browser--get-config "url") "https://custom"))
    (should (null (jenkins-browser--get-config "user")))))

(ert-deftest jenkins-browser-test-auth-source-fallback ()
  (jenkins-browser-test--with-authinfo
      "machine ci.example.com login alice password s3cret\n"
    (should (equal (jenkins-browser--get-config "user") "alice"))
    (should (equal (jenkins-browser--get-config "password") "s3cret"))
    (should (equal (jenkins-browser--auth-header)
                   (concat "Basic " (base64-encode-string "alice:s3cret" t))))))

(ert-deftest jenkins-browser-test-auth-source-matches-configured-user ()
  (jenkins-browser-test--with-authinfo
      (concat "machine ci.example.com login alice password one\n"
              "machine ci.example.com login bob password two\n")
    (let ((jenkins-browser-username "bob"))
      (should (equal (jenkins-browser--get-config "password") "two")))))

(ert-deftest jenkins-browser-test-auth-source-other-host-ignored ()
  (jenkins-browser-test--with-authinfo
      "machine other.example.com login alice password s3cret\n"
    (should (null (jenkins-browser--get-config "user")))
    (should (null (jenkins-browser--get-config "password")))
    (should (null (jenkins-browser--auth-header)))))

(ert-deftest jenkins-browser-test-config-prefers-ini-over-auth-source ()
  (jenkins-browser-test--with-authinfo
      "machine ci.example.com login alice password from-authinfo\n"
    (let ((ini (make-temp-file "jenkins-browser-ini")))
      (unwind-protect
          (let ((jenkins-browser-ini-path ini))
            (with-temp-file ini
              (insert "[jenkins]\nuser=carol\npassword=from-ini\n"))
            (should (equal (jenkins-browser--get-config "user") "carol"))
            (should (equal (jenkins-browser--get-config "password")
                           "from-ini")))
        (delete-file ini)))))

(ert-deftest jenkins-browser-test-auth-source-needs-url ()
  (jenkins-browser-test--with-authinfo
      "machine ci.example.com login alice password s3cret\n"
    (let ((jenkins-browser-url nil))
      (should (null (jenkins-browser--get-config "user"))))))

(ert-deftest jenkins-browser-test-base-url-strips-slash ()
  (jenkins-browser-test--with-config
   (should (equal (jenkins-browser-base-url) "https://ci.example.com"))))

(ert-deftest jenkins-browser-test-base-url-unconfigured ()
  (let ((jenkins-browser-url nil) (jenkins-browser-ini-path "/nonexistent")
        (auth-sources nil))
    (should-error (jenkins-browser-base-url))))

(ert-deftest jenkins-browser-test-auth-header ()
  (jenkins-browser-test--with-config
   (should (equal (jenkins-browser--auth-header)
                  (concat "Basic " (base64-encode-string "bob:tok" t))))))

;;; Paths

(ert-deftest jenkins-browser-test-job-path ()
  (should (equal (jenkins-browser--job-path nil) ""))
  (should (equal (jenkins-browser--job-path "") ""))
  (should (equal (jenkins-browser--job-path "a") "/job/a"))
  (should (equal (jenkins-browser--job-path "a/b/c") "/job/a/job/b/job/c")))

(ert-deftest jenkins-browser-test-job-path-encodes ()
  (should (equal (jenkins-browser--job-path "my job/x&y") "/job/my%20job/job/x%26y"))
  ;; Multibranch job names already contain %2F; it must be encoded again.
  (should (equal (jenkins-browser--job-path "proj/feature%2Ffoo")
                 "/job/proj/job/feature%252Ffoo")))

(ert-deftest jenkins-browser-test-job-url ()
  (jenkins-browser-test--with-config
   (should (equal (jenkins-browser--job-url "f/j" "/build")
                  "https://ci.example.com/job/f/job/j/build"))
   (should (equal (jenkins-browser--job-url nil) "https://ci.example.com"))))

(ert-deftest jenkins-browser-test-join-path ()
  (should (equal (jenkins-browser--join-path nil "a") "a"))
  (should (equal (jenkins-browser--join-path "f" "j") "f/j"))
  (should (equal (jenkins-browser--join-path "" "j") "j")))

(ert-deftest jenkins-browser-test-jobs-url-root-folder-view ()
  (jenkins-browser-test--with-config
   (should (string-prefix-p "https://ci.example.com/api/json?tree="
                            (jenkins-browser--jobs-url nil)))
   (should (string-prefix-p "https://ci.example.com/job/f/job/g/api/json?tree="
                            (jenkins-browser--jobs-url "f/g")))
   (let ((jenkins-browser-view-name "My View"))
     (should (string-prefix-p "https://ci.example.com/view/My%20View/api/json"
                              (jenkins-browser--jobs-url nil)))
     ;; Views only apply at the root.
     (should (string-prefix-p "https://ci.example.com/job/f/api/json"
                              (jenkins-browser--jobs-url "f"))))))

(ert-deftest jenkins-browser-test-jobs-url-requests-class ()
  (jenkins-browser-test--with-config
   (should (string-match-p "_class" (url-unhex-string (jenkins-browser--jobs-url nil))))))

;;; Formatting

(ert-deftest jenkins-browser-test-get-nulls ()
  (let ((h (jenkins-browser-test--json "{\"a\":null,\"b\":false,\"c\":1}")))
    (should (null (jenkins-browser--get "a" h)))
    (should (null (jenkins-browser--get "b" h)))
    (should (equal (jenkins-browser--get "c" h) 1))
    (should (null (jenkins-browser--get "x" nil)))))

(ert-deftest jenkins-browser-test-format-duration ()
  (should (equal (jenkins-browser--format-duration nil) "-"))
  (should (equal (jenkins-browser--format-duration 0) "-"))
  (should (equal (jenkins-browser--format-duration 5000) "5s"))
  (should (equal (jenkins-browser--format-duration 125000) "2m 05s"))
  (should (equal (jenkins-browser--format-duration 3725000) "1h 02m")))

(ert-deftest jenkins-browser-test-format-timestamp ()
  (should (equal (jenkins-browser--format-timestamp nil) "-"))
  (should (string-match-p "\\`[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]\\'"
                          (jenkins-browser--format-timestamp 1700000000000))))

(ert-deftest jenkins-browser-test-format-status ()
  (should (equal (substring-no-properties (jenkins-browser--format-status nil t nil)) "RUNNING"))
  (should (equal (substring-no-properties (jenkins-browser--format-status nil nil "SUCCESS")) "SUCCESS"))
  (should (equal (substring-no-properties (jenkins-browser--format-status nil nil "FAILURE")) "FAILURE"))
  (should (equal (substring-no-properties (jenkins-browser--format-status "blue_anime" nil nil)) "RUNNING"))
  (should (equal (substring-no-properties (jenkins-browser--format-status nil nil nil)) "NOT BUILT")))

(ert-deftest jenkins-browser-test-format-culprits ()
  (should (equal (jenkins-browser--format-culprits nil) "-"))
  (should (equal (jenkins-browser--format-culprits
                  (jenkins-browser-test--json "[{\"fullName\":\"Ann\"},{\"fullName\":\"Bo\"}]"))
                 "Ann, Bo"))
  (should (equal (jenkins-browser--format-culprits (jenkins-browser-test--json "[{\"x\":1}]")) "-")))

(ert-deftest jenkins-browser-test-console-text-strips-cr ()
  (should (equal (jenkins-browser--console-text "a\r\nb\rc") "a\nbc")))

;;; Folders

(ert-deftest jenkins-browser-test-folder-p ()
  (should (jenkins-browser--folder-p (jenkins-browser-test--json "{\"_class\":\"com.cloudbees.hudson.plugins.folder.Folder\"}")))
  (should (jenkins-browser--folder-p (jenkins-browser-test--json "{\"_class\":\"jenkins.branch.OrganizationFolder\"}")))
  (should (jenkins-browser--folder-p (jenkins-browser-test--json "{\"_class\":\"org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject\"}")))
  (should-not (jenkins-browser--folder-p (jenkins-browser-test--json "{\"_class\":\"hudson.model.FreeStyleProject\"}")))
  (should-not (jenkins-browser--folder-p (jenkins-browser-test--json "{\"name\":\"x\"}"))))

(defconst jenkins-browser-test--jobs-json
  "{\"jobs\":[
     {\"_class\":\"com.cloudbees.hudson.plugins.folder.Folder\",\"name\":\"team\",\"color\":null},
     {\"_class\":\"hudson.model.FreeStyleProject\",\"name\":\"idle\",\"color\":\"blue\",
      \"lastBuild\":{\"number\":3,\"building\":false,\"result\":\"SUCCESS\",\"duration\":4000}},
     {\"_class\":\"hudson.model.FreeStyleProject\",\"name\":\"busy\",\"color\":\"red_anime\",
      \"lastBuild\":{\"number\":9,\"building\":true,\"result\":null,\"duration\":0}}]}")

(ert-deftest jenkins-browser-test-job-entries ()
  (jenkins-browser-test--with-config
   (cl-letf (((symbol-function 'jenkins-browser--request)
              (lambda (&rest _) (jenkins-browser-test--json jenkins-browser-test--jobs-json))))
     (with-temp-buffer
       (let ((entries (jenkins-browser--job-entries)))
         (should (= (length entries) 3))
         (should (equal (car (nth 0 entries)) '("team" . t)))
         (should (equal (car (nth 1 entries)) '("idle")))
         (should (equal (aref (cadr (nth 0 entries)) 0) "team/"))
         (should (equal (substring-no-properties (aref (cadr (nth 1 entries)) 2)) "#3")))
       (setq jenkins-browser--filter-running-only t)
       (let ((entries (jenkins-browser--job-entries)))
         ;; Folder stays visible, idle job is hidden.
         (should (equal (mapcar (lambda (e) (car (car e))) entries)
                        '("team" "busy"))))))))

(ert-deftest jenkins-browser-test-job-entries-fetches-folder ()
  (jenkins-browser-test--with-config
   (let (requested)
     (cl-letf (((symbol-function 'jenkins-browser--request)
                (lambda (_m url &rest _) (setq requested url)
                  (jenkins-browser-test--json "{\"jobs\":[]}"))))
       (with-temp-buffer
         (setq jenkins-browser--folder "team/sub")
         (jenkins-browser--job-entries)
         (should (string-prefix-p "https://ci.example.com/job/team/job/sub/api/json"
                                  requested)))))))

(ert-deftest jenkins-browser-test-read-job-at-point ()
  (with-temp-buffer
    (jenkins-browser-mode)
    (setq jenkins-browser--folder "team")
    (setq tabulated-list-entries
          (list (list '("job1") (vector "job1" "" "" ""))
                (list '("sub" . t) (vector "sub/" "" "" ""))))
    (tabulated-list-print)
    (goto-char (point-min))
    (should (equal (jenkins-browser--read-job "x: ") "team/job1"))
    (forward-line 1)
    (should-error (jenkins-browser--read-job "x: ") :type 'user-error)))

(ert-deftest jenkins-browser-test-enter-dispatch ()
  (with-temp-buffer
    (jenkins-browser-mode)
    (setq tabulated-list-entries
          (list (list '("job1") (vector "job1" "" "" ""))
                (list '("sub" . t) (vector "sub/" "" "" ""))))
    (tabulated-list-print)
    (goto-char (point-min))
    (let (called)
      (cl-letf (((symbol-function 'jenkins-browser-view-build-history)
                 (lambda (job) (push (list 'history job) called)))
                ((symbol-function 'jenkins-browser-open-folder)
                 (lambda (f) (push (list 'folder f) called))))
        (jenkins-browser-enter)
        (forward-line 1)
        (jenkins-browser-enter))
      (should (equal (nreverse called)
                     '((history "job1") (folder "sub")))))))

;;; History

(ert-deftest jenkins-browser-test-format-description ()
  (should (equal (jenkins-browser--format-description nil) "-"))
  (should (equal (jenkins-browser--format-description "") "-"))
  (should (equal (jenkins-browser--format-description "  \n ") "-"))
  (should (equal (jenkins-browser--format-description "plain text") "plain text"))
  (should (equal (jenkins-browser--format-description "line1\nline2\r\n  line3") "line1 line2 line3"))
  (should (equal (jenkins-browser--format-description "<b>Deploy</b> to <a href=\"/x\">prod</a><br/>now<br>ok")
                 "Deploy to prod now ok"))
  (should (equal (jenkins-browser--format-description "a &lt;b&gt; &amp; &quot;c&quot; &#39;d&#39;&nbsp;e")
                 "a <b> & \"c\" 'd' e"))
  ;; &amp;lt; must decode to the literal text &lt;, not to <.
  (should (equal (jenkins-browser--format-description "&amp;lt;") "&lt;")))

(ert-deftest jenkins-browser-test-history-entries-include-author-and-description ()
  (jenkins-browser-test--with-config
   (cl-letf (((symbol-function 'jenkins-browser--request)
              (lambda (&rest _)
                (jenkins-browser-test--json
                 "{\"builds\":[
                    {\"number\":7,\"result\":\"FAILURE\",\"building\":false,
                     \"duration\":65000,\"timestamp\":1700000000000,
                     \"culprits\":[{\"fullName\":\"Ann\"}],
                     \"description\":\"<b>hotfix</b> for #12\"},
                    {\"number\":6,\"result\":\"SUCCESS\",\"building\":false,
                     \"duration\":1000,\"timestamp\":1700000000000,
                     \"culprits\":[],\"description\":null}]}"))))
     (let* ((entries (jenkins-browser--history-entries "team/job"))
            (row (cadr (car entries)))
            (row2 (cadr (cadr entries))))
       (should (= (car (car entries)) 7))
       (should (= (length row) 6))
       (should (equal (aref row 3) "Ann"))
       (should (equal (aref row 4) "1m 05s"))
       (should (equal (aref row 5) "hotfix for #12"))
       (should (equal (aref row2 5) "-"))))))

(ert-deftest jenkins-browser-test-history-entries-display-name ()
  (jenkins-browser-test--with-config
   (cl-letf (((symbol-function 'jenkins-browser--request)
              (lambda (&rest _)
                (jenkins-browser-test--json
                 "{\"builds\":[
                    {\"number\":10,\"displayName\":\"release-1.0\",
                     \"result\":\"SUCCESS\",\"building\":false,
                     \"duration\":1000,\"timestamp\":1700000000000,
                     \"culprits\":[],\"description\":null},
                    {\"number\":9,\"displayName\":\"\",
                     \"result\":\"SUCCESS\",\"building\":false,
                     \"duration\":1000,\"timestamp\":1700000000000,
                     \"culprits\":[],\"description\":null}]}"))))
     (let* ((entries (jenkins-browser--history-entries "team/job"))
            (row1 (cadr (car entries)))
            (row2 (cadr (cadr entries))))
       (should (equal (substring-no-properties (aref row1 0)) "release-1.0"))
       (should (equal (substring-no-properties (aref row2 0)) "#9"))))))

(ert-deftest jenkins-browser-test-history-url-has-limit-and-culprits ()
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-history-limit 12) requested)
     (cl-letf (((symbol-function 'jenkins-browser--request)
                (lambda (_m url &rest _) (setq requested url) nil)))
       (jenkins-browser--fetch-build-history "team/job")
       (should (string-prefix-p "https://ci.example.com/job/team/job/job/api/json?tree="
                                requested))
       (let ((tree (url-unhex-string (cadr (split-string requested "tree=")))))
         (should (string-match-p "culprits\\[fullName\\]" tree))
         (should (string-match-p "{0,12}" tree)))))))

(ert-deftest jenkins-browser-test-history-mode-has-author-column ()
  (with-temp-buffer
    (jenkins-browser-build-history-mode)
    (should (equal (mapcar #'car (append tabulated-list-format nil))
                   '("Build" "Status" "Timestamp" "Author" "Duration" "Description")))))

;;; Actions

(ert-deftest jenkins-browser-test-extract-queue-item ()
  (should (equal (jenkins-browser--extract-queue-item '(("location" . "http://j/queue/item/42/"))) "42"))
  (should (equal (jenkins-browser--extract-queue-item '(("location" . "http://j/queue/item/999"))) "999"))
  (should (null (jenkins-browser--extract-queue-item '(("location" . "http://j/job/test/")))))
  (should (null (jenkins-browser--extract-queue-item nil))))

(ert-deftest jenkins-browser-test-trigger-simple-job ()
  (jenkins-browser-test--with-config
   (let (calls)
     (cl-letf (((symbol-function 'jenkins-browser--request)
                (lambda (_method url &rest _)
                  (if (string-suffix-p "/api/json" url)
                      (jenkins-browser-test--json "{\"property\":[{}]}")
                    "")))
               ((symbol-function 'jenkins-browser--http-full)
                (lambda (method url &optional data type &rest _)
                  (push (list method url data type) calls)
                  (cons "" '(("location" . "https://ci.example.com/queue/item/101/"))))))
       (jenkins-browser-trigger-job "team/job")
       (should (equal (car calls)
                      '("POST" "https://ci.example.com/job/team/job/job/build" nil nil)))))))

(ert-deftest jenkins-browser-test-trigger-parameterized-job ()
  (jenkins-browser-test--with-config
   (let (calls)
     (cl-letf (((symbol-function 'jenkins-browser--request)
                (lambda (_method url &rest _)
                  (if (string-suffix-p "/api/json" url)
                      (jenkins-browser-test--json
                       "{\"property\":[{\"parameterDefinitions\":[
                          {\"name\":\"BRANCH\",\"description\":\"b\",
                           \"defaultParameterValue\":{\"value\":\"main\"}},
                          {\"name\":\"ENV\",\"choices\":[\"dev\",\"prod\"]}]}]}")
                    "")))
               ((symbol-function 'jenkins-browser--http-full)
                (lambda (method url &optional data type &rest _)
                  (push (list method url data type) calls)
                  (cons "" '(("location" . "https://ci.example.com/queue/item/102/")))))
               ((symbol-function 'read-string) (lambda (&rest _) "feat x"))
               ((symbol-function 'completing-read) (lambda (&rest _) "prod")))
       (jenkins-browser-trigger-job "job")
       (should (equal (car calls)
                      '("POST" "https://ci.example.com/job/job/buildWithParameters"
                        "BRANCH=feat%20x&ENV=prod"
                        "application/x-www-form-urlencoded")))))))

(ert-deftest jenkins-browser-test-trigger-boolean-parameter ()
  (jenkins-browser-test--with-config
   (let (calls prompts)
     (cl-letf (((symbol-function 'jenkins-browser--request)
                (lambda (_method url &rest _)
                  (if (string-suffix-p "/api/json" url)
                      (jenkins-browser-test--json
                       "{\"property\":[{\"parameterDefinitions\":[
                          {\"_class\":\"hudson.model.BooleanParameterDefinition\",
                           \"name\":\"DRY\",\"defaultParameterValue\":{\"value\":true}},
                          {\"_class\":\"hudson.model.BooleanParameterDefinition\",
                           \"name\":\"CLEAN\",\"defaultParameterValue\":{\"value\":false}}]}]}")
                    "")))
               ((symbol-function 'jenkins-browser--http-full)
                (lambda (method url &optional data type &rest _)
                  (push (list method url data type) calls)
                  (cons "" nil)))
               ((symbol-function 'completing-read)
                (lambda (_prompt coll _p _r default &rest _)
                  (push (cons coll default) prompts)
                  default)))
       (jenkins-browser-trigger-job "job")
       (should (equal (car calls)
                      '("POST" "https://ci.example.com/job/job/buildWithParameters"
                        "DRY=true&CLEAN=false"
                        "application/x-www-form-urlencoded")))
       (should (equal (reverse prompts)
                      '((("true" "false") . "true") (("true" "false") . "false"))))))))

(ert-deftest jenkins-browser-test-trigger-password-parameter ()
  (jenkins-browser-test--with-config
   (let (calls passwords)
     (cl-letf (((symbol-function 'jenkins-browser--request)
                (lambda (_method url &rest _)
                  (if (string-suffix-p "/api/json" url)
                      (jenkins-browser-test--json
                       "{\"property\":[{\"parameterDefinitions\":[
                          {\"_class\":\"hudson.model.PasswordParameterDefinition\",
                           \"name\":\"SECRET_KEY\",\"description\":\"auth key\",
                           \"defaultParameterValue\":{\"value\":\"defpass\"}}]}]}")
                    "")))
               ((symbol-function 'jenkins-browser--http-full)
                (lambda (method url &optional data type &rest _)
                  (push (list method url data type) calls)
                  (cons "" '(("location" . "https://ci.example.com/queue/item/555/")))))
               ((symbol-function 'read-passwd)
                (lambda (prompt &optional _confirm default)
                  (push (cons prompt default) passwords)
                  "s3cr3t!")))
       (jenkins-browser-trigger-job "job")
       (should (equal (car calls)
                      '("POST" "https://ci.example.com/job/job/buildWithParameters"
                        "SECRET_KEY=s3cr3t%21"
                        "application/x-www-form-urlencoded")))
       (should (equal passwords '(("SECRET_KEY (auth key): " . "defpass"))))))))

(ert-deftest jenkins-browser-test-trigger-queue-item-feedback ()
  (jenkins-browser-test--with-config
   (let (messages)
     (cl-letf (((symbol-function 'jenkins-browser--request)
                (lambda (_method url &rest _)
                  (if (string-suffix-p "/api/json" url)
                      (jenkins-browser-test--json "{\"property\":[{}]}")
                    "")))
               ((symbol-function 'jenkins-browser--http-full)
                (lambda (_method _url &rest _)
                  (cons "" '(("location" . "https://ci.example.com/queue/item/789/")))))
               ((symbol-function 'message)
                (lambda (fmt &rest args)
                  (push (apply #'format fmt args) messages))))
       (jenkins-browser-trigger-job "deploy-job")
       (should (member "Triggered 'deploy-job' (queue item #789)" messages))))))

(ert-deftest jenkins-browser-test-history-rebuild ()
  (jenkins-browser-test--with-config
   (let (calls prompts)
     (cl-letf (((symbol-function 'jenkins-browser--request)
                (lambda (_method url &rest _)
                  (cond
                   ((string-match-p "/10/api/json" url)
                    (jenkins-browser-test--json
                     "{\"actions\":[{\"parameters\":[
                         {\"name\":\"BRANCH\",\"value\":\"hotfix-1\"},
                         {\"name\":\"DRY\",\"value\":true}]}]}"))
                   ((string-suffix-p "/api/json" url)
                    (jenkins-browser-test--json
                     "{\"property\":[{\"parameterDefinitions\":[
                         {\"name\":\"BRANCH\",\"defaultParameterValue\":{\"value\":\"main\"}},
                         {\"_class\":\"hudson.model.BooleanParameterDefinition\",
                          \"name\":\"DRY\",\"defaultParameterValue\":{\"value\":false}}]}]}"))
                   (t ""))))
               ((symbol-function 'jenkins-browser--http-full)
                (lambda (method url &optional data type &rest _)
                  (push (list method url data type) calls)
                  (cons "" nil)))
               ((symbol-function 'read-string)
                (lambda (_prompt _i _k default)
                  (push (cons "BRANCH" default) prompts)
                  default))
               ((symbol-function 'completing-read)
                (lambda (_prompt _choices _predicate _require-match default &rest _)
                  (push (cons "DRY" default) prompts)
                  default)))
       (with-temp-buffer
         (jenkins-browser-build-history-mode)
         (setq jenkins-browser--history-job "myjob")
         (jenkins-browser-history-rebuild 10))
       (should (equal (car calls)
                      '("POST" "https://ci.example.com/job/myjob/buildWithParameters"
                        "BRANCH=hotfix-1&DRY=true"
                        "application/x-www-form-urlencoded")))
       (should (equal (reverse prompts)
                      '(("BRANCH" . "hotfix-1") ("DRY" . "true"))))))))

(ert-deftest jenkins-browser-test-queue-entries ()
  (let* ((items (jenkins-browser-test--json
                 "[{\"id\":42,\"why\":\"Waiting for executor\",\"blocked\":false,\"stuck\":false,
                   \"inQueueSince\":1700000000000,\"task\":{\"name\":\"deploy-prod\"}},
                  {\"id\":43,\"why\":\"Node offline\",\"blocked\":true,\"stuck\":false,
                   \"inQueueSince\":1700000000000,\"task\":{\"name\":\"test-run\"}}]"))
         (entries (jenkins-browser--queue-entries items)))
    (should (= (length entries) 2))
    (should (equal (car (car entries)) 42))
    (should (equal (aref (cadr (car entries)) 1) "deploy-prod"))
    (should (equal (aref (cadr (car entries)) 2) "Waiting for executor"))
    (should (string-match-p "\\[BLOCKED\\]" (aref (cadr (cadr entries)) 2)))))

(ert-deftest jenkins-browser-test-queue-cancel ()
  (jenkins-browser-test--with-config
   (let (calls)
     (cl-letf (((symbol-function 'jenkins-browser--http-full)
                (lambda (method url &rest _)
                  (push (cons method url) calls)
                  (cons "" nil)))
               ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
               ((symbol-function 'jenkins-browser-queue-refresh) #'ignore))
       (with-temp-buffer
         (jenkins-browser-queue-mode)
         (setq tabulated-list-entries '((42 ["42" "deploy" "why" "1m"])))
         (tabulated-list-print t)
         (goto-char (point-min))
         (jenkins-browser-queue-cancel-item))
       (should (equal (car calls)
                      '("POST" . "https://ci.example.com/queue/cancelItem?id=42")))))))

(ert-deftest jenkins-browser-test-stages-entries ()
  (let* ((stages (jenkins-browser-test--json
                  "[{\"id\":\"11\",\"name\":\"Declarative: Checkout SCM\",\"status\":\"SUCCESS\",
                    \"startTimeMillis\":1700000000000,\"durationMillis\":5000},
                   {\"id\":\"15\",\"name\":\"Build\",\"status\":\"FAILED\",
                    \"startTimeMillis\":1700000005000,\"durationMillis\":120000}]"))
         (entries (jenkins-browser--stages-entries stages)))
    (should (= (length entries) 2))
    (should (equal (car (car entries)) "11"))
    (should (equal (aref (cadr (car entries)) 0) "Declarative: Checkout SCM"))
    (should (equal (aref (cadr (car entries)) 1) "SUCCESS"))
    (should (equal (aref (cadr (cadr entries)) 1) "FAILED"))))

(ert-deftest jenkins-browser-test-artifacts-entries ()
  (let* ((artifacts (jenkins-browser-test--json
                     "[{\"displayPath\":\"build.log\",\"fileName\":\"build.log\",
                       \"relativePath\":\"logs/build.log\"},
                      {\"displayPath\":\"app.tar.gz\",\"fileName\":\"app.tar.gz\",
                       \"relativePath\":\"target/app.tar.gz\"}]"))
         (entries (jenkins-browser--artifacts-entries artifacts)))
    (should (= (length entries) 2))
    (should (equal (car (car entries)) "logs/build.log"))
    (should (equal (aref (cadr (car entries)) 0) "build.log"))
    (should (equal (aref (cadr (car entries)) 1) "logs/build.log"))
    (should (equal (aref (cadr (cadr entries)) 0) "app.tar.gz"))))

(ert-deftest jenkins-browser-test-abort-urls ()
  (jenkins-browser-test--with-config
   (let (calls)
     (cl-letf (((symbol-function 'jenkins-browser--request)
                (lambda (method url &rest _) (push (cons method url) calls) ""))
               ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
       (jenkins-browser-abort-build "f/j")
       (with-temp-buffer
         (jenkins-browser-build-history-mode)
         (setq jenkins-browser--history-job "f/j")
         (jenkins-browser-history-abort-build 12))
       (should (member '("POST" . "https://ci.example.com/job/f/job/j/lastBuild/stop") calls))
       (should (member '("POST" . "https://ci.example.com/job/f/job/j/12/stop") calls))))))

(ert-deftest jenkins-browser-test-console-text-strips-notes ()
  (should (equal (jenkins-browser--console-text "a\r\nb\r\n") "a\nb\n"))
  (should (equal (jenkins-browser--console-text "x\e[8mha:////4AAA+/=\e[0mfoo\r\n") "xfoo\n"))
  ;; Other ANSI sequences (colours) are left alone.
  (should (equal (jenkins-browser--console-text "\e[31mred\e[0m") "\e[31mred\e[0m")))

(ert-deftest jenkins-browser-test-console-ansi-color-applied ()
  (with-temp-buffer
    (jenkins-browser-console-mode)
    (jenkins-browser--console-insert (encode-coding-string "\e[32mPASS\e[0m\n" 'utf-8))
    (let ((prop (get-text-property (point-min) 'face))
          (prop-fl (get-text-property (point-min) 'font-lock-face)))
      (should (or prop prop-fl)))))

(ert-deftest jenkins-browser-test-console-split ()
  (should (equal (jenkins-browser--console-split "a\nb\nc" nil) '("a\nb\n" . "c")))
  (should (equal (jenkins-browser--console-split "a\nb\n" nil) '("a\nb\n" . "")))
  (should (equal (jenkins-browser--console-split "abc" nil) '("" . "abc")))
  (should (equal (jenkins-browser--console-split "" nil) '("" . "")))
  (should (equal (jenkins-browser--console-split "a\nb" t) '("a\nb" . ""))))

(ert-deftest jenkins-browser-test-parse-headers ()
  (with-temp-buffer
    (insert "HTTP/1.1 200 OK\r\nX-Text-Size: 42\r\nx-more-data:true\r\n"
            "Content-Type: text/plain; charset=utf-8\r\n\r\nbody: not a header\r\n")
    (let ((h (jenkins-browser--parse-headers)))
      (should (equal (cdr (assoc "x-text-size" h)) "42"))
      (should (equal (cdr (assoc "x-more-data" h)) "true"))
      (should (equal (cdr (assoc "content-type" h)) "text/plain; charset=utf-8"))
      (should (= (length h) 3))))
  (with-temp-buffer
    (insert "HTTP/1.1 204 No Content\n\n")
    (should (null (jenkins-browser--parse-headers)))))

;;; Console

(defun jenkins-browser-test--log-server (log &optional chunks)
  "Return a stand-in for `url-retrieve-synchronously' and `url-retrieve'.
It serves the unibyte string LOG as a Jenkins progressive log.  CHUNKS is a
list of byte counts: the Nth request sees only that much of the log, and
the last entry (or the whole log) ends the stream.  The requested start
offsets are collected in `jenkins-browser-test--log-starts'."
  (let ((n 0))
    (lambda (url &rest _)
      (cond
       ((string-match "/api/json\\?tree=number" url)
        (jenkins-browser-test--response-buffer 200 "{\"number\":7}"))
       (t
        (string-match "start=\\([0-9]+\\)" url)
        (let* ((start (string-to-number (match-string 1 url)))
               (limit (nth (min n (1- (length chunks))) chunks))
               (end (if chunks (min limit (length log)) (length log)))
               (more (and chunks (< n (1- (length chunks)))))
               (buf (generate-new-buffer " *jenkins-browser-test-log*")))
          (setq n (1+ n))
          (push start jenkins-browser-test--log-starts)
          (with-current-buffer buf
            (set-buffer-multibyte nil)
            (insert (format "HTTP/1.1 200 OK\nX-Text-Size: %d\n%sContent-Type: text/plain\n\n"
                            end (if more "X-More-Data: true\n" "")))
            (insert (substring log (min start end) end))
            (setq-local url-http-response-status 200))
          buf))))))

(defvar jenkins-browser-test--log-starts nil
  "Start offsets requested from the stubbed log server, newest first.")

(defun jenkins-browser-test--view-console (log chunks &optional build)
  "Open the console of BUILD (default 7) with LOG served in CHUNKS.
Return the console buffer.  The caller kills it."
  (let ((stub (jenkins-browser-test--log-server log chunks)))
    (cl-letf (((symbol-function 'url-retrieve-synchronously) stub)
              ((symbol-function 'url-retrieve)
               (lambda (url callback &rest _)
                 (let ((buf (funcall stub url)))
                   (with-current-buffer buf (funcall callback nil))
                   buf)))
              ((symbol-function 'pop-to-buffer) #'ignore))
      (jenkins-browser-view-console "f/j" (or build 7)))
    (get-buffer (format "*Jenkins-Console: f/j #%s*" (or build 7)))))

(defmacro jenkins-browser-test--with-console (var log chunks &rest body)
  "Open a console on LOG served in CHUNKS, bind it to VAR, and run BODY.
`url-retrieve' is stubbed while BODY runs, and the buffer is killed after."
  (declare (indent 3))
  `(let* ((jenkins-browser-test--log-starts nil)
          (,var (jenkins-browser-test--view-console ,log ,chunks)))
     (unwind-protect
         (with-current-buffer ,var ,@body)
       (when (buffer-live-p ,var) (kill-buffer ,var)))))

(defmacro jenkins-browser-test--with-log-stub (log chunks &rest body)
  "Run BODY with `url-retrieve' serving LOG in CHUNKS, answering at once."
  (declare (indent 2))
  `(let ((stub (jenkins-browser-test--log-server ,log ,chunks)))
     (cl-letf (((symbol-function 'url-retrieve)
                (lambda (url callback &rest _)
                  (let ((buf (funcall stub url)))
                    (with-current-buffer buf (funcall callback nil))
                    buf))))
       ,@body)))

(ert-deftest jenkins-browser-test-view-console-finished-build ()
  (jenkins-browser-test--with-config
   (jenkins-browser-test--with-console buf "line1\r\nline2\r\n" nil
     (should (equal (buffer-string) "line1\nline2\n"))
     (should (derived-mode-p 'jenkins-browser-console-mode))
     (should buffer-read-only)
     (should (null jenkins-browser--console-timer))
     (should (null jenkins-browser--console-more-data))
     (should (= jenkins-browser--console-offset 14))
     (should (= (point) (point-max)))
     (should (equal jenkins-browser-test--log-starts '(0))))))

(ert-deftest jenkins-browser-test-view-console-strips-annotations ()
  (jenkins-browser-test--with-config
   (jenkins-browser-test--with-console buf "a\e[8mha:////4QQ+/==\e[0mb\r\n" nil
     (should (equal (buffer-string) "ab\n")))))

(ert-deftest jenkins-browser-test-view-console-resolves-last-build ()
  (jenkins-browser-test--with-config
   (let ((stub (jenkins-browser-test--log-server "x\n" nil))
         (jenkins-browser-test--log-starts nil) urls)
     (cl-letf (((symbol-function 'url-retrieve-synchronously)
                (lambda (url &rest r) (push url urls) (apply stub url r)))
               ((symbol-function 'pop-to-buffer) #'ignore))
       (jenkins-browser-view-console "f/j"))
     (unwind-protect
         (with-current-buffer "*Jenkins-Console: f/j #lastBuild*"
           (should (equal jenkins-browser--console-build "7"))
           (should (cl-some (lambda (u) (string-match-p "/job/f/job/j/7/logText/progressiveText\\?start=0" u))
                            urls))
           (should (cl-some (lambda (u) (string-match-p "/lastBuild/api/json\\?tree=number" u))
                            urls)))
       (kill-buffer "*Jenkins-Console: f/j #lastBuild*")))))

(ert-deftest jenkins-browser-test-view-console-running-build-follows ()
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-console-poll-interval 600))
     (jenkins-browser-test--with-console buf "one\ntwo\nthree\n" '(8 14)
       (should (equal (buffer-string) "one\ntwo\n"))
       (should jenkins-browser--console-more-data)
       (should (timerp jenkins-browser--console-timer))
       (should (equal mode-line-process " follow"))
       (should (= jenkins-browser--console-offset 8))
       ;; The next poll fetches from the stored offset and finishes the log.
       (jenkins-browser-test--with-log-stub "one\ntwo\nthree\n" '(14)
         (jenkins-browser--console-fetch))
       (should (equal (buffer-string) "one\ntwo\nthree\n"))
       (should (null jenkins-browser--console-more-data))
       (should (null jenkins-browser--console-timer))
       (should (null mode-line-process))))))

(ert-deftest jenkins-browser-test-console-holds-back-partial-lines ()
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-console-poll-interval 600)
         (log "alpha\nbeta gamma\ndelta\n"))
     ;; Cut mid-"beta gamma" (after "beta"), then after the "d" of "delta".
     (jenkins-browser-test--with-console buf log '(10 18 24)
       (should (equal (buffer-string) "alpha\n"))
       (should (equal jenkins-browser--console-pending "beta"))
       (should (= jenkins-browser--console-offset 10))
       (jenkins-browser-test--with-log-stub log '(18 24)
         (jenkins-browser--console-fetch)
         (should (equal (buffer-string) "alpha\nbeta gamma\n"))
         (should (equal jenkins-browser--console-pending "d"))
         (should jenkins-browser--console-timer)
         (jenkins-browser--console-fetch)
         (should (equal (buffer-string) "alpha\nbeta gamma\ndelta\n"))
         (should (equal jenkins-browser--console-pending ""))
         (should (null jenkins-browser--console-timer)))))))

(ert-deftest jenkins-browser-test-console-does-not-cut-multibyte-characters ()
  (jenkins-browser-test--with-config
   (let* ((jenkins-browser-console-poll-interval 600)
          (log (encode-coding-string "caf\u00e9 \u2713 ok\nnext\n" 'utf-8))
          (cut (+ 3 1)))                ; between the two bytes of \u00e9
     (jenkins-browser-test--with-console buf log (list cut (length log))
       (should (equal (buffer-string) ""))
       (jenkins-browser-test--with-log-stub log (list (length log))
         (jenkins-browser--console-fetch))
       (should (equal (buffer-string) "caf\u00e9 \u2713 ok\nnext\n"))))))

(ert-deftest jenkins-browser-test-console-offset-comes-from-text-size-header ()
  ;; With annotations the body is longer than the log offset it covers
  ;; (the real server answers 3416 bytes for X-Text-Size: 3382).
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-console-poll-interval 600))
     (jenkins-browser-test--with-console buf "a\n" '(2 2)
       (jenkins-browser--console-apply "one\ntwo\n" '(("x-text-size" . "5")
                                                      ("x-more-data" . "true")))
       (should (= jenkins-browser--console-offset 5))
       (should (equal (buffer-string) "a\none\ntwo\n"))
       ;; Without the header, fall back to counting the bytes received.
       (jenkins-browser--console-apply "x\n" '(("x-more-data" . "true")))
       (should (= jenkins-browser--console-offset 7))))))

(ert-deftest jenkins-browser-test-console-final-chunk-flushes-unfinished-line ()
  (jenkins-browser-test--with-config
   (jenkins-browser-test--with-console buf "no newline at end" nil
     (should (equal (buffer-string) "no newline at end")))))

(ert-deftest jenkins-browser-test-console-keeps-reading-position ()
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-console-poll-interval 600)
         (log "1\n2\n3\n4\n"))
     (jenkins-browser-test--with-console buf log '(4 8)
       (goto-char (point-min))
       (jenkins-browser-test--with-log-stub log '(8)
         (jenkins-browser--console-fetch))
       (should (equal (buffer-string) "1\n2\n3\n4\n"))
       (should (= (point) (point-min)))))))

(ert-deftest jenkins-browser-test-console-follows-point-at-end ()
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-console-poll-interval 600)
         (log "1\n2\n3\n4\n"))
     (jenkins-browser-test--with-console buf log '(4 8)
       (should (= (point) (point-max)))
       (jenkins-browser-test--with-log-stub log '(8)
         (jenkins-browser--console-fetch))
       (should (= (point) (point-max)))))))

(ert-deftest jenkins-browser-test-console-fetch-skips-while-in-flight ()
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-console-poll-interval 600) (calls 0) pending)
     (jenkins-browser-test--with-console buf "a\nb\n" '(2 4)
       (cl-letf (((symbol-function 'jenkins-browser--request-async)
                  (lambda (_url cb &optional _raw) (cl-incf calls) (setq pending cb))))
         (jenkins-browser--console-fetch)
         (jenkins-browser--console-fetch)
         (should (= calls 1))
         (should jenkins-browser--console-in-flight)
         (funcall pending (list :body "b\n"
                                :headers '(("x-text-size" . "4")))
                  nil)
         (should (null jenkins-browser--console-in-flight))
         (should (equal (buffer-string) "a\nb\n")))))))

(ert-deftest jenkins-browser-test-console-fetch-error-stops-following ()
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-console-poll-interval 600))
     (jenkins-browser-test--with-console buf "a\nb\n" '(2 4)
       (should jenkins-browser--console-timer)
       (cl-letf (((symbol-function 'jenkins-browser--request-async)
                  (lambda (_url cb &optional _raw) (funcall cb nil "HTTP 503"))))
         (jenkins-browser--console-fetch))
       (should (null jenkins-browser--console-timer))
       (should (null jenkins-browser--console-in-flight))
       (should (equal (buffer-string) "a\n"))
       ;; The user can pick it up again.
       (jenkins-browser-test--with-log-stub "a\nb\n" '(4)
         (jenkins-browser-console-toggle-follow))
       (should (equal (buffer-string) "a\nb\n"))))))

(ert-deftest jenkins-browser-test-console-ignores-answer-after-reload ()
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-console-poll-interval 600) pending)
     (jenkins-browser-test--with-console buf "a\nb\nc\n" '(2 4 6)
       (cl-letf (((symbol-function 'jenkins-browser--request-async)
                  (lambda (_url cb &optional _raw) (setq pending cb))))
         (jenkins-browser--console-fetch))
       ;; The buffer moves on before the old answer arrives.
       (setq jenkins-browser--console-offset 99)
       (funcall pending (list :body "stale\n" :headers '(("x-text-size" . "8"))) nil)
       (should (equal (buffer-string) "a\n"))
       (should (= jenkins-browser--console-offset 99))))))

(ert-deftest jenkins-browser-test-console-toggle-follow ()
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-console-poll-interval 600))
     (jenkins-browser-test--with-console buf "a\nb\nc\n" '(2 4 6)
       (should (timerp jenkins-browser--console-timer))
       (jenkins-browser-console-toggle-follow)
       (should (null jenkins-browser--console-timer))
       (should (null mode-line-process))
       (jenkins-browser-test--with-log-stub "a\nb\nc\n" '(4 6)
         (jenkins-browser-console-toggle-follow)
         (should (timerp jenkins-browser--console-timer))
         ;; Following starts with an immediate fetch.
         (should (equal (buffer-string) "a\nb\n")))))))

(ert-deftest jenkins-browser-test-console-toggle-follow-on-finished-build ()
  (jenkins-browser-test--with-config
   (jenkins-browser-test--with-console buf "a\n" nil
     (jenkins-browser-console-toggle-follow)
     (should (null jenkins-browser--console-timer)))))

(ert-deftest jenkins-browser-test-console-refresh-key-fetches-more ()
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-console-poll-interval 600))
     (jenkins-browser-test--with-console buf "a\nb\n" '(2 4)
       (jenkins-browser-console-toggle-follow)  ; follow off, so only g fetches
       (should (null jenkins-browser--console-timer))
       (jenkins-browser-test--with-log-stub "a\nb\n" '(4)
         (jenkins-browser-console-refresh))
       (should (equal (buffer-string) "a\nb\n"))))))

(ert-deftest jenkins-browser-test-console-refresh-key-on-finished-build ()
  (jenkins-browser-test--with-config
   (jenkins-browser-test--with-console buf "a\n" nil
     (let ((calls 0))
       (cl-letf (((symbol-function 'jenkins-browser--request-async)
                  (lambda (&rest _) (cl-incf calls))))
         (jenkins-browser-console-refresh))
       (should (= calls 0))))))

(ert-deftest jenkins-browser-test-console-kill-buffer-cancels-timer ()
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-console-poll-interval 600)
         (before (copy-sequence timer-list)))
     (jenkins-browser-test--with-console buf "a\nb\n" '(2 4)
       (should (timerp jenkins-browser--console-timer))
       (should-not (equal timer-list before))
       (kill-buffer buf))
     (should (equal timer-list before)))))

(ert-deftest jenkins-browser-test-console-reopen-restarts-from-zero ()
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-console-poll-interval 600)
         (before (copy-sequence timer-list)))
     (jenkins-browser-test--with-console buf "a\nb\n" '(2 4)
       (let ((first jenkins-browser--console-timer))
         ;; Opening the same console again replaces the old timer.
         (jenkins-browser-test--with-log-stub "a\nb\n" '(2 4)
           (let ((stub (jenkins-browser-test--log-server "a\nb\n" '(2 4))))
             (cl-letf (((symbol-function 'url-retrieve-synchronously) stub)
                       ((symbol-function 'pop-to-buffer) #'ignore))
               (jenkins-browser-view-console "f/j" 7))))
         (should (equal (buffer-string) "a\n"))
         (should (timerp jenkins-browser--console-timer))
         (should-not (eq first jenkins-browser--console-timer))
         (should (= (cl-count-if (lambda (tm) (eq (timer--function tm) (timer--function jenkins-browser--console-timer)))
                                 timer-list)
                    1)))))))

(ert-deftest jenkins-browser-test-console-failed-open-leaves-no-buffer ()
  (jenkins-browser-test--with-config
   (cl-letf (((symbol-function 'url-retrieve-synchronously)
              (lambda (&rest _) (jenkins-browser-test--response-buffer 404 "")))
             ((symbol-function 'pop-to-buffer) #'ignore))
     (should-error (jenkins-browser-view-console "f/j" 9))
     (should (null (get-buffer "*Jenkins-Console: f/j #9*"))))))

;;; Failed loads

(defun jenkins-browser-test--jenkins-buffers ()
  "Return the names of live buffers that start with \"*Jenkins\"."
  (sort (cl-loop for b in (buffer-list)
                 when (string-prefix-p "*Jenkins" (buffer-name b))
                 collect (buffer-name b))
        #'string<))

(ert-deftest jenkins-browser-test-failed-first-load-leaves-no-buffer ()
  (jenkins-browser-test--with-config
   (let ((before (jenkins-browser-test--jenkins-buffers)))
     (cl-letf (((symbol-function 'jenkins-browser--request)
                (lambda (&rest _) (error "Jenkins returned HTTP 401")))
               ((symbol-function 'pop-to-buffer) #'ignore)
               ((symbol-function 'pop-to-buffer-same-window) #'ignore))
       (dolist (open (list #'jenkins-browser
                           (lambda () (jenkins-browser-open-folder "a/b"))
                           (lambda () (jenkins-browser-view-build-history "a/b"))))
         (let ((err (should-error (funcall open))))
           (should (string-match-p "HTTP 401" (error-message-string err))))))
     (should (equal (jenkins-browser-test--jenkins-buffers) before)))))

(ert-deftest jenkins-browser-test-failed-reopen-keeps-existing-buffer ()
  (jenkins-browser-test--with-config
   (let ((fail nil))
     (cl-letf (((symbol-function 'jenkins-browser--request)
                (lambda (&rest _)
                  (if fail
                      (error "Jenkins returned HTTP 503")
                    (jenkins-browser-test--json
                     "{\"jobs\":[{\"_class\":\"hudson.model.FreeStyleProject\",\"name\":\"j1\"}]}"))))
               ((symbol-function 'pop-to-buffer) #'ignore))
       (unwind-protect
           (progn
             (jenkins-browser)
             (setq fail t)
             (should-error (jenkins-browser))
             (with-current-buffer "*Jenkins*"
               (should (derived-mode-p 'jenkins-browser-mode))
               (should (= (length tabulated-list-entries) 1))))
         (when (get-buffer "*Jenkins*")
           (kill-buffer "*Jenkins*")))))))

;;; HTTP layer

(defvar jenkins-browser-test--http-calls nil
  "Requests seen by the stubbed `url-retrieve-synchronously'.
Each element is a plist (:method :url :headers :data), newest first.")

(defun jenkins-browser-test--response-buffer (status body)
  "Return a unibyte buffer holding an HTTP response with STATUS and BODY.
Header lines end in a bare newline, as `url-http' leaves them."
  (let ((buf (generate-new-buffer " *jenkins-browser-test-response*")))
    (with-current-buffer buf
      (set-buffer-multibyte nil)
      (insert (format "HTTP/1.1 %d X\nContent-Type: text/plain\n\n" status)
              (encode-coding-string body 'utf-8))
      (setq-local url-http-response-status status))
    buf))

(defmacro jenkins-browser-test--with-http (responses &rest body)
  "Run BODY with `url-retrieve-synchronously' stubbed.
RESPONSES is a form evaluating to an alist of (URL-SUFFIX STATUS . BODY).
The first entry whose suffix matches the request URL is used; a URL with
no match gets a 404.  Requests are recorded in `jenkins-browser-test--http-calls'."
  (declare (indent 1))
  `(let ((jenkins-browser-test--http-calls nil)
         (responses ,responses))
     (cl-letf (((symbol-function 'url-retrieve-synchronously)
                (lambda (url &rest _)
                  (push (list :method url-request-method
                              :url url
                              :headers url-request-extra-headers
                              :data url-request-data)
                        jenkins-browser-test--http-calls)
                  (let ((hit (cl-find-if (lambda (r) (string-suffix-p (car r) url))
                                         responses)))
                    (jenkins-browser-test--response-buffer
                     (if hit (cadr hit) 404)
                     (if hit (cddr hit) ""))))))
       ,@body)))

(defun jenkins-browser-test--calls-to (suffix)
  "Return the recorded requests whose URL ends with SUFFIX, oldest first."
  (nreverse (cl-remove-if-not (lambda (c) (string-suffix-p suffix (plist-get c :url)))
                              jenkins-browser-test--http-calls)))

(ert-deftest jenkins-browser-test-http-get-sends-auth-without-crumb ()
  (jenkins-browser-test--with-config
   (jenkins-browser-test--with-http '(("/x" 200 . "hello"))
     (should (equal (jenkins-browser--http "GET" "https://ci.example.com/x") "hello"))
     (should (= (length jenkins-browser-test--http-calls) 1))
     (let ((call (car jenkins-browser-test--http-calls)))
       (should (equal (plist-get call :method) "GET"))
       (should (equal (cdr (assoc "Authorization" (plist-get call :headers)))
                      (jenkins-browser--auth-header)))
       (should-not (assoc "Jenkins-Crumb" (plist-get call :headers)))))))

(ert-deftest jenkins-browser-test-http-post-attaches-crumb ()
  (jenkins-browser-test--with-config
   (jenkins-browser-test--with-http
       '(("/crumbIssuer/api/json" 200 . "{\"crumbRequestField\":\"Jenkins-Crumb\",\"crumb\":\"abc123\"}")
         ("/build" 201 . ""))
     (should (equal (jenkins-browser--http "POST" "https://ci.example.com/job/j/build") ""))
     (let ((post (car (jenkins-browser-test--calls-to "/build"))))
       (should (equal (plist-get post :method) "POST"))
       (should (equal (cdr (assoc "Jenkins-Crumb" (plist-get post :headers))) "abc123"))
       (should (assoc "Authorization" (plist-get post :headers))))
     ;; The crumb itself is fetched with GET.
     (should (equal (plist-get (car (jenkins-browser-test--calls-to "/crumbIssuer/api/json")) :method)
                    "GET")))))

(ert-deftest jenkins-browser-test-http-post-without-crumb-endpoint ()
  (jenkins-browser-test--with-config
   (jenkins-browser-test--with-http '(("/build" 201 . ""))
     (should (equal (jenkins-browser--http "POST" "https://ci.example.com/job/j/build") ""))
     (let ((post (car (jenkins-browser-test--calls-to "/build"))))
       (should (equal (plist-get post :method) "POST"))
       (should (assoc "Authorization" (plist-get post :headers)))
       (should (= (length (plist-get post :headers)) 1))))))

(ert-deftest jenkins-browser-test-http-crumb-is-cached ()
  (jenkins-browser-test--with-config
   (jenkins-browser-test--with-http
       '(("/crumbIssuer/api/json" 200 . "{\"crumbRequestField\":\"Jenkins-Crumb\",\"crumb\":\"abc123\"}")
         ("/build" 201 . ""))
     (dotimes (_ 3)
       (jenkins-browser--http "POST" "https://ci.example.com/job/j/build"))
     (should (= (length (jenkins-browser-test--calls-to "/crumbIssuer/api/json")) 1))
     (should (= (length (jenkins-browser-test--calls-to "/build")) 3))
     (dolist (post (jenkins-browser-test--calls-to "/build"))
       (should (equal (cdr (assoc "Jenkins-Crumb" (plist-get post :headers))) "abc123"))))))

(ert-deftest jenkins-browser-test-http-crumb-cache-is-per-server-and-user ()
  (jenkins-browser-test--with-config
   (jenkins-browser-test--with-http
       '(("/crumbIssuer/api/json" 200 . "{\"crumbRequestField\":\"Jenkins-Crumb\",\"crumb\":\"abc123\"}")
         ("/build" 201 . ""))
     (jenkins-browser--http "POST" "https://ci.example.com/job/j/build")
     (let ((jenkins-browser-username "alice"))
       (jenkins-browser--http "POST" "https://ci.example.com/job/j/build"))
     (let ((jenkins-browser-url "https://other.example.com"))
       (jenkins-browser--http "POST" "https://other.example.com/job/j/build"))
     (should (= (length (jenkins-browser-test--calls-to "/crumbIssuer/api/json")) 3)))))

(ert-deftest jenkins-browser-test-http-missing-crumb-endpoint-is-not-cached ()
  (jenkins-browser-test--with-config
   (jenkins-browser-test--with-http '(("/build" 201 . ""))
     (jenkins-browser--http "POST" "https://ci.example.com/job/j/build")
     (jenkins-browser--http "POST" "https://ci.example.com/job/j/build")
     (should (null jenkins-browser--crumb-cache))
     (should (= (length (jenkins-browser-test--calls-to "/crumbIssuer/api/json")) 2)))))

(ert-deftest jenkins-browser-test-http-get-does-not-fetch-crumb ()
  (jenkins-browser-test--with-config
   (jenkins-browser-test--with-http '(("/x" 200 . "ok"))
     (jenkins-browser--http "GET" "https://ci.example.com/x")
     (should (null (jenkins-browser-test--calls-to "/crumbIssuer/api/json"))))))

(ert-deftest jenkins-browser-test-http-403-refreshes-crumb-and-retries-once ()
  (jenkins-browser-test--with-config
   (let ((issued 1) (posts nil))        ; c1 is already in the cache
     (cl-letf (((symbol-function 'url-retrieve-synchronously)
                (lambda (url &rest _)
                  (cond
                   ((string-suffix-p "/crumbIssuer/api/json" url)
                    (setq issued (1+ issued))
                    (jenkins-browser-test--response-buffer
                     200 (format "{\"crumbRequestField\":\"Jenkins-Crumb\",\"crumb\":\"c%d\"}" issued)))
                   (t
                    (let ((sent (cdr (assoc "Jenkins-Crumb" url-request-extra-headers))))
                      (push sent posts)
                      ;; Only the second crumb is accepted.
                      (jenkins-browser-test--response-buffer (if (equal sent "c2") 201 403) "")))))))
       ;; Prime the cache with c1, then it goes stale.
       (setq jenkins-browser--crumb-cache (cons (jenkins-browser--crumb-key) '("Jenkins-Crumb" . "c1")))
       (should (equal (jenkins-browser--http "POST" "https://ci.example.com/job/j/build") ""))
       (should (equal (reverse posts) '("c1" "c2")))
       (should (equal (cdr (cdr jenkins-browser--crumb-cache)) "c2"))))))

(ert-deftest jenkins-browser-test-http-403-does-not-retry-forever ()
  (jenkins-browser-test--with-config
   (let ((posts 0))
     (cl-letf (((symbol-function 'url-retrieve-synchronously)
                (lambda (url &rest _)
                  (if (string-suffix-p "/crumbIssuer/api/json" url)
                      (jenkins-browser-test--response-buffer
                       200 "{\"crumbRequestField\":\"Jenkins-Crumb\",\"crumb\":\"same\"}")
                    (setq posts (1+ posts))
                    (jenkins-browser-test--response-buffer 403 "")))))
       (let ((err (should-error (jenkins-browser--http "POST" "https://ci.example.com/job/j/build"))))
         (should (string-match-p "403" (error-message-string err))))
       ;; Same crumb comes back, so there is nothing to retry with.
       (should (= posts 1))))))

(ert-deftest jenkins-browser-test-http-sends-data-and-content-type ()
  (jenkins-browser-test--with-config
   (jenkins-browser-test--with-http '(("/x" 200 . "ok"))
     (jenkins-browser--http "PUT" "https://ci.example.com/x" "a=1" "application/x-www-form-urlencoded")
     (let ((call (car (jenkins-browser-test--calls-to "/x"))))
       (should (equal (plist-get call :data) "a=1"))
       (should (equal (cdr (assoc "Content-Type" (plist-get call :headers)))
                      "application/x-www-form-urlencoded"))))))

(ert-deftest jenkins-browser-test-http-error-statuses ()
  (jenkins-browser-test--with-config
   (dolist (status '(400 401 403 404 500 503))
     (jenkins-browser-test--with-http `(("/x" ,status . "nope"))
       (let ((err (should-error (jenkins-browser--http "GET" "https://ci.example.com/x"))))
         (should (string-match-p (number-to-string status) (error-message-string err))))))))

(ert-deftest jenkins-browser-test-http-no-response-buffer ()
  (jenkins-browser-test--with-config
   (cl-letf (((symbol-function 'url-retrieve-synchronously) (lambda (&rest _) nil)))
     (should-error (jenkins-browser--http "GET" "https://ci.example.com/x")))))

(ert-deftest jenkins-browser-test-http-decodes-utf-8 ()
  (jenkins-browser-test--with-config
   (jenkins-browser-test--with-http '(("/x" 200 . "caf\u00e9 \u2713"))
     (should (equal (jenkins-browser--http "GET" "https://ci.example.com/x") "caf\u00e9 \u2713")))))

(ert-deftest jenkins-browser-test-http-kills-response-buffer ()
  (jenkins-browser-test--with-config
   (let ((before (buffer-list)))
     (jenkins-browser-test--with-http '(("/x" 200 . "hi") ("/y" 500 . "no"))
       (jenkins-browser--http "GET" "https://ci.example.com/x")
       (ignore-errors (jenkins-browser--http "GET" "https://ci.example.com/y")))
     (should (equal (buffer-list) before)))))

(ert-deftest jenkins-browser-test-request-parses-json-or-returns-raw ()
  (jenkins-browser-test--with-config
   (jenkins-browser-test--with-http '(("/j" 200 . "{\"a\":[1,null,false]}")
				      ("/t" 200 . "plain text\nlog")
				      ("/e" 201 . ""))
     (let ((parsed (jenkins-browser--request "GET" "https://ci.example.com/j")))
       (should (hash-table-p parsed))
       (should (equal (gethash "a" parsed) '(1 nil nil))))
     (should (equal (jenkins-browser--request "GET" "https://ci.example.com/t") "plain text\nlog"))
     (should (equal (jenkins-browser--request "POST" "https://ci.example.com/e") "")))))

;;; Async requests

(defun jenkins-browser-test--stub-retrieve (status body &optional error-plist)
  "Return a stand-in for `url-retrieve' that answers with STATUS and BODY.
The callback runs immediately, in a fresh response buffer, with
ERROR-PLIST as its status argument."
  (lambda (url callback &rest _)
    (push (list :url url
                :method url-request-method
                :headers url-request-extra-headers)
          jenkins-browser-test--http-calls)
    (let ((buf (jenkins-browser-test--response-buffer status body)))
      (with-current-buffer buf
        (funcall callback error-plist))
      buf)))

(defun jenkins-browser-test--async (stub &optional url)
  "Run `jenkins-browser--request-async' with the `url-retrieve' replacement STUB.
Return the list of callback invocations, each (RESULT ERROR)."
  (let (calls (jenkins-browser-test--http-calls nil))
    (cl-letf (((symbol-function 'url-retrieve) stub))
      (jenkins-browser--request-async (or url "https://ci.example.com/x")
				      (lambda (r e) (push (list r e) calls))))
    (nreverse calls)))

(ert-deftest jenkins-browser-test-async-success-parses-json ()
  (jenkins-browser-test--with-config
   (let ((calls (jenkins-browser-test--async
                 (jenkins-browser-test--stub-retrieve 200 "{\"a\":1}"))))
     (should (= (length calls) 1))
     (should (null (cadr (car calls))))
     (should (= (gethash "a" (car (car calls))) 1)))))

(ert-deftest jenkins-browser-test-async-returns-raw-text-when-not-json ()
  (jenkins-browser-test--with-config
   (should (equal (jenkins-browser-test--async (jenkins-browser-test--stub-retrieve 200 "plain"))
                  '(("plain" nil))))))

(ert-deftest jenkins-browser-test-async-sends-auth-header-with-get ()
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-test--http-calls nil))
     (cl-letf (((symbol-function 'url-retrieve) (jenkins-browser-test--stub-retrieve 200 "{}")))
       (jenkins-browser--request-async "https://ci.example.com/x" #'ignore))
     (let ((call (car jenkins-browser-test--http-calls)))
       (should (equal (plist-get call :method) "GET"))
       (should (equal (cdr (assoc "Authorization" (plist-get call :headers)))
                      (jenkins-browser--auth-header)))))))

(ert-deftest jenkins-browser-test-async-http-error-reaches-callback ()
  (jenkins-browser-test--with-config
   (dolist (status '(401 403 404 500))
     (let* ((calls (jenkins-browser-test--async (jenkins-browser-test--stub-retrieve status "no")))
            (call (car calls)))
       (should (= (length calls) 1))
       (should (null (car call)))
       (should (string-match-p (format "HTTP %d" status) (cadr call)))))))

(ert-deftest jenkins-browser-test-async-connection-error-reaches-callback ()
  (jenkins-browser-test--with-config
   (let ((calls (jenkins-browser-test--async
                 (jenkins-browser-test--stub-retrieve 0 "" '(:error (error connection-failed "refused"))))))
     (should (= (length calls) 1))
     (should (null (car (car calls))))
     (should (string-match-p "connection-failed" (cadr (car calls)))))))

(ert-deftest jenkins-browser-test-async-kills-response-buffer ()
  (jenkins-browser-test--with-config
   (let ((before (buffer-list)))
     (jenkins-browser-test--async (jenkins-browser-test--stub-retrieve 200 "{}"))
     (jenkins-browser-test--async (jenkins-browser-test--stub-retrieve 500 ""))
     (should (equal (buffer-list) before)))))

(ert-deftest jenkins-browser-test-async-callback-error-does-not-escape ()
  (jenkins-browser-test--with-config
   (cl-letf (((symbol-function 'url-retrieve) (jenkins-browser-test--stub-retrieve 200 "{}")))
     (jenkins-browser--request-async "https://ci.example.com/x"
				     (lambda (&rest _) (error "boom")))
     (should t))))

(ert-deftest jenkins-browser-test-async-times-out-once ()
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-request-timeout 0.05)
         (late nil)
         (calls nil)
         (buf (generate-new-buffer " *jenkins-browser-test-pending*")))
     (cl-letf (((symbol-function 'url-retrieve)
                (lambda (_url callback &rest _)
                  (setq late (lambda ()
                               (with-current-buffer
                                   (jenkins-browser-test--response-buffer 200 "{}")
                                 (funcall callback nil))))
                  buf)))
       (jenkins-browser--request-async "https://ci.example.com/x"
				       (lambda (r e) (push (list r e) calls))))
     (accept-process-output nil 0.3)
     (should (= (length calls) 1))
     (should (null (car (car calls))))
     (should (string-match-p "timed out" (cadr (car calls))))
     (should-not (buffer-live-p buf))
     ;; A response that shows up after the timeout is ignored.
     (funcall late)
     (should (= (length calls) 1)))))

(ert-deftest jenkins-browser-test-async-leaves-no-timer-when-answer-is-immediate ()
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-request-timeout 600)
         (before (copy-sequence timer-list)))
     (cl-letf (((symbol-function 'url-retrieve) (jenkins-browser-test--stub-retrieve 200 "{}")))
       (jenkins-browser--request-async "https://ci.example.com/x" #'ignore))
     (should (equal timer-list before)))))

(ert-deftest jenkins-browser-test-async-cancels-timer-when-answer-comes-later ()
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-request-timeout 600)
         (before (copy-sequence timer-list))
         callback)
     (cl-letf (((symbol-function 'url-retrieve)
                (lambda (_url cb &rest _)
                  (setq callback cb)
                  (generate-new-buffer " *jenkins-browser-test-pending*"))))
       (jenkins-browser--request-async "https://ci.example.com/x" #'ignore))
     (should-not (equal timer-list before))
     (with-current-buffer (jenkins-browser-test--response-buffer 200 "{}")
       (funcall callback nil))
     (should (equal timer-list before)))))

;;; Background refresh

(defvar jenkins-browser-test--async-urls nil
  "URLs requested through the stubbed `jenkins-browser--request-async', newest first.")

(defun jenkins-browser-test--async-answering (body &optional error-message)
  "Return a `jenkins-browser--request-async' replacement that answers with BODY.
It records the requested URLs in `jenkins-browser-test--async-urls'.  With
ERROR-MESSAGE the callback gets an error instead."
  (lambda (url callback)
    (push url jenkins-browser-test--async-urls)
    (funcall callback
             (and (not error-message) (jenkins-browser-test--json body))
             error-message)))

(ert-deftest jenkins-browser-test-refresh-current-updates-jobs-buffer ()
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-test--async-urls nil))
     (cl-letf (((symbol-function 'jenkins-browser--request-async)
                (jenkins-browser-test--async-answering jenkins-browser-test--jobs-json)))
       (with-temp-buffer
         (jenkins-browser-mode)
         (setq jenkins-browser--folder "team")
         (jenkins-browser--refresh-current)
         (should (= (length tabulated-list-entries) 3))
         (should (null jenkins-browser--refresh-in-flight))
         (should (string-prefix-p "https://ci.example.com/job/team/api/json"
                                  (car jenkins-browser-test--async-urls))))))))

(ert-deftest jenkins-browser-test-refresh-current-updates-history-buffer ()
  (jenkins-browser-test--with-config
   (let ((jenkins-browser-test--async-urls nil))
     (cl-letf (((symbol-function 'jenkins-browser--request-async)
                (jenkins-browser-test--async-answering
                 "{\"builds\":[{\"number\":4,\"result\":\"SUCCESS\",\"building\":false}]}")))
       (with-temp-buffer
         (jenkins-browser-build-history-mode)
         (setq jenkins-browser--history-job "team/job")
         (jenkins-browser--refresh-current)
         (should (equal (mapcar #'car tabulated-list-entries) '(4)))
         (should (string-prefix-p "https://ci.example.com/job/team/job/job/api/json?tree="
                                  (car jenkins-browser-test--async-urls))))))))

(ert-deftest jenkins-browser-test-refresh-current-keeps-rows-on-error ()
  (jenkins-browser-test--with-config
   (cl-letf (((symbol-function 'jenkins-browser--request-async)
              (jenkins-browser-test--async-answering nil "Jenkins returned HTTP 503")))
     (with-temp-buffer
       (jenkins-browser-mode)
       (setq tabulated-list-entries (list (list '("old") (vector "old" "" "" ""))))
       (let ((before tabulated-list-entries))
         (jenkins-browser--refresh-current)
         (should (eq tabulated-list-entries before))
         (should (null jenkins-browser--refresh-in-flight)))))))

(ert-deftest jenkins-browser-test-refresh-current-skips-while-in-flight ()
  (jenkins-browser-test--with-config
   (let (pending (calls 0))
     (cl-letf (((symbol-function 'jenkins-browser--request-async)
                (lambda (_url callback) (cl-incf calls) (setq pending callback))))
       (with-temp-buffer
         (jenkins-browser-mode)
         (jenkins-browser--refresh-current)
         (jenkins-browser--refresh-current)
         (should (= calls 1))
         (should jenkins-browser--refresh-in-flight)
         ;; Once the answer arrives the next refresh goes through again.
         (funcall pending (jenkins-browser-test--json jenkins-browser-test--jobs-json) nil)
         (should-not jenkins-browser--refresh-in-flight)
         (jenkins-browser--refresh-current)
         (should (= calls 2)))))))

(ert-deftest jenkins-browser-test-refresh-current-ignores-killed-buffer ()
  (jenkins-browser-test--with-config
   (let (pending)
     (cl-letf (((symbol-function 'jenkins-browser--request-async)
                (lambda (_url callback) (setq pending callback))))
       (with-temp-buffer
         (jenkins-browser-mode)
         (jenkins-browser--refresh-current))
       (funcall pending (jenkins-browser-test--json jenkins-browser-test--jobs-json) nil)
       (should t)))))

(ert-deftest jenkins-browser-test-refresh-current-clears-flag-when-send-fails ()
  (jenkins-browser-test--with-config
   (cl-letf (((symbol-function 'jenkins-browser--request-async)
              (lambda (&rest _) (error "cannot send"))))
     (with-temp-buffer
       (jenkins-browser-mode)
       (should-error (jenkins-browser--refresh-current))
       (should-not jenkins-browser--refresh-in-flight)))))

(ert-deftest jenkins-browser-test-refresh-current-needs-history-job ()
  (jenkins-browser-test--with-config
   (let ((calls 0))
     (cl-letf (((symbol-function 'jenkins-browser--request-async)
                (lambda (&rest _) (cl-incf calls))))
       (with-temp-buffer
         (jenkins-browser-build-history-mode)
         (jenkins-browser--refresh-current)
         (should (= calls 0)))))))

;;; Auto refresh

(ert-deftest jenkins-browser-test-timer-lifecycle ()
  (let ((jenkins-browser--refresh-timer nil)
        (jenkins-browser-auto-refresh-interval 600))
    (unwind-protect
        (progn
          (jenkins-browser--ensure-timer)
          (should (timerp jenkins-browser--refresh-timer))
          (let ((first jenkins-browser--refresh-timer))
            (jenkins-browser--ensure-timer)
            (should (eq first jenkins-browser--refresh-timer)))
          ;; No Jenkins buffers exist, so a tick stops the timer.
          (jenkins-browser--timer-tick)
          (should (null jenkins-browser--refresh-timer)))
      (jenkins-browser--stop-timer))))

(ert-deftest jenkins-browser-test-timer-disabled ()
  (let ((jenkins-browser--refresh-timer nil))
    (dolist (v '(nil 0))
      (let ((jenkins-browser-auto-refresh-interval v))
        (jenkins-browser--ensure-timer)
        (should (null jenkins-browser--refresh-timer))))))

(provide 'jenkins-browser-test)
;;; jenkins-browser-test.el ends here
