;;; diff-hl.el --- Highlight uncommitted changes using VC -*- lexical-binding: t -*-

;; Copyright (C) 2012-2026  Free Software Foundation, Inc.

;; Author:   Dmitry Gutov <dmitry@gutov.dev>
;; URL:      https://github.com/dgutov/diff-hl
;; Keywords: vc, diff
;; Version:  1.11.2
;; Package-Requires: ((emacs "30.1"))

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
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `diff-hl-mode' highlights uncommitted changes in the margin of the
;; window, allows you to jump between the hunks and revert them
;; selectively.

;; Provided commands:
;;
;; `diff-hl-diff-goto-hunk'  C-x v =
;; `diff-hl-revert-hunk'     C-x v n
;; `diff-hl-previous-hunk'   C-x v [
;; `diff-hl-next-hunk'       C-x v ]
;; `diff-hl-ediff-current-hunk' C-x v e
;; `diff-hl-stage-dwim'      C-x v S (the region, or the hunk at point)
;; `diff-hl-set-reference-rev'
;; `diff-hl-reset-reference-rev'
;; `diff-hl-unstage-file'
;;
;; The mode integrates with `repeat-mode'.

;; Add either of the following to your init file.
;;
;; To use it in all buffers:
;;
;; (global-diff-hl-mode)
;;
;; Only in `prog-mode' buffers, with `vc-dir' integration:
;;
;; (add-hook 'prog-mode-hook 'turn-on-diff-hl-mode)
;; (add-hook 'vc-dir-mode-hook 'turn-on-diff-hl-mode)

;;; Code:

