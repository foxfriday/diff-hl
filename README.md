About
=====

`diff-hl-mode` highlights uncommitted changes in the margin of the window
(`+` added, `-` deleted, `~` changed), allows you to jump between and revert
them selectively.  It works the same in graphical frames and in terminals.

This feature is also known as "source control gutter indicators".

You can also stage and unstage the changes.

For the usage instructions and the list of commands, see the Commentary section
inside the file.

Only Git is supported; files under other VC backends are ignored.

The package also contains auxiliary modes:

* `diff-hl-dired-mode` provides similar functionality in Dired.
* `diff-hl-set-reference-rev` sets the reference revision for the
  current project to any revision, see its docstring for details.
* `diff-hl-flydiff-mode` implements highlighting changes on the fly.
* `diff-hl-show-hunk` shows the hunk at point inline.

Usage
=====

Put this into your init script:

```lisp
(global-diff-hl-mode)
```

You must also ensure that VC is enabled (e.g. `vc-handled-backends`
includes `Git`).

Check out the Commentary section in each file for more detailed usage
instructions.

Requirements
=====

Emacs 30.1+.

Notes
=====

* By default `diff-hl-mode` only updates the display when the buffer is in
  saved state. For a different tradeoff, also enable `diff-hl-flydiff-mode`,
  which makes the updates happen on a timer.

* To use an
  [alternative diff algorithm](http://stackoverflow.com/questions/32365271/whats-the-difference-between-git-diff-patience-and-git-diff-histogram)
  with Git, add a corresponding argument to `vc-git-diff-switches`,
  e.g. `(setq vc-git-diff-switches '("--histogram"))`. Using the
  `diff.algorithm` option doesn't work
  [because](http://article.gmane.org/gmane.comp.version-control.git/294622)
  `vc-git-diff` calls `git diff-index`. `diff-hl-flydiff-mode` does
  not support alternative algorithms, because it uses the external
  `diff` program.

* The indicators use the right margin, which is widened to one column
  while `diff-hl-mode` is on.  Customize `diff-hl-side` to `left` to use
  the left margin instead.  The characters are set by
  `diff-hl-margin-symbols-alist` and colored by the `diff-hl-insert`,
  `diff-hl-delete` and `diff-hl-change` faces.  Changes against a
  reference revision use the same characters in the dimmed
  `diff-hl-reference-*` faces.

Integration
=====

If you're using some package other than `vc` to commit changes, it might
not run `vc-checkin-hook` after commits. In that case, you'll need to
either add `diff-hl-update` to the hook it does run, or advise some
function that's called in the buffer after its state has changed.

Tramp
-----

`diff-hl` should just work with Tramp. But slow or high latency
connections can cause performance problems. If you experience such
issues, customize `diff-hl-disable-on-remote` to `t`. This will change
the behavior of both `turn-on-diff-hl-mode` and `global-diff-hl-mode`
(whichever you prefer to use).
