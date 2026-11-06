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
         (jenkins-view-name nil))
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
