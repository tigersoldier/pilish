;;; pilish-input.el --- Input buffer, history, and completion -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Nouri

;; Author: Daniel Nouri <daniel.nouri@gmail.com>
;; Maintainer: Daniel Nouri <daniel.nouri@gmail.com>
;; URL: https://github.com/dnouri/pilish

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Input buffer features for Pilish: prompt composition,
;; history navigation (comint/eshell-style M-p/M-n), incremental
;; history search (readline-style C-r), file reference completion (@),
;; path completion (Tab), slash-command and argument completion, and fuzzy
;; in-buffer completion through Emacs's standard completion interface,
;; message queuing (follow-up and steering), and send/abort commands.
;;
;; Key entry points:
;;   `pilish-send'                  Send prompt (C-c C-c)
;;   `pilish-attach-image'          Attach one prompt image (menu C-c C-p a i)
;;   `pilish-abort'                 Abort current operation (C-c C-k)
;;   `pilish-quit'                  Close session
;;   `pilish-previous-input'        History backward (M-p)
;;   `pilish-next-input'            History forward (M-n)
;;   `pilish-input-previous-message' Navigate previous chat message
;;   `pilish-input-next-message'    Navigate next chat message
;;   `pilish-history-isearch-backward'  History search (C-r)
;;   `pilish-queue-steering'        Steering message (C-c C-s)

;;; Code:

