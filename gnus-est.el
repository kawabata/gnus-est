;;; gnus-est.el --- Search mail with HyperEstraier -*- coding: utf-8; -*-

;; Copyright (C) 2000, 2001, 2002, 2003, 2004
;; TSUCHIYA Masatoshi <tsuchiya@namazu.org>
;;
;; Modified by anonymous and <kawabata.taichi@gmail.com>

;; Author: TSUCHIYA Masatoshi <tsuchiya@namazu.org>
;; Keywords: mail searching hyperestraier

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; if not, see <http://www.gnu.org/licenses/>.


;;; Commentary:

;; This file is a modification of gnus-namazu.el 

;; This file defines the command to search mails and persistent
;; articles with HyperEstraier and to browse its results with Gnus.
;;
;; HyperEstraier is a full-text search engine intended for easy use.  For
;; more detail about Namazu, visit the following page:
;;
;;     http://hyperestraier.org/


;;; Quick Start:

;; If this module has already been installed, only four steps are
;; required to search articles with this module.
;;
;;   (1) Install HyperEstraier.
;;
;;   (2) Put this expression into your ~/.gnus.
;;
;;          (gnus-est-insinuate)
;;
;;   (3) Start Gnus and type M-x gnus-est-create-index RET to make
;;       index of articles.
;;
;;   (4) In group buffer or in summary buffer, type C-c C-n query RET.
;;       (or M-x gnus-est-search for other buffer.)


;;; Install:

;; Before installing this module, you must install HyperEstraier.
;;
;; When you would like to byte-compile this module in Gnus, put this
;; file into the lisp/ directory in the Gnus source tree and run `make
;; install'.  And then, put the following expression into your
;; ~/.gnus.
;;
;;      (gnus-est-insinuate)
;;
;; In order to make index of articles with HyperEstraier before using this
;; module, type M-x gnus-est-create-index RET.  Otherwise, you can
;; create index by yourself with the following commands:
;;
;;      % mkdir ~/News/casket
;;      % estcmd gather -cl -fm -cm ~/News/casket ~/Mail
;;
;; The first command makes the directory for index files, and the
;; second command generates index files of mails and persistent
;; articles.
;;
;; In order to update indices for incoming articles, this module
;; automatically runs estcmd, the indexer of HyperEstraier, at an interval of
;; 3 days; this period is set to `gnus-est-index-update-interval'.
;;
;; Indices will be updated when `gnus-est-search' is called.  If
;; you want to update indices every time when Gnus is started, you can put
;; the following expression to your ~/.gnus.
;;
;;      (add-hook 'gnus-startup-hook 'gnus-est-update-indices)
;;
;; In order to control estcmd closely, disable the automatic updating
;; feature and run `estcmd gather' yourself.  In this case, set nil to the
;; above option.
;;
;;      (setq gnus-est-index-update-interval nil)
;;
;; When your index is put into the directory other than the default
;; one (~/News/casket), it is necessary to set its place to
;; `gnus-est-index-directory' as follows:
;;
;;      (setq gnus-est-index-directory (expand-file-name "~/casket"))

;; メモ
;; 検索は HyperEstraier の通常の検索式で行います。
;; ただし、"+XXX:YYY" の語がある場合は、属性@XXXにYYYの文字列を含むメールを検索し、
;; "+XXX>YYY" の語がある場合は、属性@XXXXがYYYより大きいメールを検索します。
;; 例：
;; "インターネット AND セキュリティ"
;; "[RX] ^inter.*al$" 
;;   → 指定した正規表現の英単語を含む。
;; "+cdate>2011/01/01 +title:重要 +author:hogehoge.com インターネット"
;;   → 日付が2011/01/01以降で、タイトルに"重要" が入り、 
;;      From: に "hogehoge.com" が入った、"インターネット" を含む文書。

;;; Code:

(eval-when-compile (require 'cl))
(require 'nnoo)
(require 'nnheader)
(require 'nnmail)
(require 'gnus-sum)

;; To suppress byte-compile warning.
(eval-when-compile
  (defvar nnml-directory)
  (defvar nnmh-directory))


(defgroup gnus-est nil
  "Search nnmh and nnml groups in Gnus with HyperEstraier."
  :group 'gnus
  :prefix "gnus-est-")

(defconst gnus-est-index-directory
  (expand-file-name "casket" gnus-directory)
  "Place of HyperEstraier index files.")

(defcustom gnus-est-command
  "estcmd"
  "*Name of the executable file of HyperEstraier."
  :type 'string
  :group 'gnus-est)

(defcustom gnus-est-command-prefix nil
  "*Prefix commands to execute HyperEstraier.
If you put your index on a remote server, set this option as follows:

    (setq gnus-est-command-prefix
          '(\"ssh\" \"-x\" \"remote-server\"))

This makes gnus-est execute \"ssh -x remote-server estcmd ...\"
instead of executing \"estcmd\" directly."
  :type '(repeat string)
  :group 'gnus-est)

(defcustom gnus-est-additional-arguments nil
  "*Additional arguments of HyperEstraier.
The options `-vu', `-max', and `-1' are always used, very few other
options make any sense in this context."
  :type '(repeat string)
  :group 'gnus-est)

(defcustom gnus-est-index-update-interval
  259200				; 3 days == 259200 seconds.
  "*Number of seconds between running the indexer of HyperEstraier."
  :type '(choice (const :tag "Never run the indexer" nil)
		 (integer :tag "Number of seconds"))
  :group 'gnus-est)

(defcustom gnus-est-make-index-command "estcmd"
  "*Name of the executable file of the indexer of HyperEstraier."
  :type 'string
  :group 'gnus-est)

(defcustom gnus-est-make-index-arguments
  (list "gather" "-cl" "-fm" "-cm" )
  "*Arguments of the indexer of HyperEstraier."
  :type '(repeat string)
  :group 'gnus-est)

(defcustom gnus-est-field-keywords
  '("cdate:" "cdate>" "cdate<" "author:" "size>" "size<" "title:" "uri:")
  "*List of keywords to do field-search."
  :type '(repeat string)
  :group 'gnus-est)

(defvar gnus-est-field-keywords-regexp
  (regexp-opt gnus-est-field-keywords t))

(defcustom gnus-est-coding-system
  'utf-8
  "*Coding system for HyperEstraier process."
  :type 'coding-system
  :group 'gnus-est)

(defcustom gnus-est-need-path-normalization
  (and (memq system-type '(windows-nt OS/2 emx)) t)
  "*Non-nil means that outputs of HyperEstraier may contain drive letters."
  :type 'boolean
  :group 'gnus-est)

(defcustom gnus-est-case-sensitive-filesystem
  (not (eq system-type 'windows-nt))
  "*Non-nil means that the using file system distinguishes cases of characters."
  :type 'boolean
  :group 'gnus-est)

(defcustom gnus-est-query-highlight t
  "Non-nil means that queried words is highlighted."
  :type 'boolean
  :group 'gnus-est)

(defface gnus-est-query-highlight-face
  '((((type tty pc) (class color))
     (:background "magenta4" :foreground "cyan1"))
    (((class color) (background light))
     (:background "magenta4" :foreground "lightskyblue1"))
    (((class color) (background dark))
     (:background "palevioletred2" :foreground "brown4"))
    (t (:inverse-video t)))
  "Face used for HyperEstraier query matching words."
  :group 'gnus-est)

(defcustom gnus-est-remote-groups nil
  "*Alist of regular expressions matching remote groups and their base paths.
If you use an IMAP server and have a special index, set this option as
follows:

    (setq gnus-est-remote-groups
          '((\"^nnimap\\\\+server:INBOX\\\\.\" . \"~/Maildir/.\")))

This means that the group \"nnimap+server:INBOX.group\" is placed in
\"~/Maildir/.group\"."
  :group 'gnus-est
  :type '(repeat
	  (cons (regexp :tag "Regexp of group name")
		(string :tag "Base path of groups")))
  :set (lambda (symbol value)
	 (prog1 (set-default symbol value)
	   (when (featurep 'gnus-est)
	     (gnus-est/make-directory-table t)))))

;;; Internal Variable:
(defconst gnus-est/group-name-regexp "\\`nnvirtual:est-search\\?")

