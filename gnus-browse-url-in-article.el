;;; gnus-browse-url-in-article.el --- Smarter browse-url for Gnus articles -*- lexical-binding: t; -*-

;; Copyright (C) 2026 JM Ibañez

;; Author: JM Ibañez <jm@jmibanez.com>
;; URL: https://github.com/jmibanez/gnus-browse-url-in-article
;; Version: 1.0.0
;; Package-Requires: ((emacs "26.1"))
;; Keywords: convenience, mail, gnus

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
;; General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <http://www.gnu.org/licenses/>.

;; This file is not part of GNU Emacs.

;;; Commentary:

;;; Provides `gnus-browse-url-in-article', an extensible command for
;;; browsing the "best" URL in a Gnus article. Built-in handlers cover
;;; GitHub PR notifications and LinkedIn job alerts. Additional
;;; per-sender handlers can be registered via
;;; `gnus-browse-url-in-article-handlers'.

;;; Handler protocol (EIEIO):

;;;   Subclass `gnus-browse-url-in-article-handler' and implement two methods:
;;;     * `gnus-browse-url-in-article-handler-matches-p' — return
;;;       non-nil if this handler applies to the current article;
;;;       called in `gnus-summary-mode' context.
;;;     * `gnus-browse-url-in-article-handler-get-urls' — return a (display . url) alist,
;;;       or nil to fall through to the next handler.
;;;
;;;   For simple cases, use `gnus-browse-url-in-article-make-handler'
;;;   to create a `gnus-browse-url-in-article-function-handler' from a
;;;   predicate and handler function.

;;; Code:

(require 'eieio)
(require 'gnus)
(require 'gnus-sum)
(require 'mm-decode)
(require 'cl-lib)
(require 'dom)

;; ---------- Handler base class and protocol ----------

(defclass gnus-browse-url-in-article-handler ()
  ()
  "Abstract base class for Gnus article URL handlers.
Subclasses must implement `gnus-browse-url-in-article-handler-matches-p' and
`gnus-browse-url-in-article-handler-get-urls'.")

(cl-defgeneric gnus-browse-url-in-article-handler-matches-p (handler)
  "Return non-nil if HANDLER should process the current Gnus article.
Called in `gnus-summary-mode' context; may freely inspect
`gnus-summary-article-header'.")

(cl-defgeneric gnus-browse-url-in-article-handler-get-urls (handler)
  "Return a (display . url) alist for the current article, or nil.
Returning nil causes the dispatch loop to try the next HANDLER.")

;; ---------- Helper class: parse HTML beforehand ----------

(defclass gnus-browse-url-in-article-html-handler (gnus-browse-url-in-article-handler)
  ()
  "Helper abstract base class that parses HTML before hand.")

(cl-defgeneric gnus-browse-url-in-article-handler-get-html-urls (handler html-handle dom)
  "Return a (display . url) alist for the current article, or nil.
HTML-HANDLE is the handle of the HTML MIME part; DOM is the parsed
document object model for that HTML MIME part. Returning nil causes the
dispatch loop to try the next HANDLER.")

(cl-defmethod gnus-browse-url-in-article-handler-get-urls ((h gnus-browse-url-in-article-html-handler))
  (when-let* ((html-handle (gnus-browse-url-in-article--article-html-handle))
              (dom         (gnus-browse-url-in-article--parse-html-handle html-handle)))
    (gnus-browse-url-in-article-handler-get-html-urls h html-handle dom)))

;; ---------- Function-based handler ----------

(defclass gnus-browse-url-in-article-function-handler (gnus-browse-url-in-article-handler)
  ((predicate  :initarg :predicate
               :type function
               :documentation
               "Zero-arg function; return non-nil if this handler applies.")
   (handler-fn :initarg :handler-fn
               :type function
               :documentation
               "Zero-arg function; return (display . url) alist or nil."))
  "A URL handler backed by a predicate and handler function pair.
Create instances with `gnus-browse-url-in-article-make-handler'.")

(cl-defmethod gnus-browse-url-in-article-handler-matches-p ((h gnus-browse-url-in-article-function-handler))
  (funcall (oref h predicate)))

(cl-defmethod gnus-browse-url-in-article-handler-get-urls ((h gnus-browse-url-in-article-function-handler))
  (funcall (oref h handler-fn)))


;; ---------- Group and customization ----------

(defgroup gnus-browse-url-in-article nil
  "Smarter `browse-url' for Gnus articles."
  :group 'gnus)

(defcustom gnus-browse-url-in-article-handlers nil
  "List of handler instances for article URL browsing.

Each handler is tried after `gnus-browse-url-in-article-default-handlers'
and before the generic fallback.  The first handler for which
`gnus-browse-url-in-article-handler-matches-p' returns non-nil and
`gnus-browse-url-in-article-handler-get-urls' returns a non-nil alist wins.

Use `gnus-browse-url-in-article-add-handler' to prepend entries,
`gnus-browse-url-in-article-make-handler' to construct one from functions,
or `register-gnus-browse-in-article-handler' to do both in one form."
  :type '(repeat (sexp :tag "gnus-browse-url-in-article-handler instance"))
  :group 'gnus-browse-url-in-article)


;; ---------- Internal utilities ----------

(defun gnus-browse-url-in-article--article-html-handle ()
  "Return the HTML MIME handle for the current Gnus article, or nil."
  (let ((handles (with-current-buffer gnus-article-buffer
                   gnus-article-mime-handles)))
    (when handles
      (mm-find-part-by-type (list handles) "text/html" nil t))))

(defun gnus-browse-url-in-article--collect-prop-urls (property)
  "Scan current buffer for text-property PROPERTY; return (display . url) alist.
Deduplicates by URL.  Display is \"text (url)\" when the link text differs
from the URL, otherwise just the URL string."
  (let (result seen-urls)
    (cl-flet ((record-url (pos)
                (when-let* ((url (get-text-property pos property)))
                  (unless (member url seen-urls)
                    (push url seen-urls)
                    (let* ((end     (or (next-single-property-change pos property)
                                        (point-max)))
                           (text    (string-trim
                                     (buffer-substring-no-properties pos end)))
                           (display (if (and (not (string-empty-p text))
                                             (not (string= text url)))
                                        (format "%s (%s)" text url)
                                      url)))
                      (push (cons display url) result))))))
      (let ((pos (point-min)))
        (record-url pos)
        (while (setq pos (next-single-property-change pos property))
          (record-url pos))))
    (nreverse result)))

(defun gnus-browse-url-in-article--collect-from-html-handle (html-handle)
  "Render HTML-HANDLE with w3m and return (display . url) alist, or nil.
Returns nil if w3m is unavailable or rendering fails."
  (and (fboundp 'w3m-region)
       (condition-case nil
           (with-temp-buffer
             (mm-insert-part html-handle)
             (w3m-region (point-min) (point-max))
             (gnus-browse-url-in-article--collect-prop-urls 'w3m-href-anchor))
         (error nil))))

(defun gnus-browse-url-in-article--parse-html-handle (handle)
  "Parse HANDLE's HTML content and return a libxml DOM tree.
Inserts raw bytes into a unibyte buffer so libxml2 can detect the charset
from the HTML's own <meta charset> tag.  This avoids the double-decoding
artifacts that cause Unicode characters (e.g. curly quotes) to appear as
octal byte sequences in extracted text."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert (mm-get-part handle))
    (libxml-parse-html-region (point-min) (point-max))))

(defun gnus-browse-url-in-article--article-canonical-url (html-handle)
  "Extract a canonical URL from HTML-HANDLE's raw HTML, or nil."
  (when html-handle
    (with-temp-buffer
      (mm-insert-part html-handle)
      (goto-char (point-min))
      (or
       (and (re-search-forward
             "<link[^>]+rel=[\"']canonical[\"'][^>]+href=[\"']\\([^\"']+\\)[\"']"
             nil t)
            (match-string 1))
       (progn (goto-char (point-min))
              (and (re-search-forward
                    "<link[^>]+href=[\"']\\([^\"']+\\)[\"'][^>]+rel=[\"']canonical[\"']"
                    nil t)
                   (match-string 1)))
       (progn (goto-char (point-min))
              (and (re-search-forward
                    "<meta[^>]+property=[\"']og:url[\"'][^>]+content=[\"']\\([^\"']+\\)[\"']"
                    nil t)
                   (match-string 1)))
       (progn (goto-char (point-min))
              (and (re-search-forward
                    "<meta[^>]+content=[\"']\\([^\"']+\\)[\"'][^>]+property=[\"']og:url[\"']"
                    nil t)
                   (match-string 1)))))))

(defun gnus-browse-url-in-article--article-url-alist-generic (html-handle)
  "Return (display . url) alist by scanning HTML-HANDLE or the article buffer.
Tries in order: w3m-rendered HTML handle → rendered article buffer → plain text."
  (or (and html-handle
           (gnus-browse-url-in-article--collect-from-html-handle html-handle))
      (with-current-buffer gnus-article-buffer
        (save-excursion
          (goto-char (point-min))
          (or (if (bound-and-true-p w3m-minor-mode)
                  (gnus-browse-url-in-article--collect-prop-urls 'w3m-href-anchor)
                (gnus-browse-url-in-article--collect-prop-urls 'shr-url))
              ;; plain-text last resort
              (let (result seen-urls)
                (while (re-search-forward "https?://[^ \t\n<>\"',;)]+" nil t)
                  (let ((url (match-string 0)))
                    (unless (member url seen-urls)
                      (push url seen-urls)
                      (push (cons url url) result))))
                (nreverse result)))))))

(defun gnus-browse-url-in-article--find-view-in-browser-url (dom)
  "Find a \"view in browser\" link in DOM; return a (display . url) pair, or nil.
Matches the first anchor whose visible text contains a variant of
\"view ... browser\" or \"view ... online\"."
  (catch 'found
    (cl-labels ((walk (node)
                  (when (and (listp node) (symbolp (car node)))
                    (when (eq (car node) 'a)
                      (let ((href (dom-attr node 'href))
                            (text (string-trim (dom-texts node ""))))
                        (when (and href
                                   (not (string-empty-p text))
                                   (string-match-p
                                    "\\(view\\|read\\).+\\(browser\\|online\\)"
                                    (downcase text)))
                          (throw 'found (cons text href)))))
                    (mapc #'walk (cddr node)))))
      (walk dom))
    nil))


;; ---------- Predicate helpers ----------

(defun gnus-browse-url-in-article-if-from (regexp)
  "Return a predicate function matching articles whose From header matches REGEXP.
The returned function is suitable as the :predicate of a
`gnus-browse-url-in-article-function-handler'."
  (lambda ()
    (when-let* ((from (mail-header-from (gnus-summary-article-header))))
      (string-match regexp from))))


;; ---------- Built-in handler: GitHub PR ----------

(defclass gnus-browse-url-in-article-github-pr-handler (gnus-browse-url-in-article-handler)
  ()
  "URL handler for GitHub pull request notification emails.
Matches message-ids of the form <owner/repo/pull/N@github.com> and
constructs the canonical PR URL directly from the message-id.")

(cl-defmethod gnus-browse-url-in-article-handler-matches-p ((_h gnus-browse-url-in-article-github-pr-handler))
  (let ((message-id (mail-header-id (gnus-summary-article-header))))
    (string-match "<[^/]+/[^/]+/pull/[0-9]+\\(/.*\\)?@github.com>"
                  message-id)))

(cl-defmethod gnus-browse-url-in-article-handler-get-urls ((_h gnus-browse-url-in-article-github-pr-handler))
  (let* ((message-id (mail-header-id (gnus-summary-article-header)))
         (match (string-match
                 "<\\([^/]+\\)/\\([^/]+\\)/pull/\\([0-9]+\\)\\(/.*\\)?@github.com>"
                 message-id)))
    (when match
      (let ((url (format "https://github.com/%s/%s/pull/%s"
                         (match-string 1 message-id)
                         (match-string 2 message-id)
                         (match-string 3 message-id))))
        (list (cons url url))))))


;; ---------- Built-in handler: LinkedIn jobs ----------

(defclass gnus-browse-url-in-article-linkedin-jobs-handler (gnus-browse-url-in-article-html-handler)
  ()
  "URL handler for LinkedIn job alert emails.
Parses the HTML part to extract job title and company/location from each
job card, returning entries of the form \"Company · Location — Title\".")

(cl-defmethod gnus-browse-url-in-article-handler-matches-p ((_h gnus-browse-url-in-article-linkedin-jobs-handler))
  (when-let* ((from (mail-header-from (gnus-summary-article-header))))
    (string-match "linkedin\\.com" from)))

(cl-defmethod gnus-browse-url-in-article-handler-get-html-urls ((_h gnus-browse-url-in-article-linkedin-jobs-handler)
                                                                html-handle dom)
  (let* ((flat-nodes nil)
         result seen-ids)
    ;; DFS walk: collect title links and company paragraphs in document order
    (cl-labels ((walk (node)
                  (when (and (listp node) (symbolp (car node)))
                    (let ((tag (car node)))
                      (cond
                       ;; Job title: <a href="...jobs/view/N..." class="...font-bold...">
                       ((and (eq tag 'a)
                             (string-match "jobs/view/[0-9]+"
                                           (or (dom-attr node 'href) ""))
                             (string-match "\\bfont-bold\\b"
                                           (or (dom-attr node 'class) "")))
                        (push (cons 'job-title node) flat-nodes))
                       ;; Company + location: <p class="text-system-gray-100 ...">
                       ((and (eq tag 'p)
                             (string-match "text-system-gray-100"
                                           (or (dom-attr node 'class) "")))
                        (push (cons 'company node) flat-nodes))))
                    (mapc #'walk (cddr node)))))
      (walk dom))
    (setq flat-nodes (nreverse flat-nodes))
    ;; Pair each title link with the next company paragraph that follows it
    (let ((remaining flat-nodes))
      (while remaining
        (when (eq (caar remaining) 'job-title)
          (let* ((link         (cdar remaining))
                 (href         (dom-attr link 'href))
                 (title        (string-trim (dom-texts link "")))
                 (job-id       (and (string-match "jobs/view/\\([0-9]+\\)" href)
                                    (match-string 1 href)))
                 (company-node (cdr (cl-find 'company (cdr remaining) :key #'car)))
                 (company      (and company-node
                                    (string-trim (dom-texts company-node ""))))
                 (clean-url    (and job-id
                                    (format "https://www.linkedin.com/jobs/view/%s/"
                                            job-id)))
                 (display      (if (and company (not (string-empty-p company)))
                                   (format "%s - %s" company title)
                                 title)))
            (when (and job-id clean-url (not (member job-id seen-ids)))
              (push job-id seen-ids)
              (push (cons display clean-url) result))))
        (setq remaining (cdr remaining))))
    (nreverse result)))


;; ---------- Built-in handler: Ars Technica ----------

(defun gnus-browse-url-in-article--ars-decode-click-url (tracking-url)
  "Decode an Ars Technica /click/ TRACKING-URL and strip UTM parameters.
The tracking URL embeds the real destination as a base64url-encoded path
segment: https://link.arstechnica.com/click/NUMBER/BASE64.
Returns the clean article URL, or nil if not a recognised Ars tracking link."
  (when (string-match "/click/[0-9.]+/\\([A-Za-z0-9_-]+\\)" tracking-url)
    (let* ((b64     (match-string 1 tracking-url))
           (padding (mod (- 4 (mod (length b64) 4)) 4))
           (padded  (concat b64 (make-string padding ?=)))
           (decoded (condition-case nil
                        (decode-coding-string
                         (base64-decode-string padded t)
                         'utf-8)
                      (error nil))))
      (when (and decoded (string-match "arstechnica\\.com" decoded))
        (replace-regexp-in-string "\\?.*" "" decoded)))))

(defun gnus-browse-url-in-article--ars-button-url (button-node)
  "Return decoded article URL from button_block DOM node BUTTON-NODE, or nil.
Searches NODE's subtree for the first <a> with a decodable /click/ href."
  (catch 'found
    (cl-labels ((search (node)
                  (when (and (listp node) (symbolp (car node)))
                    (when (eq (car node) 'a)
                      (let ((url (gnus-browse-url-in-article--ars-decode-click-url
                                  (or (dom-attr node 'href) ""))))
                        (when url (throw 'found url))))
                    (mapc #'search (cddr node)))))
      (search button-node))
    nil))

(defclass gnus-browse-url-in-article-ars-technica-handler (gnus-browse-url-in-article-html-handler)
  ()
  "URL handler for Ars Technica newsletter emails.
Extracts article titles from text_block tables and decodes the
corresponding /click/ tracking URLs, pairing them for `completing-read'.")

(cl-defmethod gnus-browse-url-in-article-handler-matches-p ((_h gnus-browse-url-in-article-ars-technica-handler))
  (when-let* ((from (mail-header-from (gnus-summary-article-header))))
    (string-match "arstechnica\\.com" from)))

(cl-defmethod gnus-browse-url-in-article-handler-get-html-urls ((_h gnus-browse-url-in-article-ars-technica-handler)
                                                                html-handle dom)
  (when-let ((vib-link    (and dom (gnus-browse-url-in-article--find-view-in-browser-url dom))))
    (let ((flat-nodes nil))
      ;; DFS walk: collect titles and button URLs in document order.
      ;; Only match the mobile_hide (desktop) variants to avoid collecting
      ;; the duplicate desktop_hide (mobile) versions of each block.
      (cl-labels ((walk (node)
                    (when (and (listp node) (symbolp (car node)))
                      (let ((cls (or (dom-attr node 'class) "")))
                        (cond
                         ;; Article title block (desktop version)
                         ((string= cls "text_block block-1 mobile_hide")
                          (let ((title (string-trim (dom-texts node ""))))
                            (unless (string-empty-p title)
                              (push (cons 'title title) flat-nodes))))
                         ;; Read Full Story button (desktop version)
                         ((string= cls "button_block block-2 mobile_hide")
                          (let ((url (gnus-browse-url-in-article--ars-button-url node)))
                            (when url
                              (push (cons 'url url) flat-nodes))))
                         ;; Recurse into everything else
                         (t (mapc #'walk (cddr node))))))))
        (walk dom))
      ;; The flat list alternates title/url perfectly; zip them.
      (let (titles urls)
        (dolist (entry (nreverse flat-nodes))
          (if (eq (car entry) 'title)
              (push (cdr entry) titles)
            (push (cdr entry) urls)))
        (append
         (cl-mapcar #'cons (nreverse titles) (nreverse urls))
         (list vib-link))))))


;; ---------- Default handler registry ----------

(defvar gnus-browse-url-in-article-default-handlers
  (list (make-instance 'gnus-browse-url-in-article-github-pr-handler)
        (make-instance 'gnus-browse-url-in-article-linkedin-jobs-handler)
        (make-instance 'gnus-browse-url-in-article-ars-technica-handler))
  "Built-in handler instances tried before user-supplied handlers.
Covers GitHub PR notifications, LinkedIn job alerts, and Ars Technica
newsletters.")

(defun gnus-browse-url-in-article-make-handler (predicate handler-fn)
  "Create a function-handler from PREDICATE and HANDLER-FN.
PREDICATE is a zero-arg function returning non-nil if the handler applies.
HANDLER-FN is a zero-arg function returning a (display . url) alist or nil.

Example:
  (gnus-browse-url-in-article-make-handler
   (gnus-browse-url-in-article-if-from \"example\\.com\")
   (lambda () ...))"
  (make-instance 'gnus-browse-url-in-article-function-handler
                 :predicate predicate
                 :handler-fn handler-fn))

(defun gnus-browse-url-in-article-add-handler (handler)
  "Prepend HANDLER to `gnus-browse-url-in-article-handlers'.
HANDLER must be a `gnus-browse-url-in-article-handler' instance or subclass.
Use `gnus-browse-url-in-article-make-handler' to create one from functions."
  (cl-check-type handler gnus-browse-url-in-article-handler)
  (push handler gnus-browse-url-in-article-handlers))

;;;###autoload
(defun gnus-browse-url-in-article (_n)
  "Browse the best URL in the current Gnus article.

Dispatch order:
1. Try each handler in `gnus-browse-url-in-article-default-handlers', then
   `gnus-browse-url-in-article-handlers'.  The first handler for which
   `gnus-browse-url-in-article-handler-matches-p' returns non-nil and
   `gnus-browse-url-in-article-handler-get-urls' returns a non-nil alist wins.
2. Fall back to generic extraction: canonical link/meta tag, then full link
   scan.

DWIM: browses directly when exactly one URL is found; uses `completing-read'
when multiple URLs are present."
  (interactive "p" gnus-summary-mode)
  (gnus-summary-select-article)
  (gnus-configure-windows 'article)
  (let* ((all-handlers (append gnus-browse-url-in-article-default-handlers
                               gnus-browse-url-in-article-handlers))
         (html-handle  (gnus-browse-url-in-article--article-html-handle))
         (url-alist
          (or
           ;; Registered handlers (default + user)
           (cl-loop for handler in all-handlers
                    when (gnus-browse-url-in-article-handler-matches-p handler)
                    thereis (gnus-browse-url-in-article-handler-get-urls handler))
           ;; Generic fallback
           (let* ((canonical-url (gnus-browse-url-in-article--article-canonical-url html-handle)))
             (if canonical-url
                 (list (cons canonical-url canonical-url))
               (gnus-browse-url-in-article--article-url-alist-generic html-handle))))))
    (cond
     ((null url-alist)
      (message "No URLs found in article"))
     ((= 1 (length url-alist))
      (browse-url (cdr (car url-alist))))
     (t
      (let* ((candidates (mapcar #'car url-alist))
             (selected   (completing-read "Browse URL: " candidates nil t))
             (url        (cdr (assoc selected url-alist))))
        (browse-url url))))))

(provide 'gnus-browse-url-in-article)

;;; gnus-browse-url-in-article.el ends here