(require 'pilish-render)
(require 'ring)

;;;; Input History (comint/eshell style)

(defvar pilish--input-ring-size 100
  "Size of the input history ring.")

(defvar-local pilish--input-ring nil
  "Ring holding input history for this session.")

(defvar-local pilish--input-ring-index nil
  "Current position in input ring, or nil if not navigating history.")

(defvar-local pilish--input-saved nil
  "Saved input before starting history navigation.")

(defvar-local pilish--history-isearch-active nil
  "Non-nil when history isearch is active.")

(defvar-local pilish--history-isearch-saved-input nil
  "Saved input before starting history isearch.")

(defvar-local pilish--history-isearch-index nil
  "Current history index during isearch.")

(defun pilish--input-ring ()
  "Return the input ring, creating if necessary."
  (unless pilish--input-ring
    (setq pilish--input-ring (make-ring pilish--input-ring-size)))
  pilish--input-ring)

(defun pilish--history-add (input)
  "Add INPUT to history ring if non-empty and different from last."
  (let ((ring (pilish--input-ring))
        (trimmed (and input (string-trim input))))
    (when (and trimmed
               (not (string-empty-p trimmed))
               (or (ring-empty-p ring)
                   (not (string= input (ring-ref ring 0)))))
      (ring-insert ring input))))

(defun pilish-previous-input ()
  "Cycle backwards through input history.
Saves current input before first navigation."
  (interactive)
  (let ((ring (pilish--input-ring)))
    (when (ring-empty-p ring)
      (user-error "No history"))
    (unless pilish--input-ring-index
      (setq pilish--input-saved (buffer-string)))
    (let ((new-index (if pilish--input-ring-index
                         (1+ pilish--input-ring-index)
                       0)))
      (if (>= new-index (ring-length ring))
          (user-error "Beginning of history")
        (setq pilish--input-ring-index new-index)
        (delete-region (point-min) (point-max))
        (insert (ring-ref ring new-index))))))

(defun pilish-next-input ()
  "Cycle forwards through input history.
Restores saved input when moving past newest entry."
  (interactive)
  (unless pilish--input-ring-index
    (user-error "End of history"))
  (let ((new-index (1- pilish--input-ring-index)))
    (delete-region (point-min) (point-max))
    (if (< new-index 0)
        (progn
          (setq pilish--input-ring-index nil)
          (when pilish--input-saved
            (insert pilish--input-saved)))
      (setq pilish--input-ring-index new-index)
      (insert (ring-ref (pilish--input-ring) new-index)))))

;;;; History Isearch

(defun pilish-history-isearch-backward ()
  "Search input history backward using isearch.
Incrementally search through history with matches appearing
directly in the input buffer, like readline."
  (interactive)
  (let ((ring (pilish--input-ring)))
    (when (ring-empty-p ring)
      (user-error "No history"))
    (setq pilish--history-isearch-active t
          pilish--history-isearch-saved-input (buffer-string)
          pilish--history-isearch-index nil)
    (isearch-backward nil t)))

(defun pilish--history-isearch-setup ()
  "Configure isearch for history searching."
  (when pilish--history-isearch-active
    (setq isearch-message-prefix-add "history ")
    (setq-local isearch-search-fun-function
                #'pilish--history-isearch-search-fun)
    (setq-local isearch-wrap-function
                #'pilish--history-isearch-wrap)
    (setq-local isearch-push-state-function
                #'pilish--history-isearch-push-state)
    (setq-local isearch-lazy-count nil)
    (add-hook 'isearch-mode-end-hook
              #'pilish--history-isearch-end nil t)))

(defun pilish--history-isearch-end ()
  "Clean up after history isearch ends.
Restore original input if isearch was quit, keep history item if accepted."
  (setq isearch-message-prefix-add nil)
  (setq-local isearch-search-fun-function #'isearch-search-fun-default)
  (setq-local isearch-wrap-function nil)
  (setq-local isearch-push-state-function nil)
  (kill-local-variable 'isearch-lazy-count)
  (remove-hook 'isearch-mode-end-hook #'pilish--history-isearch-end t)
  (when isearch-mode-end-hook-quit
    (delete-region (point-min) (point-max))
    (insert (or pilish--history-isearch-saved-input "")))
  (unless isearch-suspended
    (setq pilish--history-isearch-active nil
          pilish--history-isearch-saved-input nil
          pilish--history-isearch-index nil)))

(defun pilish--history-isearch-goto (index)
  "Load history item at INDEX into the buffer.
If INDEX is nil, restore saved input (current line content before search)."
  (setq pilish--history-isearch-index index)
  (delete-region (point-min) (point-max))
  (if (and index (not (ring-empty-p (pilish--input-ring))))
      (insert (ring-ref (pilish--input-ring) index))
    (when (and pilish--history-isearch-saved-input
               (> (length pilish--history-isearch-saved-input) 0))
      (insert pilish--history-isearch-saved-input))))

(defun pilish--history-isearch-search-fun ()
  "Return search function for history isearch.
First searches current buffer text, then cycles through history."
  (lambda (string bound noerror)
    (let ((search-fun (isearch-search-fun-default))
          (ring (pilish--input-ring))
          found)
      (or
       (funcall search-fun string bound noerror)
       (unless bound
         (condition-case nil
             (progn
               (while (not found)
                 (cond
                  (isearch-forward
                   (when (null pilish--history-isearch-index)
                     (error "End of history; no next item"))
                   (let ((new-idx (1- pilish--history-isearch-index)))
                     (if (< new-idx 0)
                         (pilish--history-isearch-goto nil)
                       (pilish--history-isearch-goto new-idx)))
                   (goto-char (point-min)))
                  (t
                   (let* ((cur-idx (or pilish--history-isearch-index -1))
                          (new-idx (1+ cur-idx)))
                     (when (>= new-idx (ring-length ring))
                       (error "Beginning of history; no preceding item"))
                     (pilish--history-isearch-goto new-idx))
                   (goto-char (point-max))))
                 (setq isearch-barrier (point)
                       isearch-opoint (point))
                 (setq found (funcall search-fun string nil noerror)))
               (point))
           (error nil)))))))

(defun pilish--history-isearch-wrap ()
  "Wrap history isearch to beginning/end of history.
For forward search: go to oldest history item.
For backward search: go to current input (nil index)."
  (pilish--history-isearch-goto
   (if isearch-forward
       (1- (ring-length (pilish--input-ring)))
     nil))
  (goto-char (if isearch-forward (point-min) (point-max))))

(defun pilish--history-isearch-push-state ()
  "Save history index for isearch state restoration."
  (let ((index pilish--history-isearch-index))
    (lambda (_cmd)
      (pilish--history-isearch-goto index))))

;;;; Input Mode

(defun pilish--input-kill-buffer-query ()
  "Ask before killing input when its linked chat owns a live process."
  (pilish--session-kill-buffer-query))

(define-derived-mode pilish-input-mode text-mode "Pi-Input"
  "Major mode for composing pi prompts.
Uses tree-sitter markdown highlighting by default while preserving raw
markup visibility, mode identity, and keybindings.  Set
`pilish-input-markdown-highlighting' to nil for plain text."
  :group 'pilish
  (when pilish-input-markdown-highlighting
    (let ((derived-name mode-name))
      ;; `md-ts-mode' is a full major mode: it clobbers the identity
      ;; `define-derived-mode' installed before running this body, so
      ;; capture and restore it rather than duplicating "Pi-Input".
      (md-ts-mode)
      (setq major-mode 'pilish-input-mode
            mode-name derived-name)
      (use-local-map pilish-input-mode-map)
      ;; Users see exactly what they type — never hide markup in input.
      (setq-local md-ts-hide-markup nil)
      (md-ts--set-hide-markup nil)))
  (setq-local header-line-format '(:eval (pilish--header-line-string)))
  ;; Reset inherited completions (text-mode adds ispell, etc.) — our
  ;; input buffer should only offer slash commands and their arguments,
  ;; file refs, and paths.
  (setq-local completion-at-point-functions nil)
  (add-hook 'completion-at-point-functions #'pilish--command-capf nil t)
  (add-hook 'completion-at-point-functions #'pilish--file-reference-capf nil t)
  (add-hook 'completion-at-point-functions #'pilish--path-capf nil t)
  ;; Keep completion front-end agnostic; Emacs's flex style allows fuzzy
  ;; subsequence matches for commands, files, and paths.
  (setq-local completion-styles '(flex))
  (add-hook 'post-self-insert-hook #'pilish--maybe-complete-at nil t)
  (add-hook 'isearch-mode-hook #'pilish--history-isearch-setup nil t)
  (add-hook 'kill-buffer-query-functions
            #'pilish--input-kill-buffer-query nil t)
  (add-hook 'kill-buffer-hook #'pilish--cleanup-input-on-kill nil t))

;;;; Input-Buffer Chat Navigation

(defun pilish--call-in-visible-chat-window (fn)
  "Call FN in the visible linked chat window, preserving input focus."
  (let* ((chat-buf (pilish--get-chat-buffer))
         (win (and (buffer-live-p chat-buf)
                   (get-buffer-window chat-buf))))
    (if (window-live-p win)
        (save-selected-window
          (select-window win)
          (funcall fn))
      (user-error "No chat window visible"))))

(defun pilish-input-next-message ()
  "Move chat to the next user message, keeping focus in input."
  (interactive)
  (pilish--call-in-visible-chat-window
   #'pilish-next-message))

(defun pilish-input-previous-message ()
  "Move chat to the previous user message, keeping focus in input."
  (interactive)
  (pilish--call-in-visible-chat-window
   #'pilish-previous-message))

;;;; Prompt Images

(defun pilish--prompt-image-byte-limit ()
  "Return the configured nonnegative byte limit for a prompt image."
  (if (natnump pilish-prompt-image-max-bytes)
      pilish-prompt-image-max-bytes
    (* 3 1024 1024)))

(defun pilish--sniff-prompt-image-mime-type (data)
  "Return the supported MIME type sniffed from unibyte DATA, or nil."
  (let ((length (length data)))
    (cond
     ((and (>= length 8)
           (= (aref data 0) #x89)
           (equal (substring data 1 8) "PNG\r\n\x1a\n"))
      "image/png")
     ((and (>= length 3)
           (= (aref data 0) #xff)
           (= (aref data 1) #xd8)
           (= (aref data 2) #xff))
      "image/jpeg")
     ((and (>= length 6)
           (member (substring data 0 6) '("GIF87a" "GIF89a")))
      "image/gif")
     ((and (>= length 12)
           (equal (substring data 0 4) "RIFF")
           (equal (substring data 8 12) "WEBP"))
      "image/webp"))))

(defun pilish--read-prompt-image (path)
  "Read and materialize supported prompt image PATH.
The file is read literally through Emacs, including through file-name
handlers, and is never handed to the Pi process as a path."
  (let* ((path (pilish--route-preserving-expand-file-name path))
         (limit (pilish--prompt-image-byte-limit))
         (attributes (file-attributes path 'string))
         (reported-size (and attributes (file-attribute-size attributes))))
    (unless (and attributes (file-regular-p path) (file-readable-p path))
      (user-error "Prompt image is not a readable regular file: %s" path))
    (when (> reported-size limit)
      (user-error "Prompt image is too large (%s; limit %s)"
                  (file-size-human-readable reported-size 'iec " " "B")
                  (file-size-human-readable limit 'iec " " "B")))
    (let ((data (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (let ((coding-system-for-read 'no-conversion))
                    (insert-file-contents-literally
                     path nil 0
                     (and (< limit most-positive-fixnum) (1+ limit))))
                  (buffer-string))))
      (when (> (length data) limit)
        (user-error "Prompt image exceeds the %s byte limit"
                    (file-size-human-readable limit 'iec " " "B")))
      (let ((mime-type (pilish--sniff-prompt-image-mime-type data)))
        (unless mime-type
          (user-error "Unsupported prompt image format: %s" path))
        (pilish--make-prompt-image
         :name (file-name-nondirectory path)
         :mime-type mime-type
         :byte-size (length data)
         :data (base64-encode-string data t))))))

;;;###autoload
(defun pilish-attach-image (&optional clear)
  "Attach one materialized image to the current prompt draft.
With prefix argument CLEAR, remove the attached image instead.  A new image
replaces the previous draft image."
  (interactive "P")
  (let ((input-buffer (pilish--get-input-buffer)))
    (unless (buffer-live-p input-buffer)
      (user-error "No pi input buffer for this command"))
    (with-current-buffer input-buffer
      (let ((chat-buf (pilish--get-chat-buffer)))
        (when (and (buffer-live-p chat-buf)
                   (with-current-buffer chat-buf
                     (pilish--prompt-start-wait-active-p)))
          (user-error
           "Cannot change prompt image while prompt acceptance is pending"))
        (if clear
            (progn
              (pilish--clear-prompt-image)
              (message "Pi: Prompt image cleared"))
          (let* ((path (read-file-name "Attach prompt image: " nil nil t))
                 (image (pilish--read-prompt-image path)))
            (pilish--set-prompt-image image)
            (message "Pi: Attached image %s"
                     (pilish--prompt-image-name image))))))))

(defun pilish--model-supports-image-input-p (chat-buffer)
  "Return non-nil only when CHAT-BUFFER's model advertises image input."
  (let* ((state (and (buffer-live-p chat-buffer)
                     (buffer-local-value 'pilish--state chat-buffer)))
         (model (and (listp state) (plist-get state :model))))
    (condition-case nil
        (and (listp model)
             (plist-member model :input)
             (let ((input (plist-get model :input)))
               (and (or (vectorp input) (listp input))
                    (member "image" (if (vectorp input)
                                        (append input nil)
                                      input))
                    t)))
      (error nil))))

;;;; Sending Prompts

(defun pilish--accept-input-text (text &optional prompt-image)
  "Accept TEXT from input buffer state, consuming optional PROMPT-IMAGE.
Adds only TEXT to history, resets history navigation, and clears input."
  (pilish--history-add text)
  (setq pilish--input-ring-index nil
        pilish--input-saved nil)
  (when prompt-image
    (pilish--clear-prompt-image))
  (erase-buffer))

(defun pilish--queue-followup-text (chat-buf text)
  "Accept TEXT and enqueue it as a follow-up in CHAT-BUF."
  (pilish--accept-input-text text)
  (with-current-buffer chat-buf
    (pilish--push-followup text)))

(defun pilish-send ()
  "Send the current input buffer contents to pi.
Clears the input buffer after sending.  Does nothing if buffer is empty.
If pi is busy (sending, streaming, or compacting), queues a local follow-up.
An attached image is accepted only with a direct, ordinary, idle prompt.
All built-in slash commands are handled locally; other slash commands are
sent to pi."
  (interactive)
  (let* ((text (string-trim (buffer-string)))
         (chat-buf (pilish--get-chat-buffer))
         (prompt-image (pilish--get-prompt-image))
         (transitioning (and chat-buf
                             (pilish--session-transition-active-p
                              chat-buf)))
         (busy (and chat-buf (pilish--session-busy-p chat-buf))))
    (cond
     ((string-empty-p text)
      (when prompt-image
        (message "Pi: Add prompt text before sending the attached image")))
     (transitioning
      (message "Pi: Cannot send while session is switching"))
     ((and prompt-image
           (pilish--model-change-pending-p chat-buf))
      (message "Pi: Wait for the pending model change before sending an image"))
     ((and prompt-image busy)
      (message "Pi: Cannot send an attached image while Pi is busy"))
     ((and prompt-image (string-prefix-p "/" text))
      (message "Pi: Attached images cannot be sent with slash commands"))
     ((and prompt-image
           (not (pilish--model-supports-image-input-p chat-buf)))
      (message "Pi: Current model does not support known image input"))
     ((and busy (pilish--builtin-command-text-p text))
      (message "Pi: Cannot queue /%s while Pi is busy"
               (pilish--builtin-command-name text)))
     (busy
      (pilish--queue-followup-text chat-buf text)
      (pilish--maybe-hide-input-window)
      (message "Pi: Message queued (will send when Pi is ready)"))
     (prompt-image
      (pilish--accept-input-text text prompt-image)
      (pilish--maybe-hide-input-window)
      (with-current-buffer chat-buf
        (pilish--prepare-and-send text nil prompt-image)))
     (t
      (pilish--accept-input-text text)
      (pilish--maybe-hide-input-window)
      (with-current-buffer chat-buf
        (pilish--prepare-and-send text))))))

(defun pilish-abort ()
  "Stop the current pi operation and discard queued continuations.
Works while sending, streaming or compacting.  A stop during preflight is
retained if Pi subsequently starts the accepted prompt."
  (interactive)
  (when-let* ((chat-buf (pilish--get-chat-buffer)))
    (with-current-buffer chat-buf
      (when (or (memq pilish--status '(sending streaming compacting))
                (pilish--prompt-start-wait-active-p)
                (pilish--command-pending-p (pilish--get-process) "compact"))
        (pilish--set-aborted t)
        (pilish--clear-followup-queue)
        (pilish--send-abort)
        (message "Pi: Aborting...")))))

(defun pilish-quit ()
  "Close the current pi session.
Kills both chat and input buffers, terminates the process,
and removes the input window (merging its space with adjacent windows).

If a process is running, asks for confirmation first unless
`pilish-quit-without-confirmation' is non-nil.  If the user
cancels, the session remains intact."
  (interactive)
  (let* ((chat-buf (pilish--get-chat-buffer))
         (input-buf (pilish--get-input-buffer))
         (proc (when (buffer-live-p chat-buf)
                 (buffer-local-value 'pilish--process chat-buf)))
         (proc-live (and proc (process-live-p proc)))
         (input-windows nil))
    (when (and (pilish--process-kill-confirmation-required-p proc)
               (not (yes-or-no-p "Pi session has a running process; quit anyway? ")))
      (user-error "Quit cancelled"))
    ;; Suppress Emacs and pi buffer-kill prompts after explicit confirmation.
    (when proc-live
      (pilish--skip-process-kill-confirmation proc)
      (set-process-query-on-exit-flag proc nil))
    (when (buffer-live-p input-buf)
      (setq input-windows (get-buffer-window-list input-buf nil t)))
    ;; Kill chat first — its cleanup hook cascades to input buffer
    (when (buffer-live-p chat-buf)
      (kill-buffer chat-buf))
    (when (buffer-live-p input-buf)
      (kill-buffer input-buf))
    (dolist (win input-windows)
      (when (and (window-live-p win)
                 (window-deletable-p win))
        (delete-window win)))))

;;;; Slash Command Completion

(defun pilish--slash-command-context-p ()
  "Return non-nil when point is inside a slash command on the first line.
Pi expands slash commands only when the whole input starts with \"/\", so
completion is restricted to the first line of the buffer."
  (and (> (point) (point-min))
       (eq (char-after (point-min)) ?/)
       (= (line-beginning-position) (point-min))
       (<= (point) (line-end-position))))

(defun pilish--slash-command-entries ()
  "Return slash-command completion entries for the current session.
Entries may carry :description, :argument-hint, and :source.  Built-in
entries shadow same-named RPC commands so completion follows dispatch."
  (append
   (mapcar (lambda (builtin)
             (let* ((name (car builtin))
                    (props (cdr builtin))
                    (entry (list :name name :kind 'builtin)))
               (when-let* ((description (plist-get props :description)))
                 (plist-put entry :description description))
               (when-let* ((hint (plist-get props :argument-hint)))
                 (plist-put entry :argument-hint hint))
               entry))
           pilish--builtin-commands)
   (delq nil
         (mapcar (lambda (command)
                   (when-let* ((name (plist-get command :name)))
                     (unless (assoc name pilish--builtin-commands)
                       (let ((entry (list :name name :kind 'rpc)))
                         (when-let* ((description (plist-get command :description)))
                           (plist-put entry :description description))
                         (when-let* ((source (plist-get command :source)))
                           (plist-put entry :source source))
                         (when-let* ((hint (or (plist-get command :argumentHint)
                                               (plist-get command :argument-hint))))
                           (plist-put entry :argument-hint hint))
                         entry))))
                 pilish--commands))))

(defun pilish--slash-command-entry (name entries)
  "Return the completion entry for slash command NAME in ENTRIES, or nil."
  (cl-find name entries :key (lambda (entry) (plist-get entry :name))
           :test #'equal))

(defun pilish--command-annotation-string (entry)
  "Return completion annotation text for slash-command ENTRY, or nil.
Shows its description and any argument placeholder hint."
  (when entry
    (let* ((description (plist-get entry :description))
           (hint (when-let* ((h (plist-get entry :argument-hint)))
                   (format "<%s>"
                           (replace-regexp-in-string "\\`<\\|>\\'" "" h))))
           (parts (delq nil (list description hint))))
      (and parts (concat " " (mapconcat #'identity parts "  "))))))

(defun pilish--command-capf ()
  "Complete slash commands and known argument values at point.
On the first line, command names complete after the leading slash and
carry descriptions and argument hints as annotations.  After a space,
commands registered in `pilish-command-argument-completions' complete
their argument values instead.  This standard CAPF interface is usable
by Emacs and any compatible in-buffer completion front end."
  (when (pilish--slash-command-context-p)
    (let* ((line (buffer-substring (1+ (point-min)) (line-end-position)))
           (space-idx (and (string-match "[ \t]" line) (match-beginning 0)))
           (name (substring line 0 (or space-idx (length line))))
           (name-start (1+ (point-min)))
           (args-p (and space-idx (> (point) (+ name-start space-idx)))))
      (if args-p
          (when-let* ((completion-entry
                       (assoc name pilish-command-argument-completions)))
            (let* ((arg-start (+ name-start space-idx 1))
                   (prefix (buffer-substring arg-start (point)))
                   (candidates (funcall (cdr completion-entry) prefix)))
              (and candidates
                   (list arg-start (point) candidates :exclusive 'no))))
        (let* ((entries (pilish--slash-command-entries))
               (commands (mapcar (lambda (entry) (plist-get entry :name))
                                 entries)))
          (list name-start (point) commands
                :exclusive 'no
                :annotation-function
                (lambda (candidate)
                  (pilish--command-annotation-string
                   (pilish--slash-command-entry candidate entries)))))))))

;;;; /model Argument Completion

(defconst pilish--models-cache-ttl 60
  "Seconds before the cached /model argument candidate list expires.")

(defvar-local pilish--models-cache nil
  "Cached (label . model) alist for /model argument completion.")

(defvar-local pilish--models-cache-time nil
  "Float time when `pilish--models-cache' was last fetched.")

(defun pilish--available-models ()
  "Return cached (label . model) entries for available models, or nil.
Refetches with `get_available_models' when the cache is stale."
  (when-let* ((proc (pilish--get-process)))
    (when (and (processp proc) (process-live-p proc))
      (let ((now (float-time)))
        (when (or (null pilish--models-cache-time)
                  (> (- now pilish--models-cache-time)
                     pilish--models-cache-ttl))
          (setq pilish--models-cache
                (condition-case nil
                    (let* ((response
                            (pilish--rpc-sync
                             proc '(:type "get_available_models") 3))
                           (models (plist-get (plist-get response :data)
                                              :models)))
                      (mapcar
                       (lambda (model)
                         (cons (format "%s [%s]"
                                       (pilish--shorten-model-name
                                        (plist-get model :name))
                                       (or (plist-get model :provider) "?"))
                               model))
                       models))
                  (error nil)))
          (setq pilish--models-cache-time now)))
        pilish--models-cache)))

(defun pilish-model-argument-completions (prefix)
  "Return available model labels matching PREFIX for /model arguments.
Labels match those used by `pilish-select-model', so completing and
sending a model command selects it without another prompt."
  (let ((labels (mapcar #'car (pilish--available-models))))
    (and labels
         (cl-remove-if-not
          (lambda (label) (string-prefix-p prefix label t))
          labels))))

(defun pilish--slash-command-trigger-p ()
  "Return non-nil when / was just typed as the first input character."
  (and (eq (char-before (point)) ?/)
       (= (point) (1+ (point-min)))
       (= (line-beginning-position) (point-min))))

(defun pilish--slash-argument-trigger-p ()
  "Return non-nil when SPC just completed a command with known arguments."
  (and (eq (char-before (point)) ?\s)
       (> (point) (+ 2 (point-min)))
       (eq (char-after (point-min)) ?/)
       (let ((text (buffer-substring (1+ (point-min)) (1- (point)))))
         (and (string-match-p "\\`[^ \t]+\\'" text)
              (assoc text pilish-command-argument-completions)
              t))))

;;;; In-Buffer Completion Front Ends

(defun pilish--in-buffer-completion-active-p ()
  "Return non-nil when a buffer-local completion front-end is active."
  (not (eq completion-in-region-function
           (default-value 'completion-in-region-function))))

(defun pilish--run-in-buffer-completion ()
  "Run `completion-at-point' when an in-buffer front-end is active.
Return non-nil when completion was started."
  (when (pilish--in-buffer-completion-active-p)
    (completion-at-point)
    t))

(defun pilish--schedule-in-buffer-completion ()
  "Schedule in-buffer completion after the current command."
  (run-at-time 0 nil #'pilish--run-in-buffer-completion))

;;;; Editor Features: File Reference (@)

(defun pilish--at-trigger-p ()
  "Return non-nil if @ at point should trigger file completion.
Returns nil when @ follows an alphanumeric character (like in emails).
Assumes point is right after the @."
  (or (< (point) 3)  ; @ at buffer start or position 2 (no char before @)
      (save-excursion
        (backward-char 2)  ; Move to char before @
        (looking-at-p "[^[:alnum:]]"))))

(defun pilish--maybe-complete-at ()
  "Trigger in-buffer completion for slash commands and file references.
Runs after / at the start of input, after @ at a word boundary, and after
the space following a command with known argument values.  File references
fall back to the minibuffer if no in-buffer front-end is active."
  (let ((event last-command-event))
    (cond
     ((and (eq event ?@) (pilish--at-trigger-p))
      (run-at-time 0 nil #'pilish--complete-file-reference))
     ((and (eq event ?/) (pilish--slash-command-trigger-p))
      (pilish--schedule-in-buffer-completion))
     ((and (eq event ?\s) (pilish--slash-argument-trigger-p))
      (pilish--schedule-in-buffer-completion)))))

(defun pilish--complete-file-reference ()
  "Complete file reference after @, preferring an in-buffer front-end."
  (if (pilish--run-in-buffer-completion)
      nil
    (let* ((files (pilish--get-project-files))
           (choice (completing-read "File: " files nil nil)))
      (when (and choice (not (string-empty-p choice)))
        (insert choice)))))

(defvar-local pilish--project-files-cache nil
  "Cached list of project files for @ completion.")

(defvar-local pilish--project-files-cache-time nil
  "Time when project files cache was last updated.")

(defconst pilish--project-files-cache-ttl 30
  "Seconds before project files cache expires.")

(defconst pilish--file-exclude-patterns
  '(".git" "node_modules" ".elpa" "target" "build" "__pycache__" ".venv" "dist")
  "Directory names to exclude when listing files with find.")

(defun pilish--get-project-files ()
  "Get list of project files, respecting .gitignore.
Uses cache if available and not expired."
  (let ((now (float-time)))
    (when (or (null pilish--project-files-cache)
              (null pilish--project-files-cache-time)
              (> (- now pilish--project-files-cache-time)
                 pilish--project-files-cache-ttl))
      (setq pilish--project-files-cache
            (pilish--list-project-files))
      (setq pilish--project-files-cache-time now))
    pilish--project-files-cache))

(defun pilish--list-project-files ()
  "List project files using git ls-files or find.
Respects .gitignore when in a git repository."
  (let* ((dir (pilish--session-directory))
         (default-directory dir))
    (condition-case nil
        (let ((output (shell-command-to-string
                       "git ls-files --cached --others --exclude-standard 2>/dev/null")))
          (if (string-empty-p output)
              (pilish--list-files-with-find dir)
            (split-string output "\n" t)))
      (error (pilish--list-files-with-find dir)))))

(defun pilish--list-files-with-find (dir)
  "List files in DIR using find.
Excludes directories listed in `pilish--file-exclude-patterns'."
  (let* ((default-directory dir)
         (prune-expr (mapconcat (lambda (p) (format "-name '%s'" p))
                                pilish--file-exclude-patterns
                                " -o "))
         (cmd (format "find . \\( %s \\) -prune -o -type f -print 2>/dev/null | sed 's|^\\./||'"
                      prune-expr)))
    (split-string (shell-command-to-string cmd) "\n" t)))

(defun pilish--file-reference-capf ()
  "Completion-at-point function for @file references.
Triggers when @ is typed, provides completion of project files."
  (when-let* ((at-pos (save-excursion
                        (when (search-backward "@" (line-beginning-position) t)
                          (point)))))
    (let* ((start (1+ at-pos))
           (end (point))
           (prefix (buffer-substring-no-properties start end))
           (files (pilish--get-project-files))
           (candidates (if (string-empty-p prefix)
                           files
                         (cl-remove-if-not
                          (lambda (f) (string-match-p (regexp-quote prefix) f))
                          files))))
      (when candidates
        (list start end candidates
              :exclusive 'no
              :annotation-function (lambda (_) " (file)")
              :company-kind (lambda (_) 'file))))))

;;;; Editor Features: Path Completion

(defun pilish--path-prefix-p (path)
  "Check if PATH has a completable prefix (./, ../, ~/, or /)."
  (or (string-prefix-p "./" path)
      (string-prefix-p "../" path)
      (string-prefix-p "~/" path)
      (string-prefix-p "/" path)))

(defun pilish--path-completions (path)
  "Return file completion candidates for PATH, or nil if directory invalid."
  (condition-case nil
      (let* ((dir (pilish--route-preserving-file-name-directory path))
             (base (file-name-nondirectory path))
             (session-dir (pilish--session-directory))
             (expanded-dir (if dir
                               (pilish--route-preserving-file-name-as-directory
                                (pilish--emacs-path dir session-dir))
                             session-dir)))
        (when (file-directory-p expanded-dir)
          (mapcar (lambda (f) (concat (or dir "") f))
                  (cl-remove-if (lambda (f) (member f '("." ".." "./" "../")))
                                (file-name-all-completions base expanded-dir)))))
    (error nil)))

(defun pilish--path-capf ()
  "Completion-at-point function for file paths.
Completes paths starting with ./, ../, ~/, or /.
Skips / at buffer start to allow slash command completion."
  (when-let* ((bounds (bounds-of-thing-at-point 'filename))
              (start (car bounds))
              (end (cdr bounds))
              (path (buffer-substring-no-properties start end))
              ((pilish--path-prefix-p path))
              ((not (and (string-prefix-p "/" path)
                         (= start (point-min)))))
              (candidates (pilish--path-completions path)))
    (list start end candidates
          :exclusive 'no
          :annotation-function
          (lambda (c)
            (if (string-suffix-p "/" c) " (dir)" " (file)")))))

;;;; Editor Features: Message Queuing

(defun pilish--send-steer-message (text)
  "Send TEXT as a steering message via RPC.
Return t if scheduled, nil if the process is unavailable.
Report acceptance or failure after the current process acknowledges it."
  (let ((proc (pilish--get-process))
        (chat-buf (pilish--get-chat-buffer)))
    (if (and proc (process-live-p proc))
        (progn
          (pilish--rpc-async
           proc (list :type "steer" :message text)
           (lambda (response)
             (when (and (buffer-live-p chat-buf)
                        (eq proc (with-current-buffer chat-buf (pilish--get-process))))
               (if (eq (plist-get response :success) t)
                   (message "%s"
                            (pcase (plist-get (plist-get response :data) :disposition)
                              ("queued" "Pi: Steering acknowledged as queued")
                              ("handled" "Pi: Steering handled by extension")
                              (_ "Pi: Steering message sent")))
                 (message "Pi: Steering failed: %s"
                          (or (plist-get response :error) "unknown error"))))))
          t)
      (message "Pi: Cannot send steering - process unavailable")
      nil)))

(defun pilish-queue-steering ()
  "Send current input as a steering message.
During streaming, steering interrupts remaining tools.  It can also queue
in Pi before a local prompt starts or during an announced retry.
Unlike normal sends, steering is NOT displayed locally - pi will echo
it back via message_start at the correct position (after current
assistant output completes).

During compaction or while awaiting run settlement, steering text is queued
as a local follow-up.  It is sent after the surrounding run and any local
command reservation finish.  Steering refuses a draft image."
  (interactive)
  (let ((text (string-trim (buffer-string))))
    (if (pilish--get-prompt-image)
        (message "Pi: Cannot steer with an attached image")
      (unless (string-empty-p text)
        (let ((chat-buf (pilish--get-chat-buffer)))
          (when chat-buf
            (let ((status (buffer-local-value 'pilish--status chat-buf)))
              (cond
               ((pilish--session-transition-active-p chat-buf)
                (message "Pi: Cannot send steering while session is switching"))
               ((and (eq status 'idle)
                     (not (pilish--session-busy-p chat-buf)))
                (message "Pi: Nothing to interrupt - use C-c C-c to send"))
               ((or (eq status 'compacting)
                    (and (memq status '(idle sending))
                         (not (pilish--session-steerable-p chat-buf))))
                (pilish--queue-followup-text chat-buf text)
                (message "Pi: Steering queued (will send when Pi is ready)"))
               ((memq status '(sending streaming))
                (when (pilish--send-steer-message text)
                  (pilish--accept-input-text text)))
               (t
                (message "Pi: Cannot steer while session status is %s"
                         status))))))))))

(defun pilish-queue-followup ()
  "Queue current input as a follow-up message.
Obsolete: Use `pilish-send' (C-c C-c) instead, which now
automatically queues as follow-up when the agent is busy."
  (interactive)
  (pilish-send))
(make-obsolete 'pilish-queue-followup 'pilish-send "1.3.0")

(provide 'pilish-input)
;;; pilish-input.el ends here