;; Multibyte group name:
(and
 (fboundp 'gnus-group-decoded-name)
 (let ((gnus-group-name-charset-group-alist
	(list (cons gnus-est/group-name-regexp gnus-est-coding-system)))
       (query (decode-coding-string (string 27 36 66 52 65 59 122 27 40 66)
				    'iso-2022-7bit)))
   (not (string-match query
		      (gnus-summary-buffer-name
		       (encode-coding-string
			(concat "nnvirtual:est-search?query=" query)
			gnus-est-coding-system)))))
 (let (current-load-list)
   (defadvice gnus-summary-buffer-name
     (before gnus-est-summary-buffer-name activate compile)
     "Advised by `gnus-est' to handle encoded group names."
     (ad-set-arg 0 (gnus-group-decoded-name (ad-get-arg 0))))))

(defmacro gnus-est/make-article (group number)
  `(cons ,group ,number))
(defmacro gnus-est/article-group  (x) `(car ,x))
(defmacro gnus-est/article-number (x) `(cdr ,x))


;;
(defsubst gnus-est/indexed-servers ()
  "Choice appropriate servers from opened ones, and return thier list."
  (append
   (gnus-servers-using-backend 'nnml)
   (gnus-servers-using-backend 'nnmh)))

(defun gnus-est/setup ()
  (and (boundp 'gnus-group-name-charset-group-alist)
       (not (member (cons gnus-est/group-name-regexp
			  gnus-est-coding-system)
		    gnus-group-name-charset-group-alist))
       (let ((pair (assoc gnus-est/group-name-regexp
			  gnus-group-name-charset-group-alist)))
	 (if pair
	     (setcdr pair gnus-est-coding-system)
	   (push (cons gnus-est/group-name-regexp
		       gnus-est-coding-system)
		 gnus-group-name-charset-group-alist))))
  (unless gnus-est-command-prefix
    (gnus-est-update-indices)))

(defun gnus-est/server-directory (server)
  "Return the top directory of the server SERVER."
  (and (memq (car server) '(nnml nnmh))
       (nnoo-change-server (car server) (nth 1 server) (nthcdr 2 server))
       (file-name-as-directory
	(expand-file-name (if (eq 'nnml (car server))
			      nnml-directory
			    nnmh-directory)))))

;;; Functions to call HyperEstraier.
(defsubst gnus-est/normalize-results ()
  "Normalize file names returned by HyperEstraier in this current buffer."
  (goto-char (point-min))
  (search-forward "file://" nil t)
  (beginning-of-line)
  (delete-region (point-min) (point))
  (while (not (eobp))
    (when (re-search-forward "^.*file://\\(.*\\)$" nil t)
      (replace-match "\\1"))
    (when (if gnus-est-need-path-normalization
	      (or (not (looking-at "/\\(.\\)|/"))
		  (replace-match "\\1:/"))
	    (eq ?~ (char-after (point))))
      (goto-char (point-at-bol))
      (insert (expand-file-name
	       (buffer-substring (point-at-bol) (point-at-eol))))
      (delete-region (point) (point-at-eol)))
    (forward-line 1)))

(defun gnus-est/query-to-attr-args (query)
  "query のフィールド指定を HyperEstraier の attr指定に置き換え、
queryを先端に入れたリストを返す。
例：+title:hoge +date>2011/01/01 moge
→ '(\"moge\" \"-attr\" \"@title STRINC hoge\" \"-attr\" \"@CDATE NUMLE 2011/01/01\")"
  (let (attr-args)
    (with-temp-buffer 
      (insert query)
      (goto-char (point-min))
      (while (re-search-forward 
              (concat "\\+" gnus-est-field-keywords-regexp "\\([^ ]+\\) ") 
	      nil t)
        (let ((attr (substring (match-string-no-properties 1) 0 -1))
              (oper (substring (match-string-no-properties 1) -1))
              (subj (match-string-no-properties 2)))
	  (message "debug %s" oper)
          (setq attr-args
                (nconc (list "-attr"
                             (concat
                              "@" attr
                              (cond ((and (equal oper ":") (equal attr "cdate"))
				     " NUMEQ ")
				    ((equal oper ":") " STRINC ")
				    ((equal oper "<") " NUMLE ")
				    (t " NUMGE "))
                              subj))
                       attr-args))))
      (cons (buffer-substring-no-properties (point) (point-max))
            attr-args))))

(defsubst gnus-est/call-est (query)
  (let* ((coding-system-for-read gnus-est-coding-system)
	 (coding-system-for-write gnus-est-coding-system)
	 (default-process-coding-system
	   (cons gnus-est-coding-system gnus-est-coding-system))
	 program-coding-system-alist
	 (file-name-coding-system gnus-est-coding-system)
	 (attr-args (gnus-est/query-to-attr-args query))
	 (commands
	  (append gnus-est-command-prefix
		  (list gnus-est-command
			"search"
			"-vu"
			"-max"
			"-1")
		  (cdr attr-args)
		  gnus-est-additional-arguments
		  (list gnus-est-index-directory)
		  (list (car attr-args)))))
    (message "debug: estcmd = %s" commands)
    (apply 'call-process (car commands) nil t nil (cdr commands))))


(defvar gnus-est/directory-table nil)
(defun gnus-est/make-directory-table (&optional force)
  (interactive (list t))
  (unless (and (not force)
	       gnus-est/directory-table
	       (eq gnus-est-case-sensitive-filesystem
		   (car gnus-est/directory-table)))
    (let ((table (make-vector (length gnus-newsrc-hashtb) 0))
	  cache agent alist dir method)
      (mapatoms
       (lambda (group)
	 (unless (gnus-ephemeral-group-p (setq group (symbol-name group)))
	   (when (file-directory-p
		  (setq dir (file-name-as-directory
			     (gnus-cache-file-name group ""))))
	     (push (cons dir group) cache))
	   (when (file-directory-p
		  (setq dir (gnus-agent-group-pathname group)))
	     (push (cons dir group) agent))
	   (when (memq (car (setq method (gnus-find-method-for-group group)))
		       '(nnml nnmh))
	     (when (file-directory-p
		    (setq dir (nnmail-group-pathname
			       (gnus-group-short-name group)
			       (gnus-est/server-directory method))))
	       (push (cons dir group) alist)))
	   (dolist (pair gnus-est-remote-groups)
	     (when (string-match (car pair) group)
	       (setq dir (nnmail-group-pathname
			  (substring group (match-end 0))
			  "/"))
	       (push (cons (concat (cdr pair)
				   ;; nnmail-group-pathname() on some
				   ;; systems returns pathnames which
				   ;; have drive letters at their top.
				   (substring dir (1+ (string-match "/" dir))))
			   group)
		     alist)))))
       gnus-newsrc-hashtb)
      (dolist (pair (nconc agent cache alist))
	(set (intern (if gnus-est-case-sensitive-filesystem
			 (car pair)
		       (downcase (car pair)))
		     table)
	     (cdr pair)))
      (setq gnus-est/directory-table
	    (cons gnus-est-case-sensitive-filesystem table)))))

(defun gnus-est/search (groups query)
  (gnus-est/make-directory-table)
  (with-temp-buffer
    (message "debug/query=%s" query) ;; debug
    (let ((exit-status (gnus-est/call-est query)))
      (unless (zerop exit-status)
        (message "Error contents = %s" (buffer-string))
	(error "HyperEstraier finished abnormally: %d" exit-status)))
    (gnus-est/normalize-results)
    (message "debug=%s" (buffer-string)) ;; debug
    (goto-char (point-min))
    (let (articles group)
      (while (not (eobp))
	(setq group (buffer-substring-no-properties
		     (point)
		     (progn
		       (end-of-line)
		       ;; NOTE: Only numeric characters are permitted
		       ;; as file names of articles.
		       (skip-chars-backward "0-9")
		       (point))))
	(and (setq group
		   (symbol-value
		    (intern-soft (if gnus-est-case-sensitive-filesystem
				     group
				   (downcase group))
				 (cdr gnus-est/directory-table))))
	     (or (not groups)
		 (member group groups))
	     (push (gnus-est/make-article
		    group
		    (string-to-number
		     (buffer-substring-no-properties (point)
						     (point-at-eol))))
		   articles))
	(forward-line 1))
      (nreverse articles))))

;;; User Interface:
(defun gnus-est/get-target-groups ()
  (cond
   ((eq major-mode 'gnus-group-mode)
    ;; In Group buffer.
    (cond
     (current-prefix-arg
      (gnus-group-process-prefix current-prefix-arg))
     (gnus-group-marked
      (prog1 gnus-group-marked (gnus-group-unmark-all-groups)))))
   ((eq major-mode 'gnus-summary-mode)
    ;; In Summary buffer.
    (if current-prefix-arg
	(list (gnus-read-group "Group: "))
      (if (and
	   (gnus-ephemeral-group-p gnus-newsgroup-name)
	   (string-match gnus-est/group-name-regexp gnus-newsgroup-name))
	  (cadr (assq 'gnus-est-target-groups
		      (gnus-info-method (gnus-get-info gnus-newsgroup-name))))
	(list gnus-newsgroup-name))))))

(defun gnus-est/get-current-query ()
  (and (eq major-mode 'gnus-summary-mode)
       (gnus-ephemeral-group-p gnus-newsgroup-name)
       (string-match gnus-est/group-name-regexp gnus-newsgroup-name)
       (cadr (assq 'gnus-est-current-query
		   (gnus-info-method (gnus-get-info gnus-newsgroup-name))))))

(defvar gnus-est/read-query-original-buffer nil)
(defvar gnus-est/read-query-prompt nil)
(defvar gnus-est/read-query-history nil)

(defun gnus-est/get-current-subject ()
  (and gnus-est/read-query-original-buffer
       (bufferp gnus-est/read-query-original-buffer)
       (with-current-buffer gnus-est/read-query-original-buffer
	 (when (eq major-mode 'gnus-summary-mode)
	   (let ((s (gnus-summary-article-subject)))
	     ;; Remove typically prefixes of mailing lists.
	     (when (string-match
		    "^\\(\\[[^]]*[0-9]+\\]\\|([^)]*[0-9]+)\\)\\s-*" s)
	       (setq s (substring s (match-end 0))))
	     (when (string-match
		    "^\\(Re\\(\\^?\\([0-9]+\\|\\[[0-9]+\\]\\)\\)?:\\s-*\\)+" s)
	       (setq s (substring s (match-end 0))))
	     (when (string-match "\\s-*(\\(re\\|was\\)\\b" s)
	       (setq s (substring s 0 (match-beginning 0))))
	     s)))))

(defun gnus-est/get-current-from ()
  (and gnus-est/read-query-original-buffer
       (bufferp gnus-est/read-query-original-buffer)
       (with-current-buffer gnus-est/read-query-original-buffer
	 (when (eq major-mode 'gnus-summary-mode)
	   (cadr (mail-extract-address-components
		  (mail-header-from
		   (gnus-summary-article-header))))))))

(defun gnus-est/get-current-to ()
  (and gnus-est/read-query-original-buffer
       (bufferp gnus-est/read-query-original-buffer)
       (with-current-buffer gnus-est/read-query-original-buffer
	 (when (eq major-mode 'gnus-summary-mode)
	   (cadr (mail-extract-address-components
		  (cdr (assq 'To (mail-header-extra
				  (gnus-summary-article-header))))))))))

(defmacro gnus-est/minibuffer-prompt-end ()
  (if (fboundp 'minibuffer-prompt-end)
      '(minibuffer-prompt-end)
    '(point-min)))

(defun gnus-est/message (string &rest arguments)
  (let* ((s1 (concat
	      gnus-est/read-query-prompt
	      (buffer-substring (gnus-est/minibuffer-prompt-end)
				(point-max))))
	 (s2 (apply (function format) string arguments))
	 (w (- (window-width)
	       (string-width s1)
	       (string-width s2)
	       1)))
    (message (if (>= w 0)
		 (concat s1 (make-string w ?\ ) s2)
	       s2))
    (if (sit-for 0.3) (message s1))
    s2))

(defun gnus-est/complete-query ()
  (interactive)
  (let ((pos (point)))
    (cond
     ((and (re-search-backward "\\+\\([-a-z]*\\)" nil t)
	   (= pos (match-end 0)))
      (let* ((partial (match-string 1))
	     (completions
	      (all-completions
	       partial
	       gnus-est-field-keywords))) ;; remove (mapcar 'list)
	(cond
	 ((null completions)
	  (gnus-est/message "No completions of %s" partial))
	 ((= 1 (length completions))
	  (goto-char (match-beginning 1))
	  (delete-region (match-beginning 1) (match-end 1))
	  (insert (car completions) ":")
	  (setq pos (point))
	  (gnus-est/message "Completed"))
	 (t
	  (let ((x (try-completion partial (mapcar 'list completions))))
	    (if (string= x partial)
		(if (and (eq last-command
			     'gnus-est/complete-query)
			 completion-auto-help)
		    (with-output-to-temp-buffer "*Completions*"
		      (display-completion-list completions))
		  (gnus-est/message "Sole completion"))
	      (goto-char (match-beginning 1))
	      (delete-region (match-beginning 1) (match-end 1))
	      (insert x)
	      (setq pos (point))))))))
     ((and (looking-at "\\+title:")
	   (= pos (match-end 0)))
      (let ((s (gnus-est/get-current-subject)))
	(when s
	  (goto-char pos)
	  (insert "\"" s "\"")
	  (setq pos (point)))))
     ((and (looking-at "\\+cdate[:<>]")
	   (= pos (match-end 0)))
      (let ((f (gnus-est/get-current-from)))
	(when f
	  (goto-char pos)
	  (insert "\"" f "\"")
	  (setq pos (point))))))
    (goto-char pos)))

(defvar gnus-est/read-query-map
  (let ((keymap (copy-keymap minibuffer-local-map)))
    (define-key keymap "\t" 'gnus-est/complete-query)
    keymap))

(defun gnus-est/read-query (prompt &optional initial)
  (let ((gnus-est/read-query-original-buffer (current-buffer))
	(gnus-est/read-query-prompt prompt))
    (unless initial
      (when (setq initial (gnus-est/get-current-query))
	(setq initial (cons initial 0))))
    (read-from-minibuffer prompt initial gnus-est/read-query-map nil
			  'gnus-est/read-query-history)))

(defun gnus-est/highlight-words (query)
  (with-temp-buffer
    (insert " " query)
    ;; Remove tokens for NOT search
    (goto-char (point-min))
    (while (re-search-forward "[　 \t\r\f\n]+not[　 \t\r\f\n]+\
\\([^　 \t\r\f\n\"{(/]+\\|\"[^\"]+\"\\|{[^}]+}\\|([^)]+)\\|/[^/]+/\\)+" nil t)
      (delete-region (match-beginning 0) (match-end 0)))
    ;; Remove tokens for Field search
    (goto-char (point-min))
    (while (re-search-forward "[　 \t\r\f\n]+\\+[^　 \t\r\f\n:]+:\
\\([^　 \t\r\f\n\"{(/]+\\|\"[^\"]+\"\\|{[^}]+}\\|([^)]+)\\|/[^/]+/\\)+" nil t)
      (delete-region (match-beginning 0) (match-end 0)))
    ;; Remove tokens for Regexp search
    (goto-char (point-min))
    (while (re-search-forward "/[^/]+/" nil t)
      (delete-region (match-beginning 0) (match-end 0)))
    ;; Remove brackets, double quote, asterisk and operators
    (goto-char (point-min))
    (while (re-search-forward "\\([(){}\"*]\\|\\b\\(and\\|or\\)\\b\\)" nil t)
      (delete-region (match-beginning 0) (match-end 0)))
    ;; Collect all keywords
    (setq query nil)
    (goto-char (point-min))
    (while (re-search-forward "[^　 \t\r\f\n]+" nil t)
      (push (match-string 0) query))
    (when query
      (let (en ja)
	(dolist (q query)
	  (if (string-match "\\cj" q)
	      (push q ja)
	    (push q en)))
	(append
	 (when en
	   (list (list (concat "\\b\\(" (regexp-opt en) "\\)\\b")
		       0 0 'gnus-est-query-highlight-face)))
	 (when ja
	   (list (list (regexp-opt ja)
		       0 0 'gnus-est-query-highlight-face))))))))

(defun gnus-est/truncate-article-list (articles)
  (let ((hit (length articles)))
    (when (and gnus-large-newsgroup
	       (> hit gnus-large-newsgroup))
      (let* ((cursor-in-echo-area nil)
	     (input (read-from-minibuffer
		     (format "\
Too many articles were retrieved.  How many articles (max %d): "
			     hit)
		     (cons (number-to-string gnus-large-newsgroup) 0))))
	(unless (string-match "\\`[ \t]*\\'" input)
	  (setcdr (nthcdr (min (1- (string-to-number input)) hit) articles)
		  nil)))))
  articles)

