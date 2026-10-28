;;; diff-hl-test.el --- tests for diff-hl -*- lexical-binding: t -*-

;; Copyright (C) 2020-2024  Free Software Foundation, Inc.

;; Author:   Nathan Moreau <nathan.moreau@m4x.org>

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;; Code:

(require 'diff-hl)
(require 'subr-x) ;; string-trim
(require 'ert)
(require 'vc-git)

(defvar diff-hl-test-source-file
  (expand-file-name (concat (file-name-directory (locate-library "diff-hl"))
                            "test/empty")))

(defvar diff-hl-test-initial-content nil)

(defmacro diff-hl-test-in-source (&rest body)
  `(save-window-excursion
     (find-file diff-hl-test-source-file)
     ,@body))
(put 'diff-hl-test-in-source 'lisp-indent-function 0)

(defun diff-hl-test-init ()
  (diff-hl-test-in-source
    (setq diff-hl-test-initial-content (buffer-string)))
  t)

(defun diff-hl-test-teardown ()
  (diff-hl-test-in-source
    (erase-buffer)
    (insert diff-hl-test-initial-content)
    (save-buffer)
    (vc-git-command nil 0 (diff-hl--buffer-file-name) "reset")))

(defun diff-hl-test-compute-diff-lines ()
  (diff-hl-test-in-source
    (save-buffer)
    (let ((vc-diff-switches "-w"))
      (diff-hl-diff-goto-hunk))
    (switch-to-buffer "*vc-diff*")
    (let ((lines nil)
          (previous-line (point-min)))
      (goto-char (point-min))
      (while (< (point) (point-max))
        (forward-line 1)
        (push (string-trim (buffer-substring-no-properties previous-line (point))) lines)
        (setq previous-line (point)))
      (delq nil (nreverse lines)))))

(defmacro diff-hl-deftest (name &rest body)
  `(ert-deftest ,name ()
     (diff-hl-test-init)
     (unwind-protect
         (progn ,@body)
       (diff-hl-test-teardown))))
(put 'diff-hl-deftest 'lisp-indent-function 'defun)

(ert-deftest diff-hl-update-once-schedules-per-buffer ()
  (let ((diff-hl-timer nil)
        (calls 0))
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (&rest _) (cl-incf calls))))
      (with-temp-buffer (diff-hl-update-once))
      (with-temp-buffer (diff-hl-update-once)))
    (should (= calls 2))))

(diff-hl-deftest diff-hl-insert ()
  (diff-hl-test-in-source
    (goto-char (point-max))
    (insert "added\n")
    (should (equal "+added"
                   (car (last (diff-hl-test-compute-diff-lines)))))))

(diff-hl-deftest diff-hl-remove ()
  (diff-hl-test-in-source
    (delete-region (point-min) (point-max))
    (should (equal "-last line"
                   (car (last (diff-hl-test-compute-diff-lines)))))))

(diff-hl-deftest diff-hl-indirect-buffer-insert ()
  (diff-hl-test-in-source
    (narrow-to-region (point-min) (point-max))
    (goto-char (point-max))
    (insert "added\n")
    (should (equal "+added"
                   (car (last (diff-hl-test-compute-diff-lines)))))))

(diff-hl-deftest diff-hl-indirect-buffer-remove ()
  (diff-hl-test-in-source
    (narrow-to-region (point-min) (point-max))
    (goto-char (point-min))
    (delete-region (point) (point-max))
    (should (equal "-last line"
                   (car (last (diff-hl-test-compute-diff-lines)))))))

(diff-hl-deftest diff-hl-indirect-buffer-move ()
  (diff-hl-test-in-source
    (narrow-to-region (point-min) (point-max))
    (goto-char (point-min))
    (kill-whole-line 3)
    (goto-char (point-max))
    (insert "added\n")
    (save-buffer)
    (diff-hl-mode 1)
    (diff-hl-update)
    (diff-hl-previous-hunk)
    (should (looking-at "added"))
    (diff-hl-previous-hunk)
    (should (looking-at "function2"))
    (should-error (diff-hl-previous-hunk) :type 'user-error)
    (diff-hl-next-hunk)
    (should (looking-at "added"))
    (should-error (diff-hl-next-hunk) :type 'user-error)))

(diff-hl-deftest diff-hl-indirect-buffer-move-async ()
  (diff-hl-test-in-source
   (let ((diff-hl-update-async t))
     (narrow-to-region (point-min) (point-max))
     (goto-char (point-min))
     (kill-whole-line 3)
     (goto-char (point-max))
     (insert "added\n")
     (save-buffer)
     (diff-hl-mode 1)
     (diff-hl-update)

     (while (or (process-live-p
                  (get-buffer-process " *diff-hl* "))
                (process-live-p
                  (get-buffer-process " *diff-hl-reference* ")))
       (accept-process-output nil 0.05))

     (diff-hl-previous-hunk)
     (should (looking-at "added"))
     (diff-hl-previous-hunk)
     (should (looking-at "function2"))
     (should-error (diff-hl-previous-hunk) :type 'user-error)
     (diff-hl-next-hunk)
     (should (looking-at "added"))
     (should-error (diff-hl-next-hunk) :type 'user-error))))

(diff-hl-deftest diff-hl-can-ignore-staged-changes ()
  (diff-hl-test-in-source
    (goto-char (point-min))
    (insert "new line 1\n")
    (save-buffer)
    (vc-git-command nil 0 (diff-hl--buffer-file-name) "add")
    (goto-char (point-max))
    (insert "new line 2\n")
    (save-buffer)
    (let ((diff-hl-show-staged-changes t))
      (should
       (null
        (assoc-default :reference (diff-hl-changes)))))
    (let* ((diff-hl-show-staged-changes nil)
           (res-buf (assoc-default :reference (diff-hl-changes))))
      (should
       (equal
        (diff-hl-changes-from-buffer res-buf)
        '((1 1 0 insert)))))))

(diff-hl-deftest diff-hl-flydiff-can-ignore-staged-changes ()
  (diff-hl-test-in-source
    (goto-char (point-min))
    (insert "new line 1\n")
    (save-buffer)
    (vc-git-command nil 0 (diff-hl--buffer-file-name) "add")
    (goto-char (point-max))
    (insert "new line 2\n")
    (let ((diff-hl-show-staged-changes t))
      (should
       (equal (diff-hl-changes-from-buffer
               (diff-hl-diff-buffer-with-reference (diff-hl--buffer-file-name)))
              '((1 1 0 insert)
                (12 1 0 insert)))))
    (let ((diff-hl-show-staged-changes nil))
      (should
       (equal (diff-hl-changes-from-buffer
               (diff-hl-diff-buffer-with-reference (diff-hl--buffer-file-name)))
              '((12 1 0 insert)))))))

(diff-hl-deftest diff-hl-can-split-away-no-trailing-newline ()
  (diff-hl-test-in-source
    (goto-char (point-max))
    (delete-char -1)
    (search-backward "}")
    (insert " ")
    (save-buffer)
    (let ((file (diff-hl--buffer-file-name))
          (dest-buffer (get-buffer-create " *diff-hl-test*")))
      (diff-hl-diff-buffer-with-reference file dest-buffer 3)
      (with-current-buffer dest-buffer
        (with-no-warnings
          (let (diff-auto-refine-mode)
            (diff-hl-diff-skip-to 10)))
        (let ((inhibit-read-only t))
          (diff-hl-split-away-changes 3))
        (should (string-prefix-p
                 "@@ -9,2 +9,2 @@
\x20
-last line
+last line
\\ No newline at end of file

Diff finished."
                 (buffer-substring (point) (point-max))))))))

;;; Tests in throwaway repositories

(defun diff-hl-test-git (&rest args)
  (with-temp-buffer
    (unless (zerop (apply #'process-file "git" nil t nil args))
      (error "git %S failed: %s" args (buffer-string)))))

(defun diff-hl-test-write (file content)
  (with-temp-file file (insert content)))

(defun diff-hl-test-read (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defmacro diff-hl-test-with-repo (&rest body)
  "Run BODY in a new Git repository, deleted afterwards."
  `(let* ((dir (file-name-as-directory (make-temp-file "diff-hl-test-" t)))
          (default-directory dir))
     (unwind-protect
         (progn
           (diff-hl-test-git "init" "-q")
           (diff-hl-test-git "config" "user.email" "test@example.com")
           (diff-hl-test-git "config" "user.name" "Test")
           ,@body)
       (dolist (buf (buffer-list))
         (when (string-prefix-p dir (or (buffer-file-name buf) ""))
           (with-current-buffer buf (set-buffer-modified-p nil))
           (kill-buffer buf)))
       (delete-directory dir t))))
(put 'diff-hl-test-with-repo 'lisp-indent-function 0)

(defun diff-hl-test-commit (&rest files-and-contents)
  "Write FILES-AND-CONTENTS (file, content, ...) and commit them."
  (let (files)
    (while files-and-contents
      (diff-hl-test-write (car files-and-contents) (cadr files-and-contents))
      (push (car files-and-contents) files)
      (setq files-and-contents (cddr files-and-contents)))
    (apply #'diff-hl-test-git "add" "--" files)
    (diff-hl-test-git "commit" "-qm" "commit")))

(ert-deftest diff-hl-safe-revision ()
  (should (diff-hl--safe-revision-p nil))
  (should (diff-hl--safe-revision-p "HEAD~1"))
  (should-not (diff-hl--safe-revision-p ""))
  (should-not (diff-hl--safe-revision-p "--output=/tmp/x"))
  (should-not (diff-hl--safe-revision-p 'HEAD))
  (should (eq (get 'diff-hl-reference-revision 'safe-local-variable)
              #'diff-hl--safe-revision-p)))

(ert-deftest diff-hl-option-like-revision-is-rejected ()
  (diff-hl-test-with-repo
    (diff-hl-test-commit "f.txt" "a\n")
    (diff-hl-test-write "f.txt" "b\n")
    (let ((diff-hl-reference-revision
           (concat "--output=" (expand-file-name "pwned"))))
      (with-temp-buffer
        (should-error (diff-hl-diff-against-reference
                       (expand-file-name "f.txt") (current-buffer))
                      :type 'user-error))
      (should-error (diff-hl-resolved-revision diff-hl-reference-revision)
                    :type 'user-error))
    (should-not (file-exists-p "pwned"))))

(ert-deftest diff-hl-option-like-file-name-in-diff-files ()
  (diff-hl-test-with-repo
    (diff-hl-test-commit "keep.txt" "keep\n" "--output=keep.txt" "a\n")
    (diff-hl-test-write "--output=keep.txt" "b\n")
    (let ((diff-hl-show-staged-changes nil)
          (diff-hl-reference-revision nil)
          (diff-hl-update-async nil))
      (with-temp-buffer
        (diff-hl-diff-against-reference (expand-file-name "--output=keep.txt")
                                        (current-buffer))))
    (should (equal (diff-hl-test-read "keep.txt") "keep\n"))))

(ert-deftest diff-hl-option-like-file-name-in-unstage ()
  (diff-hl-test-with-repo
    (diff-hl-test-commit "a.txt" "a\n" "--hard" "x\n")
    (diff-hl-test-write "a.txt" "changed\n")
    (diff-hl-test-write "--hard" "y\n")
    (diff-hl-test-git "add" "--" "--hard")
    (with-current-buffer (find-file-noselect (expand-file-name "--hard"))
      (should (diff-hl-git-index-object-name (diff-hl--buffer-file-name)))
      (let ((diff-hl-show-staged-changes t))
        (diff-hl-unstage-file)))
    ;; A `git reset --hard' would have discarded this change.
    (should (equal (diff-hl-test-read "a.txt") "changed\n"))))

(ert-deftest diff-hl-snapshots-are-private ()
  (let ((diff-hl--snapshot-directory nil))
    (unwind-protect
        (diff-hl-test-with-repo
          (diff-hl-test-commit "f.txt" "old\n")
          (let* ((dir (diff-hl--snapshot-directory))
                 (file (expand-file-name "f.txt"))
                 (snapshot (with-current-buffer (find-file-noselect file)
                             (diff-hl-create-revision
                              file (diff-hl-resolved-revision "HEAD")))))
            (should (= (file-modes dir) #o700))
            (should (string-prefix-p dir snapshot))
            (should (equal (diff-hl-test-read snapshot) "old\n"))))
      (diff-hl--delete-snapshot-directory))))

(ert-deftest diff-hl-margin-restored-after-side-change ()
  (with-temp-buffer
    (let ((diff-hl-side 'right)) (diff-hl--ensure-margin))
    (should (= right-margin-width 1))
    (let ((diff-hl-side 'left)) (diff-hl--ensure-margin))
    (should (= right-margin-width 0))
    (should (= left-margin-width 1))
    (diff-hl--restore-margin)
    (should (= left-margin-width 0))))

(ert-deftest diff-hl-margin-only-in-git-files ()
  (let ((dir (make-temp-file "diff-hl-nogit-" t))
        (diff-hl-side 'right))
    (unwind-protect
        (with-current-buffer (find-file-noselect (expand-file-name "f.txt" dir))
          (diff-hl-mode 1)
          (diff-hl--update)
          (should (= right-margin-width 0))
          (kill-buffer))
      (delete-directory dir t)))
  (diff-hl-test-with-repo
    (diff-hl-test-commit "f.txt" "a\n")
    (with-current-buffer (find-file-noselect (expand-file-name "f.txt"))
      (let ((diff-hl-side 'right))
        (diff-hl-mode 1)
        (diff-hl--update)
        (should (= right-margin-width 1))
        (diff-hl-mode -1)
        (should (= right-margin-width 0))))))

(ert-deftest diff-hl-after-undo-clears-timer ()
  (with-temp-buffer
    (insert "still modified")
    (setq diff-hl-timer (timer-create))
    (diff-hl-after-undo (current-buffer))
    (should-not diff-hl-timer)))

(ert-deftest diff-hl-project-reference-innermost ()
  (let ((diff-hl-reference-revision-projects-cache
         (list (cons (expand-file-name "~/outer/") "outer-rev")
               (cons (expand-file-name "~/outer/inner/") "inner-rev"))))
    (should (equal (diff-hl--project-reference "~/outer/inner/sub/") "inner-rev"))
    (should (equal (diff-hl--project-reference "~/outer/sub/") "outer-rev"))
    (should-not (diff-hl--project-reference "~/elsewhere/"))))

(ert-deftest diff-hl-staged-hunks-are-skipped ()
  (diff-hl-test-with-repo
    (diff-hl-test-commit "f.txt" "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n")
    (diff-hl-test-write "f.txt" "one\n2\n3\n4\n5\n6\n7\n8\n9\nten\n")
    (with-current-buffer (find-file-noselect (expand-file-name "f.txt"))
      (let ((diff-hl-show-staged-changes nil)
            (diff-hl-update-async nil))
        (diff-hl-mode 1)
        (diff-hl-update)
        (goto-char (point-min))
        (diff-hl-stage-current-hunk)
        (diff-hl-update)
        ;; Line 1 is staged: still drawn, but no longer a hunk to act on.
        (goto-char (point-min))
        (should (cl-some (lambda (o) (overlay-get o 'diff-hl-reference))
                         (overlays-in (point) (1+ (point)))))
        (should-not (diff-hl-hunk-overlay-at (point)))
        (diff-hl-next-hunk)
        (should (= (line-number-at-pos) 10))
        (should-error (diff-hl-next-hunk) :type 'user-error)
        (should-error (diff-hl-previous-hunk) :type 'user-error)
        ;; Against a reference revision, those hunks are what gets reviewed.
        (let ((diff-hl-reference-revision "HEAD"))
          (should (diff-hl-hunk-overlay-at (point-min))))))))

(provide 'diff-hl-test)

;;; diff-hl-test.el ends here
