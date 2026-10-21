;;; pilish-window-rewrite-bench.el --- Window-rewrite A/B benchmark -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Nouri

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Compare the pre-optimization whole-transcript window restore with the
;; current bounded implementation on a synthetic Markdown chat buffer.  Each
;; run rewrites the whole transcript after fontifying the original viewport,
;; then measures restoration with fresh JIT-lock state.  Each variant/case runs
;; in a fresh Emacs process so timers do not leak between measurements.  The
;; GUI/xvfb lane is primary; batch results are structural diagnostics only.
;; Timing is never a pass/fail threshold.

;;; Code:

(require 'json)
(require 'subr-x)

(defconst pilish-wr-bench-repo-root
  (file-name-as-directory
   (expand-file-name ".."
                     (file-name-directory
                      (or load-file-name buffer-file-name default-directory))))
  "Repository root containing the window-rewrite benchmark files.")

(add-to-list 'load-path pilish-wr-bench-repo-root)
(require 'pilish)

(defun pilish-wr-bench--env (name default)
  "Return environment variable NAME, or DEFAULT when unset or empty."
  (let ((value (getenv name)))
    (if (and value (not (string-empty-p value))) value default)))

(defun pilish-wr-bench--env-int (name default)
  "Return environment variable NAME as an integer, or DEFAULT."
  (string-to-number
   (pilish-wr-bench--env name (number-to-string default))))

(defvar pilish-wr-bench-variant
  (pilish-wr-bench--env "PI_WR_BENCH_VARIANT" "after")
  "Implementation variant measured by this process: before or after.")

(defvar pilish-wr-bench-case
  (pilish-wr-bench--env "PI_WR_BENCH_CASE" "middle")
  "Viewport case measured by this process: middle or short-tail.")

(defvar pilish-wr-bench-iteration
  (pilish-wr-bench--env-int "PI_WR_BENCH_ITERATION" 1)
  "Repetition number recorded in the result.")

(defvar pilish-wr-bench-turns
  (pilish-wr-bench--env-int "PI_WR_BENCH_TURNS" 200)
  "Number of synthetic transcript turns.")

(defvar pilish-wr-bench-lines-per-turn
  (pilish-wr-bench--env-int "PI_WR_BENCH_LINES_PER_TURN" 20)
  "Markdown lines generated per transcript turn.")

(defvar pilish-wr-bench-out-dir
  (expand-file-name
   (pilish-wr-bench--env "PI_WR_BENCH_OUT_DIR" "tmp/window-rewrite-bench"))
  "Output directory for this benchmark process.")

(defvar pilish-wr-bench--recorded-branch nil
  "Restore branch recorded by the current benchmark run.")

(defun pilish-wr-bench--record-fill-decision
    (original start body-height window)
  "Call ORIGINAL fill check and record its decision for the benchmark."
  (let ((fills (funcall original start body-height window)))
    (setq pilish-wr-bench--recorded-branch (if fills "fill" "fallback"))
    fills))

(defun pilish-wr-bench--restore-before (window-state)
  "Restore WINDOW-STATE using the pre-optimization whole-transcript scans.
This is a frozen copy of the old restore algorithm for A/B comparison."
  (let ((win (plist-get window-state :window)))
    (when (and (window-live-p win)
               (eq (window-buffer win) (current-buffer)))
      (with-selected-window win
        (let* ((point-max (point-max))
               (point (pilish--resolve-window-rewrite-point
                       window-state nil)))
          (if (plist-get window-state :tail-p)
              (progn
                (goto-char point-max)
                (recenter -1))
            (goto-char point)
            (let* ((body-height (max 1 (window-body-height win)))
                   (saved-start
                    (pilish--map-window-rewrite-pos
                     (plist-get window-state :start)
                     nil
                     point)))
              (let ((fills
                     (>= (count-screen-lines saved-start point-max nil win)
                         (1- body-height))))
                (setq pilish-wr-bench--recorded-branch
                      (if fills "fill" "fallback"))
                (if fills
                    (progn
                      (set-window-start win saved-start t)
                      (set-window-point win (max point saved-start)))
                  (let* ((above-lines
                          (count-screen-lines (point-min) point nil win))
                         (tail-lines
                          (max 1 (count-screen-lines point point-max nil win)))
                         (row (pilish--clamp-rewrite-point-row
                               (plist-get window-state :row)
                               above-lines tail-lines body-height)))
                    (recenter row)))))))))))

(defun pilish-wr-bench--history-text ()
  "Return a deterministic Markdown transcript at the configured size."
  (with-temp-buffer
    (dotimes (turn pilish-wr-bench-turns)
      (dotimes (line pilish-wr-bench-lines-per-turn)
        (insert
         (format "Turn %03d line %02d: **streamed status** [source](https://example.test/%03d/%02d) with `render_call(%d)` and enough prose to exercise Markdown fontification.\n"
                 turn line turn line (+ turn line))))
      (insert "\n"))
    (buffer-string)))

(defun pilish-wr-bench--line-position (line)
  "Return the buffer position at physical LINE, clamped to the buffer."
  (save-excursion
    (goto-char (point-min))
    (forward-line (max 0 line))
    (point)))

(defun pilish-wr-bench--make-window-state (window)
  "Position WINDOW for the configured case and return its captured state."
  (let* ((line-count (with-current-buffer (window-buffer window)
                       (count-lines (point-min) (point-max))))
         (height (max 1 (window-body-height window)))
         (start-line
          (if (equal pilish-wr-bench-case "short-tail")
              ;; Leave less than one viewport after START to exercise fallback.
              (max 0 (- line-count (max 2 (/ height 8))))
            (/ line-count 2)))
         (point-line
          (min (max 0 (1- line-count))
               (+ start-line (if (equal pilish-wr-bench-case "short-tail")
                                 0 (max 1 (/ height 4))))))
         start point state)
    (with-current-buffer (window-buffer window)
      (setq start (pilish-wr-bench--line-position start-line)
            point (pilish-wr-bench--line-position point-line)))
    (set-window-start window start t)
    (set-window-point window point)
    (when (display-graphic-p)
      ;; Establish a warm viewport, then the benchmark rewrites the entire
      ;; buffer so this visible region becomes dirty before restoration.
      (redisplay t))
    (with-current-buffer (window-buffer window)
      (setq state
            (pilish--capture-window-rewrite-state window (point-max))))
    (when (plist-get state :tail-p)
      (error "Benchmark setup unexpectedly produced a tail-following window"))
    state))

(defun pilish-wr-bench--run-one ()
  "Prepare one synthetic session, measure restore, and write its JSON result."
  (unless (member pilish-wr-bench-variant '("before" "after"))
    (error "Unknown benchmark variant: %s" pilish-wr-bench-variant))
  (unless (member pilish-wr-bench-case '("middle" "short-tail"))
    (error "Unknown benchmark case: %s" pilish-wr-bench-case))
  (unless (and (> pilish-wr-bench-turns 0)
               (> pilish-wr-bench-lines-per-turn 0))
    (error "Transcript dimensions must be positive"))
  (make-directory pilish-wr-bench-out-dir t)
  (let ((buffer (generate-new-buffer " *pilish-window-rewrite-bench*"))
        (window nil)
        (state nil)
        (restore-error nil)
        (restore-ms 0.0)
        (timer-before 0)
        (timer-after 0)
        (gc-before 0)
        (gc-time-before 0.0)
        (gc-count 0)
        (gc-ms 0.0)
        (point-ok nil)
        (window-ok nil)
        (viewport-ok nil)
        (fill-branch nil)
        (expected-branch (if (equal pilish-wr-bench-case "middle")
                             "fill" "fallback"))
        (window-start-position nil)
        (window-end-position nil)
        (point-row nil)
        (markdown-grammar-available
         (and (fboundp 'treesit-language-available-p)
              (ignore-errors (treesit-language-available-p 'markdown))))
        (tail-p nil)
        (height 0)
        (buffer-lines 0))
    (unwind-protect
        (condition-case err
            (progn
              (with-current-buffer buffer
                (pilish-chat-mode)
                (let ((inhibit-read-only t))
                  (insert (pilish-wr-bench--history-text))))
              (save-window-excursion
                (delete-other-windows)
                (switch-to-buffer buffer)
                (setq window (selected-window)
                      height (window-body-height window)
                      state (pilish-wr-bench--make-window-state window))
                ;; Simulate a full history replay: erase and reinsert the same
                ;; transcript so the previously fontified viewport is dirty.
                (let ((rewritten-text
                       (with-current-buffer buffer
                         (buffer-substring-no-properties
                          (point-min) (point-max)))))
                  (with-current-buffer buffer
                    (let ((inhibit-read-only t))
                      (erase-buffer)
                      (insert rewritten-text
                              "\nCompleted benchmark rewrite with **bold** and [a link](https://example.test/final).\n")
                      (setq buffer-lines (count-lines (point-min) (point-max))))))
                (setq tail-p (plist-get state :tail-p)
                      pilish-wr-bench--recorded-branch nil
                      timer-before (length timer-list)
                      gc-before gcs-done
                      gc-time-before gc-elapsed)
                (let ((started (float-time)))
                  (if (equal pilish-wr-bench-variant "before")
                      (with-current-buffer buffer
                        (pilish-wr-bench--restore-before state))
                    (advice-add 'pilish--window-start-fills-window-p :around
                                #'pilish-wr-bench--record-fill-decision)
                    (unwind-protect
                        (with-current-buffer buffer
                          (pilish--restore-window-rewrite-state state))
                      (advice-remove 'pilish--window-start-fills-window-p
                                     #'pilish-wr-bench--record-fill-decision)))
                  (setq restore-ms (* 1000.0 (- (float-time) started))))
                ;; Record scheduler and viewport state after timing so inspection
                ;; cost is not included in the restore measurement.
                (setq timer-after (length timer-list)
                      gc-count (- gcs-done gc-before)
                      gc-ms (* 1000.0 (- gc-elapsed gc-time-before))
                      fill-branch pilish-wr-bench--recorded-branch
                      point-ok (= (window-point window)
                                  (plist-get state :point))
                      window-ok (eq (window-buffer window) buffer)
                      window-start-position (window-start window)
                      window-end-position (window-end window t)
                      point-row
                      (with-current-buffer buffer
                        (count-screen-lines window-start-position
                                            (window-point window) nil window))
                      viewport-ok
                      (and (<= window-start-position (window-point window))
                           (<= (window-point window) window-end-position)
                           (if (equal pilish-wr-bench-case "middle")
                               (= window-start-position
                                  (plist-get state :start))
                             (and (>= window-end-position (point-max))
                                  (>= (with-current-buffer buffer
                                        (count-screen-lines
                                         window-start-position (point-max)
                                         nil window))
                                      (1- height))))))))
          (error
           (setq restore-error (error-message-string err))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))
    (let* ((branch-ok (equal fill-branch expected-branch))
           (ok (and (null restore-error) (not tail-p) point-ok window-ok
                    viewport-ok branch-ok))
           (result-file (expand-file-name "result.json"
                                           pilish-wr-bench-out-dir))
           (result
            (list :variant pilish-wr-bench-variant
                  :case pilish-wr-bench-case
                  :emacsVersion emacs-version
                  :displayMode (if (display-graphic-p) "gui" "batch")
                  :markdownGrammarAvailable
                  (if markdown-grammar-available t :json-false)
                  :iteration pilish-wr-bench-iteration
                  :turns pilish-wr-bench-turns
                  :linesPerTurn pilish-wr-bench-lines-per-turn
                  :bufferLines buffer-lines
                  :bodyHeight height
                  :restoreMs restore-ms
                  :timerCountBefore timer-before
                  :timerCountAfter timer-after
                  :timerCountDelta (- timer-after timer-before)
                  :gcCount gc-count
                  :gcMs gc-ms
                  :tailFollowing (if tail-p t :json-false)
                  :pointPreserved (if point-ok t :json-false)
                  :windowPreserved (if window-ok t :json-false)
                  :restoreBranch fill-branch
                  :expectedBranch expected-branch
                  :windowStart window-start-position
                  :windowEnd window-end-position
                  :pointRow point-row
                  :viewportPreserved (if viewport-ok t :json-false)
                  :ok (if ok t :json-false)
                  :error (or restore-error json-null))))
      (with-temp-file result-file
        (insert (json-encode result) "\n"))
      (princ (format "Wrote %s\n" result-file))
      ok)))

(defun pilish-wr-bench-run-batch ()
  "Run one benchmark process in batch mode and exit with its verdict."
  (kill-emacs (if (pilish-wr-bench--run-one) 0 1)))

(provide 'pilish-window-rewrite-bench)
;;; pilish-window-rewrite-bench.el ends here