;;;###autoload
(defun gnus-est-search (groups query)
  "Search QUERY through GROUPS with HyperEstraier,
and make a virtual group contains its results."
  (interactive
   (list
    (gnus-est/get-target-groups)
    (gnus-est/read-query "Enter query: ")))
  (gnus-est/setup)
  (let ((articles (gnus-est/search groups query)))
    (if articles
	(let ((real-groups groups)
	      (vgroup
	       (apply (function format)
		      "nnvirtual:est-search?query=%s&groups=%s&id=%d%d%d"
		      query
		      (if groups (mapconcat 'identity groups ",") "ALL")
		      (current-time))))
	  (gnus-est/truncate-article-list articles)
	  (unless real-groups
	    (dolist (a articles)
	      (add-to-list 'real-groups (gnus-est/article-group a))))
	  ;; Generate virtual group which includes all results.
	  (when (fboundp 'gnus-group-decoded-name)
	    (setq vgroup
		  (encode-coding-string vgroup gnus-est-coding-system)))
	  (setq vgroup
		(gnus-group-read-ephemeral-group
		 vgroup
		 `(nnvirtual ,vgroup
			     (nnvirtual-component-groups ,real-groups)
			     (gnus-est-target-groups ,groups)
			     (gnus-est-current-query ,query))
		 t (cons (current-buffer) (current-window-configuration)) t))
	  (when gnus-est-query-highlight
	    (gnus-group-set-parameter vgroup 'highlight-words
				      (gnus-est/highlight-words query)))
	  ;; Generate new summary buffer which contains search results.
	  (gnus-group-read-group
	   t t vgroup
	   (sort (delq nil ;; Ad-hoc fix, to avoid wrong-type-argument error.
		       (mapcar
			(lambda (a)
			  (nnvirtual-reverse-map-article
			   (gnus-est/article-group a)
			   (gnus-est/article-number a)))
			articles))
		 '<)))
      (message "No entry."))))

;; indexファイルがなく、ディレクトリのみなので、_metaで代用しておく。
(defmacro gnus-est/meta-file-name ()
  `(expand-file-name "_meta" ,gnus-est-index-directory))

(defun gnus-est/gather-cleanup ()
  nil)
;;  (let ((lockfile (gnus-est/lock-file-name)))
;;    (when (file-exists-p lockfile)
;;      ;; 以下は実行されない。
;;      (delete-file lockfile)
;;      (dolist (tmpfile (directory-files directory t "\\`NMZ\\..*\\.tmp\\'" t))
;;	(delete-file tmpfile)))))

;;;###autoload
(defun gnus-est-create-index (&optional directory target-directories force)
  "Create index under DIRECTORY."
  (interactive)
  (unless directory (setq directory gnus-est-index-directory))
  (unless target-directories
    (setq target-directories
	  (delq nil
		(mapcar (lambda (dir)
			  (when (file-directory-p dir) dir))
			(append
			 (mapcar 'gnus-est/server-directory
				 (gnus-est/indexed-servers))
			 (list
			  (expand-file-name gnus-cache-directory)
			  (expand-file-name gnus-agent-directory)))))))
  (if nil ; (file-exists-p (gnus-est/lock-file-name))
      (when force
	(error "Found lock file: %s" (gnus-est/lock-file-name)))
    (with-current-buffer (get-buffer-create " *estcmd gather*")
      (erase-buffer)
      (unless (file-directory-p directory)
	(make-directory directory t))
      (setq default-directory directory)
      (dolist (target-directory target-directories)
        (let ((args (append gnus-est-make-index-arguments
                            (list directory)
                            (list target-directory))))
          (insert "% " gnus-est-make-index-command " "
                  (mapconcat 'identity args " ") "\n")
          (goto-char (point-max))
          (when force
            (pop-to-buffer (current-buffer)))
          (message "Make index at %s..." directory)
          (unwind-protect
              (message "%s" (cons gnus-est-make-index-command args))
	    (apply 'call-process gnus-est-make-index-command nil t t args)
            (gnus-est/gather-cleanup))
          (message "Make index at %s...done" directory)))
      (unless force
        (kill-buffer (current-buffer))))
    (gnus-est/make-directory-table t)))

(defun gnus-est/lapse-seconds (start end)
  "Return lapse seconds from START to END.
START and END are lists which represent time in Emacs-style."
  (+ (* (- (car end) (car start)) 65536)
     (cadr end)
     (- (cadr start))))

(defun gnus-est/index-old-p ()
  "Return non-nil value when the index is older than the period
that is set to `gnus-est-index-update-interval'"
  (let ((file (gnus-est/meta-file-name)))
    (or (not (file-exists-p file))
	(and (integerp gnus-est-index-update-interval)
	     (>= (gnus-est/lapse-seconds
		  (nth 5 (file-attributes file))
		  (current-time))
		 gnus-est-index-update-interval)))))

(defvar gnus-est/update-directory nil)
(defvar gnus-est/update-process nil)

(defun gnus-est/update-p (&optional force)
  "Check if `gnus-est-index-directory' should be updated."
  (labels ((error-message (format &rest args)
			  (apply (if force 'error 'message) format args)
			  nil))
    (if gnus-est/update-process
	(error-message "%s" "Can not run two update processes simultaneously")
      (or force
	  (gnus-est/index-old-p)))))

;;;###autoload
(defun gnus-est-update-indices (&optional directories force)
  "Update the index."
  (interactive)
  (when (gnus-est/update-p force)
    (with-current-buffer (get-buffer-create " *estcmd gather*")
      (buffer-disable-undo)
      (erase-buffer)
      (unless (file-directory-p gnus-est-index-directory)
	(make-directory gnus-est-index-directory t))
      (setq default-directory gnus-est-index-directory)
      (let ((proc (apply 'start-process
                         gnus-est-make-index-command
                         (current-buffer)
                         gnus-est-make-index-command
                         (append
                          gnus-est-make-index-arguments
                          (list gnus-est-index-directory)
                          target-directories))))
	(if (processp proc)
	    (prog1 (setq gnus-est/update-process proc)
	      (process-kill-without-query proc)
	      (set-process-sentinel proc 'gnus-est/update-sentinel)
	      (add-hook 'kill-emacs-hook 'gnus-est-stop-update)
	      (message "Update index at %s..." gnus-est-index-directory))
	  (goto-char (point-min))
	  (if (re-search-forward "^ERROR:.*$" nil t)
	      (progn
		(pop-to-buffer (current-buffer))
		(funcall (if force 'error 'message)
			 "Update index at %s...%s" directory (match-string 0)))
	    (kill-buffer (current-buffer))
	    (funcall (if force 'error 'message)
		     "Can not start %s" gnus-est-make-index-command))
	  nil)))))

(defun gnus-est/update-sentinel (process event)
  (let ((buffer (process-buffer process)))
    (when (buffer-name buffer)
      (with-current-buffer buffer
	(gnus-est/gather-cleanup)
	(goto-char (point-min))
	(cond
	 ((re-search-forward "^ERROR:.*$" nil t)
	  (pop-to-buffer (current-buffer))
	  (message "Update index at %s...%s"
		   default-directory (match-string 0))
	  (setq gnus-est/update-directory nil))
	 ((and (eq 'exit (process-status process))
	       (zerop (process-exit-status process)))
	  (message "Update index at %s...done" default-directory)
	  (unless (or debug-on-error debug-on-quit)
	    (kill-buffer buffer)))))))
  (setq gnus-est/update-process nil)
  (unless (gnus-est-update-indices gnus-est/update-directory)
    (gnus-est/make-directory-table t)))

;;;###autoload
(defun gnus-est-stop-update ()
  "Stop the running indexer of HyperEstraier."
  (interactive)
  (setq gnus-est/update-directories nil)
  (and gnus-est/update-process
       (processp gnus-est/update-process)
       (kill-process gnus-est/update-process)))

(let (current-load-list)
  (defadvice gnus-offer-save-summaries
    (before gnus-est-kill-summary-buffers activate compile)
    "Advised by `gnus-est'.
In order to avoid annoying questions, kill summary buffers which
generated by `gnus-est' itself before `gnus-offer-save-summaries'
is called."
    (let ((buffers (buffer-list)))
      (while buffers
	(when (with-current-buffer (car buffers)
		(and (eq major-mode 'gnus-summary-mode)
		     (gnus-ephemeral-group-p gnus-newsgroup-name)
		     (string-match gnus-est/group-name-regexp
				   gnus-newsgroup-name)))
	  (kill-buffer (car buffers)))
	(setq buffers (cdr buffers))))))

;;;###autoload
(defun gnus-est-insinuate ()
  (add-hook
   'gnus-group-mode-hook
   (lambda ()
     (define-key gnus-group-mode-map "\C-c\C-n" 'gnus-est-search)))
  (add-hook
   'gnus-summary-mode-hook
   (lambda ()
     (define-key gnus-summary-mode-map "\C-c\C-n" 'gnus-est-search))))

(provide 'gnus-est)

;;; arch-tag: a6814a35-593a-4563-8157-a2b762c29ed8
;; gnus-est.el ends here.