(require 'cl-lib)
(require 'diff-mode)
(require 'vc)
(require 'vc-dir)
(require 'log-view)

(eval-when-compile
  (require 'vc-git)
  (require 'project))

(defgroup diff-hl nil
  "VC diff highlighting in the margin of a window."
  :group 'vc)

(defface diff-hl-insert
  '((((background dark)) :foreground "green3")
    (t :foreground "green4"))
  "Face used to highlight inserted lines."
  :group 'diff-hl)

(defface diff-hl-delete
  '((((background dark)) :foreground "red2")
    (t :foreground "red3"))
  "Face used to highlight deleted lines."
  :group 'diff-hl)

(defface diff-hl-change
  '((((background dark)) :foreground "DodgerBlue1")
    (t :foreground "blue3"))
  "Face used to highlight changed lines."
  :group 'diff-hl)

(defface diff-hl-reference-insert
  '((t :inherit shadow))
  "Face used to highlight lines inserted since reference rev."
  :group 'diff-hl)

(defface diff-hl-reference-delete
  '((t :inherit shadow))
  "Face used to highlight lines deleted since reference rev."
  :group 'diff-hl)

(defface diff-hl-reference-change
  '((t :inherit shadow))
  "Face used to highlight lines changed since reference rev."
  :group 'diff-hl)

(defcustom diff-hl-command-prefix (kbd "C-x v")
  "The prefix for all `diff-hl' commands."
  :group 'diff-hl
  :type 'string)

(defcustom diff-hl-disable-on-remote nil
  "Non-nil will disable `diff-hl' in remote buffers."
  :group 'diff-hl
  :type 'boolean)

(defcustom diff-hl-ask-before-revert-hunk t
  "Non-nil to ask for confirmation before revert a hunk."
  :group 'diff-hl
  :type 'boolean)

(defcustom diff-hl-next-previous-hunk-auto-recenter nil
  "Non-nil to `recenter' after `diff-hl-next-hunk' and `diff-hl-previous-hunk'."
  :group 'diff-hl
  :type 'boolean)

(defcustom diff-hl-highlight-reference t
  "Non-nil to mark changes against the reference revision separately.
Those changes use the same symbols as uncommitted ones, but are shown
with `diff-hl-reference-insert' and the related faces (dimmed by
default).  When nil, all changes against the reference revision are
shown as if they were uncommitted."
  :group 'diff-hl
  :type 'boolean)

(defvar diff-hl--margin-spec-cache (make-hash-table :test 'equal))

(defcustom diff-hl-margin-symbols-alist
  '((insert . "+") (delete . "-") (change . "~")
    (unknown . "?") (ignored . "i"))
  "Alist from change types to the strings shown in the margin."
  :group 'diff-hl
  :type '(alist :key-type symbol
                :value-type string
                :options (insert delete change unknown ignored))
  :set (lambda (symbol value)
         (set-default symbol value)
         (clrhash diff-hl--margin-spec-cache)))

(defcustom diff-hl-side 'right
  "Which margin to use for indicators."
  :type '(choice (const left)
                 (const right))
  :initialize 'custom-initialize-default
  :set (lambda (var value)
         (let ((on (bound-and-true-p global-diff-hl-mode)))
           (when on (global-diff-hl-mode -1))
           (set-default var value)
           (when on (global-diff-hl-mode 1)))))

(defcustom diff-hl-highlight-revert-hunk-function
  #'diff-hl-revert-narrow-to-hunk
  "Function to emphasize the current hunk in `diff-hl-revert-hunk'.
The function is called at the beginning of the hunk and is passed
the end position as its only argument."
  :type '(choice (const :tag "Do nothing" ignore)
                 (const :tag "Highlight the first column"
                        diff-hl-revert-highlight-first-column)
                 (const :tag "Narrow to the hunk"
                        diff-hl-revert-narrow-to-hunk)))

(defcustom diff-hl-global-modes '(not image-mode)
  "Modes for which `diff-hl-mode' is automagically turned on.
This affects the behavior of `global-diff-hl-mode'.
If nil, no modes have `diff-hl-mode' automatically turned on.
If t, all modes have `diff-hl-mode' enabled.
If a list, it should be a list of `major-mode' symbol names for
which it should be automatically turned on.  The sense of the list
is negated if it begins with `not'.  As such, the default value, which
lists `not' and `image-mode', means that `diff-hl-mode' is turned on in
all modes except for `image-mode' buffers.  Previously, `diff-hl-mode'
caused worse performance when viewing such files in certain
conditions."
  :type '(choice (const :tag "none" nil)
                 (const :tag "all" t)
                 (set :menu-tag "mode specific" :tag "modes"
                      :value (not)
                      (const :tag "Except" not)
                      (repeat :inline t (symbol :tag "mode"))))
  :group 'diff-hl)

(defcustom diff-hl-show-staged-changes t
  "Whether to include staged changes in the indicators.

When `diff-hl-highlight-reference' is non-nil, instead of being hidden,
the staged changes become part of the \"reference\" indicators."
  :type 'boolean)

(defcustom diff-hl-goto-hunk-old-revisions nil
  "Non-nil means `diff-hl-diff-goto-hunk' always goes to the current line.
It then always tries to navigate to the line in the diff that
corresponds to the current line in the file buffer (or as close as it
can get to it).

When this variable is nil (default), `diff-hl-diff-goto-hunk'
only does that when called without the prefix argument, or when
the NEW revision is not specified (meaning, the diff is against
the current version of the file)."
  :type 'boolean)

(defcustom diff-hl-update-async nil
  "When non-nil, `diff-hl-update' will run asynchronously.

When the value is `thread', it will call the diff process in a Lisp thread.

Any other non-nil value will make the the diff process called
asynchronously in the main thread.

Note that the latter mechanism is only compatible with Emacs 31+.
Whereas using a thread can help with older Emacs as well, but might
crash in some configurations.

This feature makes Emacs more responsive with large projects.  But it's
disabled in remote buffers, since current testing shows it doesn't work
reliably over Tramp."
  :type '(choice
          (const :tag "Disabled" nil)
          (const :tag "Simple async" t)
          (const :tag "Thread" thread)))

;; Threads are not reliable with remote files, yet.
(defcustom diff-hl-async-inhibit-functions (list #'file-remote-p)
  "Functions to call to check whether asynchronous method should be disabled.

When `diff-hl-update-async' is non-nil, these functions are called in turn
and passed the value `default-directory'.

If any returns non-nil, `diff-hl-update' will run synchronously anyway."
  :type '(repeat :tag "Predicate" function))

(defvar diff-hl-reference-revision-projects-cache '()
  "Alist of cached directory roots for per-project reference revisions.
Each element in this list has the form (DIR . REV).
DIR is the expanded name of the directory.
REV is the current reference revision.")

(defvar diff-hl-reference-revision nil
  "Revision to diff against.  nil means the most recent one.

It can be a relative expression as well, such as \"HEAD^\".")

(defun diff-hl--safe-revision-p (value)
  "Return non-nil if VALUE is nil or a revision safe to pass to Git.
A string starting with \"-\" would be parsed as an option."
  (or (null value)
      (and (stringp value)
           (not (string-empty-p value))
           (not (string-prefix-p "-" value)))))

(put 'diff-hl-reference-revision 'safe-local-variable
     #'diff-hl--safe-revision-p)

(defun diff-hl--check-revision (rev)
  "Signal an error unless REV is safe to pass to Git; return REV."
  (unless (diff-hl--safe-revision-p rev)
    (user-error "Invalid revision: %S" rev))
  rev)

(defun diff-hl--target-buffer (&optional buf)
  "Return the base buffer of BUF, or BUF itself if it has none.
BUF defaults to the current buffer."
  (let ((buf (or buf (current-buffer))))
    (or (buffer-base-buffer buf) buf)))

(defun diff-hl--buffer-file-name (&optional buffer)
  "Return the file name of the BUFFER or its base buffer.
BUFFER defaults to the current buffer."
  (buffer-file-name (diff-hl--target-buffer buffer)))

(defvar-local diff-hl--margin-widened nil
  "The margin width variable diff-hl set to 1 in the current buffer, if any.")

(defun diff-hl--refresh-margins ()
  "Make the windows showing the current buffer pick up its margin widths."
  (dolist (win (get-buffer-window-list nil nil t))
    (set-window-buffer win (current-buffer))))

(defun diff-hl--ensure-margin ()
  "Make the margin on `diff-hl-side' at least one column wide."
  (let ((var (intern (format "%s-margin-width" diff-hl-side))))
    ;; `diff-hl-side' changed since we widened the other margin.
    (unless (memq diff-hl--margin-widened (list nil var))
      (diff-hl--restore-margin))
    (when (zerop (symbol-value var))
      (set var 1)
      (setq diff-hl--margin-widened var)
      (diff-hl--refresh-margins))))

(defun diff-hl--restore-margin ()
  "Undo `diff-hl--ensure-margin'."
  (when diff-hl--margin-widened
    (set diff-hl--margin-widened 0)
    (setq diff-hl--margin-widened nil)
    (diff-hl--refresh-margins)))

(defun diff-hl--margin-spec (type face)
  "Return the margin display string for change TYPE shown with FACE."
  (let ((key (list type face diff-hl-side)))
    (or (gethash key diff-hl--margin-spec-cache)
        (puthash
         key
         (propertize
          " " 'display
          `((margin ,(intern (format "%s-margin" diff-hl-side)))
            ,(propertize (or (assoc-default type diff-hl-margin-symbols-alist)
                             " ")
                         'face face)))
         diff-hl--margin-spec-cache))))

(defmacro diff-hl-with-diff-switches (body)
  "Evaluate BODY with diff switches that produce hunks without context."
  `(progn
     (let ((vc-git-diff-switches
            ;; https://github.com/dgutov/diff-hl/issues/67
            (cons "-U0"
                  ;; https://github.com/dgutov/diff-hl/issues/9
                  (and (boundp 'vc-git-diff-switches)
                       (listp vc-git-diff-switches)
                       (cl-remove-if-not
                        (lambda (arg)
                          (member arg '("--histogram" "--patience" "--minimal" "--textconv")))
                        vc-git-diff-switches))))
           (vc-diff-switches '("-U0"))
           ,@(when (boundp 'vc-disable-async-diff)
               '((vc-disable-async-diff t))))
       ,body)))

(defun diff-hl-modified-p (state)
  "Return non-nil if a file in VC STATE may have changes to highlight."
  (or (memq state '(edited conflict))
      (and (eq state 'up-to-date)
           ;; VC state is stale in after-revert-hook.
           (or (static-if (boundp 'revert-buffer-in-progress)
                   ;; Emacs 31.
                   revert-buffer-in-progress
                 revert-buffer-in-progress-p)
               ;; Diffing against an older revision.
               diff-hl-reference-revision))))

(declare-function vc-git-command "vc-git")
(declare-function vc-git--rev-parse "vc-git")
(declare-function vc-git--empty-db-p "vc-git")
(declare-function vc-git-diff "vc-git")
(declare-function vc-git-root "vc-git")
(declare-function vc-git-previous-revision "vc-git")
(declare-function vc-git-find-revision "vc-git")
(declare-function vc-find-revision-no-save "vc")
(declare-function ediff-buffers "ediff")
(declare-function ediff-diff-at-point "ediff-util")
(declare-function ediff-jump-to-difference "ediff-util")
(defvar ediff-number-of-differences)

(defun diff-hl--use-git-index-base-p ()
  "Return non-nil if diff-hl should use the Git index as the reference base."
  (and (not diff-hl-reference-revision)
       (not diff-hl-show-staged-changes)))

(defun diff-hl-changes-buffer (file &optional new-rev bufname)
  "Diff FILE against the reference, without context, into buffer BUFNAME.
NEW-REV is passed to `diff-hl-diff-against-reference'.  BUFNAME defaults
to \" *diff-hl* \".  Return the buffer name."
  (diff-hl-with-diff-switches
   (diff-hl-diff-against-reference file (or bufname " *diff-hl* ") new-rev)))

(defconst diff-hl--git-empty-tree "4b825dc642cb6eb9a060e54bf8d69288fbee4904")

(defun diff-hl-diff-against-reference (file buffer &optional new-rev)
  "Insert the Git diff of FILE into BUFFER and return BUFFER.
The old side is `diff-hl-reference-revision', HEAD or the index.  The
new side is the working tree, or NEW-REV if non-nil: a revision, or
`git-index' for the staged version."
  (diff-hl--check-revision diff-hl-reference-revision)
  (when (stringp new-rev)
    (diff-hl--check-revision new-rev))
  (cond
   ((and (not new-rev)
         (diff-hl--use-git-index-base-p))
    (apply #'vc-git-command buffer
           (if (diff-hl--use-async-p) 'async 1)
           (list file)
           "diff-files"
           (append (cons "-p" (vc-switches 'git 'diff)) '("--"))))
   ((eq new-rev 'git-index)
    (apply #'vc-git-command buffer
           (if (diff-hl--use-async-p) 'async 1)
           (list file)
           "diff-index"
           (append
            (vc-switches 'git 'diff)
            (list "-p" "--cached"
                  (or diff-hl-reference-revision
                      (if (vc-git--empty-db-p)
                          diff-hl--git-empty-tree)
                      "HEAD")
                  "--"))))
   (t
    (condition-case err
        (vc-git-diff (list file)
                     diff-hl-reference-revision
                     new-rev
                     buffer
                     (diff-hl--use-async-p))
      (error
       ;; https://github.com/dgutov/diff-hl/issues/117
       (when (string-match-p "\\`Failed (status 128)" (error-message-string err))
         (vc-git-diff (list file)
                      diff-hl--git-empty-tree
                      nil
                      buffer
                      (diff-hl--use-async-p)))))))
  buffer)

(defun diff-hl-changes ()
  "Start computing the changes in the current buffer's file.
Return an alist with the keys `:working' (uncommitted changes) and
`:reference' (changes against the reference revision).  Each value is
a list of changes or the name of a buffer that receives a diff, possibly
asynchronously; see `diff-hl--resolve'.  Return nil for non-Git files."
  (let* ((file (diff-hl--buffer-file-name))
         (hide-staged (not diff-hl-show-staged-changes)))
    (when (eq (vc-backend file) 'Git)
      (let ((state (vc-state file 'Git))
            ;; Workaround for debbugs#78946 for the `thread' async update method.
            ;; This is fiddly, but we basically allow the thread to start, while
            ;; prohibiting the async process call inside.
            ;; That still makes it partially async on macOS.
            ;; Or just use "simple async" if your Emacs is new enough.
            (diff-hl-update-async (or (and (eq diff-hl-update-async 'thread)
                                           (not (eq window-system 'ns)))
                                      (eq diff-hl-update-async t))))
        (cond
         ((and
           (not diff-hl-highlight-reference)
           (diff-hl-modified-p state))
          `((:working . ,(diff-hl-changes-buffer file))))
         ((or
           diff-hl-reference-revision
           (diff-hl-modified-p state))
          (let* ((ref-changes
                  (and (or diff-hl-reference-revision
                           hide-staged)
                       (diff-hl-changes-buffer file
                                               (if hide-staged
                                                   'git-index
                                                 "HEAD")
                                               " *diff-hl-reference* ")))
                 (diff-hl-reference-revision nil)
                 (work-changes (diff-hl-changes-buffer file)))
            `((:reference . ,ref-changes)
              (:working . ,work-changes))))
         ((eq state 'added)
          `((:working . ,`((1 ,(line-number-at-pos (point-max)) 0 insert)))))
         ((eq state 'removed)
          `((:working . ,`((1 0 ,(line-number-at-pos (point-max)) delete))))))))))

(defun diff-hl-adjust-changes (old new)
  "Adjust changesets in OLD using changes in NEW.
The result alters the values inside the OLD changeset so that the line
numbers and insertion/deletion counts refer to the lines in the file
contents as they are (or would be) after applying the changes in NEW."
  (let ((acc 0)
        (ref old)
        overlap)
    (while (and new old)
      (cond
       ((<= (+ (nth 0 (car new)) (nth 2 (car new)))
            (+ acc (nth 0 (car old))))
        ;; (A) NEW-END <= OLD-BEG
        (cl-incf acc (- (nth 1 (car new)) (nth 2 (car new))))
        (setq new (cdr new)))
       ((<= (+ acc (nth 0 (car old)) (nth 1 (car old)))
            (nth 0 (car new)))
        ;; (B) OLD-END <= NEW-BEG
        (cl-incf (nth 0 (car old)) acc)
        (setq old (cdr old)))
       (t
        ;; There is overlap.
        (setq overlap
              (-
               (min
                (+ (nth 0 (car new)) (nth 2 (car new)))
                (+ acc (nth 0 (car old)) (nth 1 (car old))))
               (max
                (nth 0 (car new))
                (+ acc (nth 0 (car old))))))
        (cl-decf (nth 1 (car old)) overlap)
        ;; Add INSERTION amount to either before or inside.
        (cl-incf (nth
                  (if (> (nth 0 (car new))
                         (+ acc (nth 0 (car old))))
                      1 0)
                  (car old))
                 (-
                  (nth 1 (car new))
                  (- (nth 2 (car new))
                     overlap)))
        ;; See which of the heads to pop.
        (if (> (+ (nth 0 (car new)) (nth 1 (car new)))
               (+ acc (nth 0 (car old)) (nth 1 (car old))))
            (progn
              ;; Repetition of B (how to avoid dup?)
              (cl-incf (nth 0 (car old)) acc)
              (setq old (cdr old)))
          ;; Repetition of A.
          (cl-incf acc (- (nth 1 (car new)) (nth 2 (car new))))
          ;; But also decrease OLD-BEG by the same amount: it's added later.
          (cl-decf (nth 0 (car old)) (- (nth 1 (car new)) (nth 2 (car new))))
          (setq new (cdr new))))))
    (while old
      (cl-incf (nth 0 (car old)) acc)
      (setq old (cdr old)))
    ref))

(defun diff-hl-changes-from-buffer (buf)
  "Parse the diff in BUF into a list of (LINE INSERTS DELETES TYPE)."
  (with-current-buffer buf
    (let (res)
      (goto-char (point-min))
      (unless (eobp)
        (ignore-errors
          (diff-beginning-of-hunk t))
        (while (looking-at diff-hunk-header-re-unified)
          (let ((line (string-to-number (match-string 3)))
                (beg (point)))
            (with-no-warnings
              (let (diff-auto-refine-mode)
                (diff-end-of-hunk)))
            (let* ((inserts (diff-count-matches "^\\+" beg (point)))
                   (deletes (diff-count-matches "^-" beg (point)))
                   (type (cond ((zerop deletes) 'insert)
                               ((zerop inserts) 'delete)
                               (t 'change))))
              (when (eq type 'delete)
                (cl-incf line))
              (push (list line inserts deletes type) res)))))
      (nreverse res))))

(defun diff-hl--use-async-p ()
  "Return non-nil if diffs should be computed asynchronously here."
  (and diff-hl-update-async
       (not
        (run-hook-with-args-until-success 'diff-hl-async-inhibit-functions
                                          default-directory))))

(defvar-local diff-hl-timer nil
  "Pending idle timer that will update the current buffer, if any.")
(put 'diff-hl-timer 'permanent-local t)

(defun diff-hl-update ()
  "Update the diff-hl indicators in the current buffer."
  (setq diff-hl-timer nil)
  (if (and (diff-hl--use-async-p)
           (eq diff-hl-update-async 'thread))
      ;; TODO: debounce if a thread is already running.
      (let ((buf (current-buffer))
            (temp-buffer (generate-new-buffer " *temp*" t)))
        ;; Switch buffer temporarily, to "unlock" it for other threads.
        (with-current-buffer temp-buffer
          (make-thread
           (lambda ()
             (kill-buffer temp-buffer)
             (when (buffer-live-p buf)
               (set-buffer buf)
               (diff-hl--update-safe)))
           "diff-hl--update-safe")))
    (diff-hl--update)))

(defun diff-hl--update-buffer (buf)
  "Run `diff-hl-update' in BUF if it's still live."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (diff-hl-update))))

(defun diff-hl--update-safe ()
  "Update the diff-hl indicators, logging any error instead of signaling it."
  (condition-case-unless-debug err
      (diff-hl--update)
    (error
     (message "An error occurred in diff-hl--update: %S" err)
     nil)))

(defun diff-hl--update-overlays (changes reuse &optional reference)
  "Update the diff-hl overlays based on CHANGES.
REUSE is a list of existing line overlays that can be used.
REFERENCE non-nil means CHANGES are against the reference revision.
Return a list of line overlays used."
  (let ((current-line 1)
        ovls)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (dolist (c changes)
          (cl-destructuring-bind (line inserts _deletes type) c
            (forward-line (- line current-line))
            (setq current-line line)
            (let ((hunk-beg (point))
                  (len (if (eq type 'delete) 1 inserts)))
              (while (and reuse
                          (< (overlay-start (car reuse)) (point)))
                (setq reuse (cdr reuse)))
              (while (cl-plusp len)
                (push
                 (diff-hl-add-highlighting
                  type
                  (intern (format (if reference
                                      "diff-hl-reference-%s"
                                    "diff-hl-%s")
                                  type))
                  (and reuse
                       (= (overlay-start (car reuse)) (point))
                       (pop reuse)))
                 ovls)
                (forward-line 1)
                (cl-incf current-line)
                (cl-decf len))
              (let ((h (make-overlay hunk-beg (point)))
                    (hook '(diff-hl-overlay-modified)))
                (overlay-put h 'diff-hl t)
                (overlay-put h 'diff-hl-hunk t)
                (overlay-put h 'diff-hl-hunk-type type)
                (overlay-put h 'diff-hl-reference reference)
                (overlay-put h 'modification-hooks hook)
                (overlay-put h 'insert-in-front-hooks hook)
                (overlay-put h 'insert-behind-hooks hook)))))))
    (nreverse ovls)))

(defun diff-hl--no-query-on-exit (value)
  "Don't ask about killing the diff process of buffer VALUE on exit.
VALUE is a value from `diff-hl-changes'; lists are ignored."
  (when-let* ((buf (and (stringp value) (get-buffer value)))
              (proc (get-buffer-process buf)))
    (set-process-query-on-exit-flag proc nil)))

(defun diff-hl--update ()
  "Recompute the changes and redraw the indicators of the current buffer.
Also redraw them in the other buffers sharing its base buffer."
  ;; Reserve the margin in Git files only, even while they're unchanged,
  ;; so that the text doesn't shift when the first change appears.
  (when (eq (vc-backend (diff-hl--buffer-file-name)) 'Git)
    (diff-hl--ensure-margin))
  (let* ((orig (current-buffer))
         (cc (diff-hl-changes))
         (working (assoc-default :working cc))
         (reference (assoc-default :reference cc)))
    (diff-hl--no-query-on-exit working)
    (diff-hl--no-query-on-exit reference)
    (diff-hl--resolve
     working
     (lambda (changes)
       (diff-hl--resolve
        reference
        (lambda (ref-changes)
          (when (buffer-live-p orig)
            (let ((ref-changes (diff-hl-adjust-changes ref-changes changes))
                  (base (diff-hl--target-buffer orig)))
              (dolist (buf (buffer-list))
                (when (and (eq (diff-hl--target-buffer buf) base)
                           (buffer-local-value 'diff-hl-mode buf))
                  (with-current-buffer buf
                    (diff-hl-remove-overlays)
                    (let (reuse)
                      (when ref-changes
                        (setq reuse (diff-hl--update-overlays ref-changes nil t)))
                      (when changes
                        (diff-hl--update-overlays changes reuse))))))))))))))

(defun diff-hl--resolve (value-or-buffer cb)
  "Call CB with the list of changes in VALUE-OR-BUFFER.
If it's a buffer name, wait for its diff process to finish and parse
the diff."
  (if (listp value-or-buffer)
      (funcall cb value-or-buffer)
    (static-if (fboundp 'vc-run-delayed-success)
        ;; Emacs 31.
        (when (get-buffer value-or-buffer)
          (with-current-buffer value-or-buffer
            (vc-run-delayed-success 1
              (funcall cb (diff-hl-changes-from-buffer (current-buffer))))))
      (diff-hl--when-done value-or-buffer
                          #'diff-hl-changes-from-buffer
                          cb))))

(defun diff-hl--when-done (buffer get-value callback &optional proc)
  "Call CALLBACK with the result of GET-VALUE on BUFFER when PROC is done.
PROC defaults to BUFFER's process.  If there's none, call it right away."
  (let ((proc (or proc (get-buffer-process buffer))))
    (cond
     ;; If there's no background process, just execute the code.
     ((or (null proc) (eq (process-status proc) 'exit))
      ;; Make sure we've read the process's output before going further.
      (when proc (accept-process-output proc))
      (when (get-buffer buffer)
        (with-current-buffer buffer
          (funcall callback (funcall get-value buffer)))))
     ;; If process was deleted, we ignore it.
     ((eq (process-status proc) 'signal))
     ;; If a process is running, set the sentinel.
     ((eq (process-status proc) 'run)
      (add-function
       :after
       (process-sentinel proc)
       (lambda (proc _status)
         ;; Delegate to the parent cond for decision logic.
         (diff-hl--when-done buffer get-value callback proc))))
     ;; Maybe we should ignore all other states as well.
     (t (error "Unexpected process state")))))

(defun diff-hl-update-once ()
  "Schedule one update of the current buffer, when Emacs is idle.
Doing it once, after all major mode changes, also keeps the local value
of the margin width, if any."
  (unless diff-hl-timer
    (setq diff-hl-timer
          (run-with-idle-timer 0 nil #'diff-hl--update-buffer (current-buffer)))))

(defun diff-hl-add-highlighting (type face &optional ovl)
  "Mark the current line in the margin as a change of TYPE, using FACE.
OVL is an existing overlay to reuse."
  (let ((o (or ovl (make-overlay (point) (point)))))
    (diff-hl--ensure-margin)
    (overlay-put o 'diff-hl t)
    (overlay-put o 'before-string (diff-hl--margin-spec type face))
    o))

(defun diff-hl-remove-overlays (&optional beg end)
  "Delete the diff-hl overlays between BEG and END (default: everywhere)."
  (save-restriction
    (widen)
    (dolist (o (overlays-in (or beg (point-min)) (or end (point-max))))
      (when (overlay-get o 'diff-hl) (delete-overlay o)))))

(defun diff-hl-overlay-modified (ov after-p _beg _end &optional _length)
  "Delete the hunk overlay OV and all our line overlays inside it.
Do it before the change, when AFTER-P is nil."
  (unless after-p
    (when (overlay-buffer ov)
      (diff-hl-remove-overlays (overlay-start ov) (overlay-end ov))
      (delete-overlay ov))))

(defun diff-hl-edit (_beg _end _len)
  "Schedule `diff-hl-after-undo' when a change comes from an undo.
Undoing back to the unmodified state should restore the indicators."
  (when undo-in-progress
    (when diff-hl-timer
      (cancel-timer diff-hl-timer))
    (setq diff-hl-timer
          (run-with-idle-timer 0.01 nil #'diff-hl-after-undo (current-buffer)))))

(defun diff-hl-after-undo (buffer)
  "Update BUFFER if undo has made it unmodified."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      ;; The timer has fired; a stale value would block
      ;; `diff-hl-update-once'.
      (setq diff-hl-timer nil)
      (unless (buffer-modified-p)
        (diff-hl-update)))))

(defun diff-hl-diff-goto-hunk-1 (historic rev1)
  "Show the diff of the current file against REV1, at the current line.
If HISTORIC is non-nil, read both revisions, with REV1 as the default
for the older one."
  (defvar vc-sentinel-movepoint)
  (with-current-buffer (diff-hl--target-buffer)
    (vc-buffer-sync))
  (let* ((line (line-number-at-pos))
         (buffer (current-buffer))
         rev2)
    (when historic
      (let ((revs (diff-hl-diff-read-revisions rev1)))
        (setq rev1 (car revs)
              rev2 (cdr revs))))
    (diff-hl--check-revision rev1)
    (diff-hl--check-revision rev2)
    (vc-diff-internal
     (if (boundp 'vc-allow-async-diff)
         vc-allow-async-diff
       t)
     (vc-deduce-fileset) rev1 rev2 t)
    (vc-run-delayed (if (< (line-number-at-pos (point-max)) 3)
                        (with-current-buffer buffer (diff-hl-update))
                      (when (or (not rev2) diff-hl-goto-hunk-old-revisions)
                        (diff-hl-diff-skip-to line))
                      (setq vc-sentinel-movepoint (point))))))

(defun diff-hl-diff-goto-hunk (&optional historic)
  "Run VC diff command and go to the corresponding line in diff.
With a prefix argument HISTORIC, read the revisions to compare.  With a
double prefix argument (\\[universal-argument] \\[universal-argument]),
the diff is made against the reference revision."
  (interactive (list current-prefix-arg))
  (with-current-buffer (current-buffer)
    (if (equal historic '(16))
        (diff-hl-diff-reference-goto-hunk)
      (diff-hl-diff-goto-hunk-1 historic nil))))

(defun diff-hl-diff-reference-goto-hunk ()
  "Run VC diff command against the reference and go to the corresponding line."
  (interactive)
  (with-current-buffer (current-buffer)
    (diff-hl-diff-goto-hunk-1 nil diff-hl-reference-revision)))

(defun diff-hl-root-diff-reference-goto-hunk ()
  "Run VC diff command against the reference for the whole tree.
And if the current buffer is visiting a file, and it has changes, the diff
buffer will show the position corresponding to its current line."
  (interactive)
  (defvar vc-sentinel-movepoint)
  (with-current-buffer (current-buffer)
    (let ((default-directory default-directory)
          rootdir fileset
          relname)
      (unless (eq (vc-deduce-backend) 'Git)
        (error "Directory is not under Git control"))
      (diff-hl--check-revision diff-hl-reference-revision)
      (setq rootdir (vc-git-root default-directory)
            default-directory rootdir
            fileset `(Git (,rootdir))
            relname (let ((file (diff-hl--buffer-file-name)))
                      (when file
                        (file-relative-name file rootdir))))
      (vc-buffer-sync-fileset fileset t)
      (let* ((line (line-number-at-pos)))
        (vc-diff-internal
         (if (boundp 'vc-allow-async-diff)
             vc-allow-async-diff
           t)
         fileset diff-hl-reference-revision nil t)
        (vc-run-delayed (when relname
                          (diff-hl-diff-skip-to line relname)
                          (setq vc-sentinel-movepoint (point))))))))

(defun diff-hl--ediff-reference-buffer (file)
  "Return the reference buffer for FILE used in Ediff."
  (unless file
    (user-error "No current file"))
  (unless (eq (vc-backend file) 'Git)
    (user-error "The buffer is not under Git control"))
  (let* ((reference diff-hl-reference-revision)
         ;; Use the index snapshot only when diff-hl hides staged changes.
         (use-index (and (diff-hl--use-git-index-base-p)
                         (not diff-hl-highlight-reference)))
         (buf
          (if use-index
              (let ((obj (diff-hl-git-index-object-name file)))
                (unless obj
                  (user-error "No index entry for %s" file))
                (let ((filename (diff-hl-git-index-revision file obj)))
                  (find-file-noselect filename)))
            (let ((rev (diff-hl-resolved-revision (or reference "HEAD"))))
              (vc-find-revision-no-save file rev 'Git)))))
    (with-current-buffer buf
      (set-buffer-modified-p nil)
      (read-only-mode 1))
    buf))

;;;###autoload
(defun diff-hl-ediff-current-hunk ()
  "Run Ediff against current comparison base.  Jump to hunk at point."
  (interactive)
  (require 'ediff)
  (let* ((pos (point))
         (file (or buffer-file-name
                   (and-let* ((base (buffer-base-buffer)))
                     (buffer-file-name base))))
         (refbuf (diff-hl--ediff-reference-buffer file))
         (startup
          (list
           (lambda ()
             (unless (zerop ediff-number-of-differences)
               (ediff-jump-to-difference
                (max 1 (ediff-diff-at-point 'B pos))))))))
    (ediff-buffers refbuf (current-buffer) startup)))

(defun diff-hl-diff-read-revisions (rev1-default)
  "Read the older and newer revisions to compare the current file.
REV1-DEFAULT is the default older revision.  Return (REV1 . REV2), where
nil means the working tree."
  (let* ((file (diff-hl--buffer-file-name))
         (files (list file))
         (rev2-default nil))
    (cond
     ;; if the file is not up-to-date, use working revision as older revision
     ((not (vc-up-to-date-p file))
      (setq rev1-default
            (or rev1-default
                (vc-working-revision file))))
     ((not rev1-default)
      (setq rev1-default (ignore-errors ;If `previous-revision' doesn't work.
                           (vc-git-previous-revision file
                                                     (vc-working-revision file))))
      (when (string= rev1-default "") (setq rev1-default nil))))
    ;; finally read the revisions
    (let* ((rev1-prompt (if rev1-default
                            (concat "Older revision (default "
                                    rev1-default "): ")
                          "Older revision: "))
           (rev2-prompt (concat "Newer revision (default "
                                (or rev2-default "current source") "): "))
           (rev1 (vc-read-revision rev1-prompt files 'Git rev1-default))
           (rev2 (vc-read-revision rev2-prompt files 'Git rev2-default)))
      (when (string= rev1 "") (setq rev1 nil))
      (when (string= rev2 "") (setq rev2 nil))
      (cons rev1 rev2))))

(defun diff-hl-diff-skip-to (line &optional filename)
  "In `diff-mode', skip to the hunk and line corresponding to LINE.
LINE is a line in the source file.  Without an exact match, go to the
last line of the hunk above it.

When passed FILENAME, ensure that the line is in the section belonging to
that file, if it's present."
  (goto-char (point-min)) ; Counteract any similar behavior in diff-mode.
  (let (found
        (end-pos (point-max)))
    (diff-hunk-next)
    (when filename
      (while (and (not (equal (diff-find-file-name nil t)
                              filename))
                  (not (eobp)))
        (diff-file-next))
      (if (not (eobp))
          ;; Found our file in the changed set. Ensure that we don't go past.
          (setq end-pos (save-excursion
                          (diff-end-of-file)
                          (point)))
        (goto-char (point-min))
        (setq line 0)))
    (while (and (looking-at diff-hunk-header-re-unified)
                (not found)
                (< (point) end-pos))
      (let ((hunk-line (string-to-number (match-string 3)))
            (len (let ((m (match-string 4)))
                   (if m (string-to-number m) 1))))
        (if (> line (+ hunk-line len))
            (diff-hunk-next)
          (setq found t)
          (if (< line hunk-line)
              ;; Retreat to the previous hunk.
              (forward-line -1)
            (let ((to-go (1+ (- line hunk-line))))
              (while (cl-plusp to-go)
                (forward-line 1)
                (unless (looking-at "^[-\\]")
                  (cl-decf to-go))))))))
    (when (> (point) end-pos)
      (diff-hunk-prev)
      (diff-end-of-hunk))))

(defface diff-hl-reverted-hunk-highlight
  '((default :inverse-video t))
  "Face used to highlight the first column of the hunk to be reverted.")

(defun diff-hl-revert-highlight-first-column (end)
  "Highlight the first column of the minimal hunk after point.
END is ignored; the hunk's end is recomputed."
  (re-search-forward "^[+-]")
  (forward-line 0)
  (setq end (diff-hl-split-away-changes 0))
  (let ((inhibit-read-only t))
    (save-excursion
      (while (< (point) end)
        (font-lock-prepend-text-property (point) (1+ (point)) 'font-lock-face
                                         'diff-hl-reverted-hunk-highlight)
        (forward-line 1)))))

(defun diff-hl-revert-narrow-to-hunk (end)
  "Narrow the diff buffer to the hunk between point and END."
  (narrow-to-region (point) end))

(defun diff-hl-revert-hunk-1 ()
  "Show the hunk at point in a diff buffer and revert it after confirmation."
  (save-restriction
    (widen)
    (with-current-buffer (diff-hl--target-buffer)
      (vc-buffer-sync))
    (let* ((diff-buffer (get-buffer-create
                         (generate-new-buffer-name "*diff-hl-revert*")))
           (buffer (current-buffer))
           (diff-hl-update-async nil)
           (line (save-excursion
                   (diff-hl-find-current-hunk)
                   (line-number-at-pos)))
           (file (diff-hl--buffer-file-name)))
      (unwind-protect
          (progn
            (vc-setup-buffer diff-buffer)
            (with-current-buffer buffer
              ;; Ensure that the buffer-local variable value is applied.
              (diff-hl-diff-against-reference file diff-buffer))
            (diff-mode)
            (setq-local diff-vc-backend 'Git)
            (setq-local diff-vc-revisions (list diff-hl-reference-revision nil))
            (setq buffer-read-only t)
            (pop-to-buffer diff-buffer)
            (vc-run-delayed
              (vc-diff-finish diff-buffer nil)
              (let (beg-line end-line m-beg m-end)
                (when (eobp)
                  (with-current-buffer buffer (diff-hl-remove-overlays))
                  (user-error "Buffer is up-to-date"))
                (diff-hl-diff-skip-to line)
                (setq m-end (diff-hl-split-away-changes 3))
                (setq m-beg (point-marker))
                (funcall diff-hl-highlight-revert-hunk-function m-end)
                (setq beg-line (line-number-at-pos m-beg)
                      end-line (line-number-at-pos m-end))
                (let ((wbh (window-body-height)))
                  (if (>= wbh (- end-line beg-line))
                      (recenter (/ (+ wbh (- beg-line end-line) 2) 2))
                    (recenter 1)))
                (when (eq diff-refine 'navigation)
                  (diff-refine-hunk))
                (if diff-hl-ask-before-revert-hunk
                    (unless (yes-or-no-p (format "Revert current hunk in %s? "
                                                 file))
                      (user-error "Revert canceled")))
                (widen)
                (let ((diff-advance-after-apply-hunk nil))
                  (save-window-excursion
                    (diff-apply-hunk t)))
                (with-current-buffer buffer
                  (save-buffer))
                (message "Hunk reverted"))))
        (quit-windows-on diff-buffer t)))))

(defun diff-hl-split-away-changes (max-context)
  "Split away the minimal hunk at point from the rest of the hunk.

The minimal hunk is the hunk a diff program would produce if
asked for 0 lines of context.  Add MAX-CONTEXT lines of context at
most (stop when encounter another minimal hunk).

Move point to the beginning of the delineated hunk and return
its end position."
  (let (end-marker)
    (save-excursion
      (while (looking-at "[-+\\]") (forward-line 1))
      (dotimes (_i max-context)
        (unless (looking-at "@\\|[-+]")
          (forward-line 1)))
      (setq end-marker (point-marker))
      (unless (or (eobp)
                  (looking-at "@"))
        (diff-split-hunk)))
    (unless (looking-at "[-+]") (forward-line -1))
    (while (looking-at "[-+\\]") (forward-line -1))
    (dotimes (_i max-context)
      (unless (looking-at "@\\|[-+]")
        (forward-line -1)))
    (unless (looking-at "@")
      (forward-line 1)
      (diff-split-hunk)
      (forward-line -1))
    end-marker))

(defun diff-hl-revert-hunk ()
  "Revert the diff hunk with changes at or above point."
  (interactive)
  (with-current-buffer (current-buffer)
    (diff-hl-revert-hunk-1)))

(defun diff-hl-hunk-overlay-at (pos)
  "Return the diff-hl hunk overlay at POS, if any.
When the indicators diff against the Git index, staged hunks are only
shown, so they are skipped: navigating, staging or reverting them would
act on the unstaged changes instead."
  (let ((skip-staged (diff-hl--use-git-index-base-p)))
    (cl-loop for o in (overlays-in pos (1+ pos))
             when (and (overlay-get o 'diff-hl-hunk)
                       (not (and skip-staged
                                 (overlay-get o 'diff-hl-reference))))
             return o)))

(defun diff-hl-search-next-hunk (&optional backward)
  "Search the next hunk in the current buffer, or previous if BACKWARD."
  (save-excursion
    (catch 'found
      (while (not (if backward (bobp) (eobp)))
        (goto-char (if backward
                       (previous-overlay-change (point))
                     (next-overlay-change (point))))
        (let ((o (diff-hl-hunk-overlay-at (point))))
          (when (and o (= (overlay-start o) (point)))
            (throw 'found o)))))))

(defun diff-hl-next-hunk (&optional backward)
  "Go to the beginning of the next hunk in the current buffer.
If BACKWARD is non-nil, go to the previous one instead."
  (interactive)
  (let ((overlay (diff-hl-search-next-hunk backward)))
    (unless overlay
      (user-error "No further hunks found"))
    (goto-char (overlay-start overlay))
    (when diff-hl-next-previous-hunk-auto-recenter
      (recenter))))

(defun diff-hl-previous-hunk ()
  "Go to the beginning of the previous hunk in the current buffer."
  (interactive)
  (diff-hl-next-hunk t))

(defun diff-hl-find-current-hunk ()
  "Move point into the hunk at point, or else the previous or next hunk."
  (let ((o)
        (diff-hl-next-previous-hunk-auto-recenter nil))
    (cond
     ((diff-hl-hunk-overlay-at (point)))
     ((setq o (diff-hl-search-next-hunk t))
      (goto-char (overlay-start o)))
     (t
      (diff-hl-next-hunk)))))

(defun diff-hl-mark-hunk ()
  "Put the region around the hunk at point."
  (interactive)
  (let ((hunk (diff-hl-hunk-overlay-at (point))))
    (unless hunk
      (user-error "No hunk at point"))
    (goto-char (overlay-start hunk))
    (push-mark (overlay-end hunk) nil t)))

(defun diff-hl--ensure-staging-supported ()
  "Signal an error unless the current file is under Git."
  (unless (eq (vc-backend (diff-hl--buffer-file-name)) 'Git)
    (user-error "This file is not under Git control")))

(defun diff-hl-stage-diff (orig-buffer)
  "Stage the patch in the current buffer, in the repository of ORIG-BUFFER.
Return non-nil on success."
  (let ((patchfile (make-nearby-temp-file "diff-hl-stage-patch"))
        success)
    (write-region (point-min) (point-max) patchfile
                  nil 'silent)
    (unwind-protect
        (with-current-buffer orig-buffer
          (with-output-to-string
            (vc-git-command standard-output 0
                            (file-local-name patchfile)
                            "apply" "--cached" )
            (setq success t)))
      (delete-file patchfile))
    success))

(defun diff-hl-stage-current-hunk ()
  "Stage the hunk at or near point.

Only supported with Git."
  (interactive)
  (diff-hl--ensure-staging-supported)
  (diff-hl-find-current-hunk)
  (let* ((line (line-number-at-pos))
         (file (diff-hl--buffer-file-name))
         (dest-buffer (get-buffer-create " *diff-hl-stage*"))
         (orig-buffer (current-buffer))
         ;; FIXME: If the file name has double quotes, these need to be quoted.
         (file-base (file-name-nondirectory file))
         success)
    (with-current-buffer dest-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (let (diff-hl-reference-revision
          diff-hl-update-async)
      (diff-hl-diff-buffer-with-reference file dest-buffer 3))
    (with-current-buffer dest-buffer
      (diff-hl-diff-skip-to line)
      (let ((inhibit-read-only t))
        (diff-hl-split-away-changes 3)
        (save-excursion
          (diff-end-of-hunk)
          (delete-region (point) (point-max)))
        (diff-beginning-of-hunk)
        (delete-region (point-min) (point))
        ;; diff-no-select creates a very ugly header; Git rejects it
        (insert (format "diff a/%s b/%s\n" file-base file-base))
        (insert (format "--- a/%s\n" file-base))
        (insert (format "+++ b/%s\n" file-base)))
      (setq success (diff-hl-stage-diff orig-buffer)))
    (when success
      (if diff-hl-show-staged-changes
          (message (concat "Hunk staged; customize `diff-hl-show-staged-changes'"
                           " to highlight only unstaged changes"))
        (message "Hunk staged"))
      (unless diff-hl-show-staged-changes
        (diff-hl-update)))))

(defun diff-hl-unstage-file ()
  "Unstage everything staged in the current file."
  (interactive)
  (let ((file (diff-hl--buffer-file-name)))
    (unless file
      (user-error "No current file"))
    (diff-hl--ensure-staging-supported)
    (vc-git-command nil 0 file "reset" "--")
    (message "Unstaged all")
    (unless diff-hl-show-staged-changes
      (diff-hl-update))))

(defun diff-hl-stage-dwim (&optional with-edit)
  "Stage the current hunk or choose the hunks to stage.
With a prefix argument WITH-EDIT, or when the region is active, invoke
`diff-hl-stage-some'."
  (interactive "P")
  (if (or with-edit (region-active-p))
      (call-interactively #'diff-hl-stage-some)
    (call-interactively #'diff-hl-stage-current-hunk)))

(defvar diff-hl-stage--orig nil
  "The buffer whose changes are being staged from this diff buffer.")

(define-derived-mode diff-hl-stage-diff-mode diff-mode "Stage Diff"
  "Major mode for editing a diff buffer before staging.

\\<diff-hl-stage-diff-mode-map>\\[diff-hl-stage-finish] stages the edited diff."
  (setq revert-buffer-function #'ignore))

(define-key diff-hl-stage-diff-mode-map (kbd "C-c C-c") #'diff-hl-stage-finish)

(defun diff-hl-stage-some (&optional beg end)
  "Stage some or all of the current changes, interactively.
Pop up a diff buffer that can be edited to choose the changes to stage.
When BEG and END are non-nil (interactively, the region), only include
the changes between them."
  (interactive "r")
  (diff-hl--ensure-staging-supported)
  (let* ((line-beg (and beg (line-number-at-pos beg t)))
         (line-end (and end (line-number-at-pos end t)))
         (file (diff-hl--buffer-file-name))
         (dest-buffer (get-buffer-create "*diff-hl-stage-some*"))
         (orig-buffer (current-buffer))
         (diff-hl-update-async nil)
         ;; FIXME: If the file name has double quotes, these need to be quoted.
         (file-base (file-name-nondirectory file)))
    (with-current-buffer dest-buffer
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (let (diff-hl-reference-revision)
      (diff-hl-diff-buffer-with-reference file dest-buffer 3))
    (with-current-buffer dest-buffer
      (let ((inhibit-read-only t))
        (when end
          (with-no-warnings
            (let (diff-auto-refine-mode)
              (diff-hl-diff-skip-to line-end)
              (diff-hl-split-away-changes 3)
              (diff-end-of-hunk)))
          (delete-region (point) (point-max)))
        (if beg
            (with-no-warnings
              (let (diff-auto-refine-mode)
                (diff-hl-diff-skip-to line-beg)
                (diff-hl-split-away-changes 3)
                (diff-beginning-of-hunk)))
          (goto-char (point-min))
          (forward-line 3))
        (delete-region (point-min) (point))
        ;; diff-no-select creates a very ugly header; Git rejects it
        (insert (format "diff a/%s b/%s\n" file-base file-base))
        (insert (format "--- a/%s\n" file-base))
        (insert (format "+++ b/%s\n" file-base)))
      (let ((diff-default-read-only t))
        (diff-hl-stage-diff-mode))
      (setq-local diff-hl-stage--orig orig-buffer))
    (pop-to-buffer dest-buffer)
    (message "Press %s and %s to navigate, %s to split, %s to kill hunk, %s to undo, and %s to stage the diff after editing"
             (substitute-command-keys "\\`n'")
             (substitute-command-keys "\\`p'")
             (substitute-command-keys "\\[diff-split-hunk]")
             (substitute-command-keys "\\[diff-hunk-kill]")
             (substitute-command-keys "\\[diff-undo]")
             (substitute-command-keys "\\[diff-hl-stage-finish]"))))

(defun diff-hl-stage-finish ()
  "Stage the diff in the current buffer and bury it."
  (interactive)
  (let ((count 0)
        (orig-buffer diff-hl-stage--orig))
    (when (diff-hl-stage-diff orig-buffer)
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward diff-hunk-header-re-unified nil t)
          (cl-incf count)))
      (message "Staged %d hunks" count)
      (bury-buffer)
      (unless diff-hl-show-staged-changes
        (with-current-buffer orig-buffer
          (diff-hl-update))))))

(defvar diff-hl-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "n" 'diff-hl-revert-hunk)
    (define-key map "[" 'diff-hl-previous-hunk)
    (define-key map "]" 'diff-hl-next-hunk)
    (define-key map "e" 'diff-hl-ediff-current-hunk)
    (define-key map "S" 'diff-hl-stage-dwim)
    map))
(fset 'diff-hl-command-map diff-hl-command-map)

(defvar diff-hl-lighter ""
  "Mode line lighter for Diff Hl.

The value of this variable is a mode line template as in
`mode-line-format'.")

;;;###autoload
(define-minor-mode diff-hl-mode
  "Toggle VC diff highlighting."
  :lighter diff-hl-lighter
  :keymap `(([remap vc-diff] . diff-hl-diff-goto-hunk)
            (,diff-hl-command-prefix . diff-hl-command-map))
  (if diff-hl-mode
      (progn
        (add-hook 'after-save-hook 'diff-hl-update nil t)
        (add-hook 'after-change-functions 'diff-hl-edit nil t)
        (add-hook (if vc-mode
                      ;; Defer until the end of this hook, so that its
                      ;; elements can modify the update behavior.
                      'diff-hl-mode-on-hook
                    ;; If we're only opening the file now,
                    ;; `vc-find-file-hook' likely hasn't run yet, so
                    ;; let's wait until the state information is
                    ;; saved, in order not to fetch it twice.
                    'find-file-hook)
                  'diff-hl-update-once t t)
        ;; Never removed because it acts globally.
        (add-hook 'vc-checkin-hook 'diff-hl-after-checkin)
        (add-hook 'after-revert-hook 'diff-hl-update-once nil t)
        (when-let* ((rev (diff-hl--project-reference default-directory)))
          (setq-local diff-hl-reference-revision rev)))
    (remove-hook 'after-save-hook 'diff-hl-update t)
    (remove-hook 'after-change-functions 'diff-hl-edit t)
    (remove-hook 'find-file-hook 'diff-hl-update-once t)
    (remove-hook 'after-revert-hook 'diff-hl-update-once t)
    (diff-hl-remove-overlays)
    (diff-hl--restore-margin)
    (kill-local-variable 'diff-hl-reference-revision)))

(defun diff-hl-after-checkin ()
  "Update the buffers visiting the files that were just committed."
  (let ((fileset (vc-deduce-fileset t)))
    (dolist (file (nth 1 fileset))
      (let ((buf (find-buffer-visiting file)))
        (when buf
          (with-current-buffer buf
            (when diff-hl-mode
              (diff-hl-update))))))))

(defvar diff-hl-repeat-exceptions '(diff-hl-ediff-current-hunk)
  "Commands in `diff-hl-command-map' that `repeat-mode' doesn't repeat.")

;; Integrate with `repeat-mode' (https://debbugs.gnu.org/47566).
(map-keymap
 (lambda (_key cmd)
   (unless (memq cmd diff-hl-repeat-exceptions)
     (put cmd 'repeat-map 'diff-hl-command-map)))
 diff-hl-command-map)

(defun diff-hl-dir-update ()
  "Clear the indicators of the files that this `vc-dir' commit made clean."
  (dolist (pair (if (vc-dir-marked-files)
                    (vc-dir-marked-only-files-and-states)
                  (vc-dir-child-files-and-states)))
    (when (eq 'up-to-date (cdr pair))
      (let ((buffer (find-buffer-visiting (car pair))))
        (when buffer
          (with-current-buffer buffer
            (diff-hl-remove-overlays)))))))

(define-minor-mode diff-hl-dir-mode
  "Toggle `diff-hl-mode' integration in a `vc-dir-mode' buffer."
  :lighter ""
  (if diff-hl-dir-mode
      (add-hook 'vc-checkin-hook 'diff-hl-dir-update t t)
    (remove-hook 'vc-checkin-hook 'diff-hl-dir-update t)))

(defvar diff-hl-temporary-directory (if (and (eq system-type 'gnu/linux)
                                             (file-directory-p "/dev/shm/"))
                                        "/dev/shm/"
                                      temporary-file-directory)
  "Directory in which diff-hl creates its private snapshot directory.")

(defvar diff-hl--snapshot-directory nil
  "Private directory holding the old file versions diff-hl compares against.
Created on demand and deleted when Emacs exits.")

(defun diff-hl--snapshot-directory ()
  "Return the private snapshot directory, creating it if needed."
  (unless (and diff-hl--snapshot-directory
               (file-directory-p diff-hl--snapshot-directory))
    ;; `make-temp-file' picks an unpredictable name and creates the
    ;; directory with mode 0700, so other users can't read or plant
    ;; snapshots.
    (setq diff-hl--snapshot-directory
          (let ((temporary-file-directory diff-hl-temporary-directory))
            (file-name-as-directory (make-temp-file "diff-hl-" t))))
    (add-hook 'kill-emacs-hook #'diff-hl--delete-snapshot-directory))
  diff-hl--snapshot-directory)

(defun diff-hl--delete-snapshot-directory ()
  "Delete the private snapshot directory and everything in it."
  (when (and diff-hl--snapshot-directory
             (file-directory-p diff-hl--snapshot-directory))
    (delete-directory diff-hl--snapshot-directory t))
  (setq diff-hl--snapshot-directory nil))

(defun diff-hl--snapshot-file-name (file id)
  "Return the snapshot file name for the version of FILE identified by ID.
ID contains a commit or blob hash, so an existing snapshot never goes
stale and can be reused."
  (expand-file-name
   (format "%s-%s.~%s~"
           (substring (md5 file) 0 8)
           (file-name-nondirectory file)
           id)
   (diff-hl--snapshot-directory)))

(defun diff-hl--write-snapshot (file filename writer)
  "Create FILENAME by calling WRITER with an output buffer, unless it exists.
WRITER is called with FILE's buffer current.  Return FILENAME."
  (let ((filebuf (get-file-buffer file)))
    (unless (file-exists-p filename)
      (with-current-buffer filebuf
        (let ((coding-system-for-read 'no-conversion)
              (coding-system-for-write 'no-conversion))
          (condition-case nil
              (with-temp-file filename
                (let ((outbuf (current-buffer)))
                  (with-current-buffer filebuf
                    (funcall writer outbuf))))
            (error
             (when (file-exists-p filename)
               (delete-file filename)))))))
    filename))

(defun diff-hl-create-revision (file revision)
  "Write REVISION of FILE to a snapshot file and return its name."
  (diff-hl--write-snapshot
   file (diff-hl--snapshot-file-name file revision)
   ;; Run in FILE's buffer to get the local value of
   ;; `vc-checkout-switches'.
   (lambda (outbuf) (vc-git-find-revision file revision outbuf))))

(declare-function diff-no-select "diff")

(defun diff-hl-diff-buffer-with-reference (file &optional dest-buffer context-lines)
  "Diff the current buffer contents of FILE against the reference.
The diff goes into the buffer DEST-BUFFER, which is returned.  This
requires the program `diff-program' to be in your variable `exec-path'.
CONTEXT-LINES is the size of the unified diff context, defaults to 0."
  (require 'diff)
  (unless file
    (error "Buffer %s is not visiting a file" (buffer-name)))
  (unless (eq (vc-backend file) 'Git)
    (error "File %s is not under Git control" file))
  (save-current-buffer
    (let* ((dest-buffer (or dest-buffer "*diff-hl-diff-buffer-with-reference*"))
           (temporary-file-directory diff-hl-temporary-directory)
           (enable-local-variables nil)
           (rev
            (if (diff-hl--use-git-index-base-p)
                (diff-hl-git-index-revision
                 file
                 (diff-hl-git-index-object-name file))
              (diff-hl-create-revision
               file
               (diff-hl-resolved-revision
                (or diff-hl-reference-revision "HEAD")))))
           (switches (format "-U %d --strip-trailing-cr" (or context-lines 0))))
      (diff-no-select rev (current-buffer) switches (not (diff-hl--use-async-p))
                      (get-buffer-create dest-buffer))
      ;; Function `diff-sentinel' adds a summary line, but that seems fine.
      ;; In all commands which use exact text we call it synchronously.
      (get-buffer-create dest-buffer))))

(defun diff-hl-resolved-revision (revision)
  "Return the commit hash that REVISION refers to."
  (vc-git--rev-parse (diff-hl--check-revision revision)))

;; TODO: Cache based on .git/index's mtime, maybe.
(defun diff-hl-git-index-object-name (file)
  "Return the hash of FILE's blob in the Git index, or nil."
  (with-temp-buffer
    (vc-git-command (current-buffer) 0 file "ls-files" "-s" "--")
    (and
     (goto-char (point-min))
     (re-search-forward "^[0-9]+ \\([0-9a-f]+\\)" nil t)
     (match-string-no-properties 1))))

(defun diff-hl-git-index-revision (file object-name)
  "Write the index blob OBJECT-NAME of FILE to a snapshot file.
Return the snapshot file name."
  (diff-hl--write-snapshot
   file (diff-hl--snapshot-file-name file (concat "index-" object-name))
   ;; Run in FILE's buffer to be inside the repo.
   (lambda (outbuf)
     (vc-git-command outbuf 0 nil "cat-file" "blob" object-name))))

;;;###autoload
(defun turn-on-diff-hl-mode ()
  "Turn on `diff-hl-mode' or `diff-hl-dir-mode' in a buffer if appropriate."
  (let ((file (diff-hl--buffer-file-name)))
    (cond
     (file
      (unless (and diff-hl-disable-on-remote
                   (file-remote-p file))
        (diff-hl-mode 1)))
     ((eq major-mode 'vc-dir-mode)
      (diff-hl-dir-mode 1)))))

;;;###autoload
(defun diff-hl--global-turn-on ()
  "Call `turn-on-diff-hl-mode' if the current major mode is applicable."
  (when (cond ((eq diff-hl-global-modes t)
               t)
              ((eq (car-safe diff-hl-global-modes) 'not)
               (not (memq major-mode (cdr diff-hl-global-modes))))
              (t (memq major-mode diff-hl-global-modes)))
    (turn-on-diff-hl-mode)))

(declare-function vc-annotate-extract-revision-at-line "vc-annotate")
(declare-function project-name "project")
(declare-function project-buffers "project")

;;;###autoload
(defun diff-hl-set-reference-rev (rev)
  "Set the reference revision in the current project to REV.
Files opened later in the same project use it as well.

When called interactively, REV is read with completion.  With a prefix
argument, reset the reference to the most recent revision instead, like
`diff-hl-reset-reference-rev'.

The default value is chosen using one of the methods below:

- In a log view buffer, it uses the revision of current entry.
Call `vc-print-log' or `vc-print-root-log' first to open a log
view buffer.
- In a VC annotate buffer, it uses the revision of current line.
- In other situations, it uses the symbol at point."
  (interactive
   (list
    (unless current-prefix-arg
      (let* ((def (or (and (equal major-mode 'vc-annotate-mode)
                           (car (vc-annotate-extract-revision-at-line)))
                      (log-view-current-tag)
                      (thing-at-point 'symbol t)))
             (prompt (if def
                         (format "Reference revision (default %s): " def)
                       "Reference revision: ")))
        (vc-read-revision prompt nil nil def)))))
  (if (not rev)
      (diff-hl-reset-reference-rev)
    (diff-hl--check-revision rev)
    (let ((proj (diff-hl--current-project)))
      (diff-hl--set-project-reference proj rev)
      (message "Showing changes against %s (project %s)"
               rev (project-name proj)))))

;;;###autoload
(defun diff-hl-reset-reference-rev ()
  "Reset the reference revision in the current project to the most recent one."
  (interactive)
  (let ((proj (diff-hl--current-project)))
    (diff-hl--set-project-reference proj nil)
    (message "Showing changes against the most recent revision (project %s)"
             (project-name proj))))

(defun diff-hl--current-project ()
  "Return the current project, or signal an error if there's none."
  (or (project-current)
      (user-error "Not in a project")))

(defun diff-hl--project-root (proj)
  "Return the expanded root directory of the project PROJ."
  (expand-file-name (project-root proj)))

(defun diff-hl--project-reference (dir)
  "Return the reference revision remembered for the project containing DIR.
With nested projects, the innermost one wins."
  (let ((dir (expand-file-name dir))
        best)
    (dolist (pair diff-hl-reference-revision-projects-cache)
      (when (and (string-prefix-p (car pair) dir)
                 (> (length (car pair)) (length (car best))))
        (setq best pair)))
    (cdr best)))

(defun diff-hl--set-project-reference (proj rev)
  "Use REV as the reference revision in the project PROJ.
nil means the most recent revision."
  (let ((root (diff-hl--project-root proj)))
    ;; Remembered for files opened later, see `diff-hl-mode'.
    (setq diff-hl-reference-revision-projects-cache
          (assoc-delete-all root diff-hl-reference-revision-projects-cache
                            #'string-equal))
    (when rev
      (push (cons root rev) diff-hl-reference-revision-projects-cache))
    (dolist (buf (project-buffers proj))
      (with-current-buffer buf
        (when diff-hl-mode
          (if rev
              (setq-local diff-hl-reference-revision rev)
            (kill-local-variable 'diff-hl-reference-revision))
          (diff-hl-update))))))

;;;###autoload
(define-globalized-minor-mode global-diff-hl-mode diff-hl-mode
  diff-hl--global-turn-on :after-hook (diff-hl-global-mode-change))

(defun diff-hl-global-mode-change ()
  "Turn off `diff-hl-dir-mode' everywhere when `global-diff-hl-mode' is off."
  (unless global-diff-hl-mode
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when diff-hl-dir-mode
          (diff-hl-dir-mode -1))))))

(provide 'diff-hl)

;;; diff-hl.el ends here
