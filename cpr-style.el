;; cpr-style.el --- CSL style structure and related functions -*- lexical-binding: t; -*-

;; Copyright (C) 2017 András Simonyi

;; Author: András Simonyi <andras.simonyi@gmail.com>

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Structure type and functions for constructing and accessing CSL style
;; objects.

;;; Code:

(require 'subr-x)
(require 'let-alist)
(require 'dash)
(require 'cl-lib)

(require 'cpr-lib)
(require 'cpr-locale)

(cl-defstruct (cpr-style (:constructor cpr-style--create))
  "A struct representing a parsed and localized CSL style.
INFO is the style's general info (currently simply the
  corresponding fragment of the parsed xml),
OPTS, BIB-OPTS, CITE-OPTS and LOCALE-OPTS are alists of general
  and bibliography-, cite- and locale-specific CSL options,
BIB-SORT, BIB-LAYOUT, CITE-SORT and CITE-LAYOUT are anonymous
  functions for calculating sort-keys and rendering,
BIB-SORT-ORDERS and CITE-SORT-ORDERS are the lists of sort orders
  for bibliography and cite sort (the value is a list containg t
  or nil as its n-th element depending on whether the sort for on
  the n-th key should be in ascending or desending order,
CITE-LAYOUT-ATTRS contains the attributes of the citation layout
  as an alist,
CITE-NOTE is non-nil iff the style's citation-format is \"note\",
DATE-TEXT and DATE-NUMERIC are the style's date formats,
MACROS is an alist with macro names as keys and corresponding
  anonymous rendering functions,
TERMS is the style's parsed term-list,
USES-YS-VAR is non-nil iff the style uses the YEAR-SUFFIX
  CSL-variable."
  info opts bib-opts bib-sort bib-sort-orders
  bib-layout cite-opts cite-note cite-sort cite-sort-orders
  cite-layout cite-layout-attrs locale-opts macros terms
  uses-ys-var date-text date-numeric)

(defun cpr-style-parse (style)
  "Return the parsed representation of csl STYLE.
STYLE is either a path to a style file or a style as a string.
Returns a (YEAR-SUFF-P . PARSED-STYLE) cons cell. YEAR-SUFF-P is
non-nil if the style uses the `year-suffix' csl var; PARSED-STYLE
is the parsed form of the xml STYLE-FILE."
  (let ((xml-input (s-matches-p " ?<" style)))
    (with-temp-buffer
      (let ((case-fold-search t))
	(if xml-input (insert style)
	  (insert-file-contents style))
	(goto-char 1)
	(cons (re-search-forward "variable=\"year-suffix\"" nil t)
	      (cpr-lib-remove-xml-comments
	       (libxml-parse-xml-region (point-min) (point-max) nil t)))))))

;; TODO: Parse and store info in a more structured and sensible form. Also,
;; currently the first in-style locale is loaded that is compatible with the
;; locale to be used. In theory, there may be more than one compatible in-style
;; locales that should be merged in an order reflecting their closeness to the
;; requested locale.
(defun citeproc-create-style-from-locale (parsed-style year-suffix locale)
  "Create a citation style from parsed xml style PARSED-STYLE.
YEAR-SUFFIX specifies whether the style explicitly uses the
`year-suffix' csl variable. LOCALE is the locale for which
in-style locale information will be loaded (if available)."
  (let* ((style (cpr-style--create))
	 (style-opts (cadr parsed-style))
	 locale-loaded)
    (setf (cpr-style-opts style) style-opts
	  (cpr-style-uses-ys-var style) year-suffix)
    (--each (cddr parsed-style)
      (pcase (car it)
	('info
	 (let ((info-lst (cddr it)))
	   (setf (cpr-style-info style) info-lst
		 (cpr-style-cite-note style)
		 (not (not (member '(category
				     ((citation-format . "note")))
				   info-lst))))))
	('locale
	 (let ((lang (alist-get 'lang (cadr it))))
	   (when (and (cpr-locale--compatible-p lang locale)
		      (not locale-loaded))
	     (cpr-style--update-locale style it)
	     (setq locale-loaded t))))
	('citation
	 (cpr-style--update-cite-info style it))
	('bibliography
	 (cpr-style--update-bib-info style it))
	('macro
	 (cpr-style--update-macros style it))))
    style))

(defun cpr-style--parse-layout-and-sort-frag (frag)
  "Parse a citation or bibliography style xml FRAG.
Return an alist with keys 'layout, 'opts, 'layout-attrs, 'sort
and 'sort-orders."
  (let* ((opts (cadr frag))
	 (sort-p (eq (cl-caaddr frag) 'sort))
	 (layout (cpr-style--transform-xmltree
		  (elt frag (if sort-p 3 2))))
	 (layout-attrs (cl-cadadr (cl-caddr layout)))
	 sort sort-orders)
    (when sort-p
      (let* ((sort-frag (cl-caddr frag)))
	(setq sort (cpr-style--transform-xmltree sort-frag)
	      sort-orders (--map (not (string= "descending" (alist-get 'sort (cadr it))))
				 (cddr sort-frag)))))
    `((opts . ,opts) (layout . ,layout) (layout-attrs . ,layout-attrs)
      (sort . ,sort) (sort-orders . ,sort-orders))))

(defun cpr-style--update-cite-info (style frag)
  "Update the cite info of STYLE on the basis of its parsed FRAG."
  (let-alist (cpr-style--parse-layout-and-sort-frag frag)
    (setf (cpr-style-cite-opts style) .opts
	  (cpr-style-cite-layout style) .layout
	  (cpr-style-cite-layout-attrs style) .layout-attrs
	  (cpr-style-cite-sort style) .sort
	  (cpr-style-cite-sort-orders style) .sort-orders)))

(defun cpr-style--update-bib-info (style frag)
  "Update the bib info of STYLE on the basis of its parsed FRAG."
  (let-alist (cpr-style--parse-layout-and-sort-frag frag)
    (setf (cpr-style-bib-opts style) .opts
	  (cpr-style-bib-layout style) .layout
	  (cpr-style-bib-sort style) .sort
	  (cpr-style-bib-sort-orders style) .sort-orders)))

(defun cpr-style--update-macros (style frag)
  "Update the macro info of STYLE on the basis of its parsed FRAG."
  (let ((name (cl-cdaadr frag)))
    (setf (car frag) 'macro)
    (setf (cadr frag) nil)
    (push (cons name (cpr-style--transform-xmltree frag))
	  (cpr-style-macros style))))

(defun cpr-style--update-locale (style frag)
  "Update locale info in STYLE using xml fragment FRAG.
FRAG should be a parsed locale element from a style or a locale."
  (--each (cddr frag)
    (pcase (car it)
      ('style-options (setf (cpr-style-locale-opts style)
			    (-concat (cpr-style-locale-opts style)
				     (cadr it))))
      ('date
       (cpr-style--update-locale-date style it))
      ('terms
       (let ((parsed-terms (cpr-locale-termlist-from-xml-frag (cddr it))))
	 (setf (cpr-style-terms style)
	       (if (cpr-style-terms style)
		   (cpr-term-list-update parsed-terms (cpr-style-terms style))
		 parsed-terms)))))))

(defun cpr-style--update-locale-date (style frag)
  "Update date info in STYLE using xml fragment FRAG.
FRAG should be a parsed locale element from a style or a locale."
  (let* ((date-attrs (cadr frag))
	 (form (alist-get 'form date-attrs))
	 (date-format (cons date-attrs
			    (cpr-lib-named-parts-to-alist frag))))
    (if (string= form "text")
	(unless (cpr-style-date-text style)
	  (setf (cpr-style-date-text style) date-format))
      (unless (cpr-style-date-numeric style)
	(setf (cpr-style-date-numeric style) date-format)))))

(defconst cpr-style--opt-defaults
  '((cite-opts near-note-distance "5")
    (locale-opts punctuation-in-quote "false")
    (locale-opts limit-day-ordinals-to-day-1 "false")
    (bib-opts hanging-indent "false")
    (bib-opts line-spacing "1")
    (bib-opts entry-spacing "1")
    (opts initialize-with-hyphen "true")
    (opts demote-non-dropping-particle "display-and-sort"))
  "Global style options.
Specified as a list of (STYLE-SLOT OPTION-NAME OPTION-DEFAULT)
lists.

Note: Collapse-related options are not specified here since their
default settings are interdependent.")

(defun cpr-style--set-opt (style opt-slot opt value)
  "Set OPT in STYLE's OPT-SLOT to VALUE."
  (setf (cl-struct-slot-value 'cpr-style opt-slot style)
	(cons (cons opt value)
	      (cl-struct-slot-value 'cpr-style opt-slot style))))

(defun cpr-style--set-opt-defaults (style)
  "Set missing options of STYLE to their default values."
  (cl-loop
   for (slot option value) in cpr-style--opt-defaults do
   (let ((slot-value (cl-struct-slot-value 'cpr-style slot style)))
     (when (null (alist-get option slot-value))
       (setf (cl-struct-slot-value 'cpr-style slot style)
	     (cons (cons option value) slot-value)))))
  (let* ((cite-opts (cpr-style-cite-opts style))
	 (collapse (alist-get 'collapse cite-opts)))
    (when (and collapse (not (string= collapse "citation-number")))
      (let ((cite-layout-dl (alist-get 'delimiter (cpr-style-cite-layout-attrs style)))
	    (cite-group-dl (alist-get 'cite-group-delimiter cite-opts)))
	(when (null cite-group-dl)
	  (cpr-style--set-opt style 'cite-opts 'cite-group-delimiter ", "))
	(when (null (alist-get 'after-collapse-delimiter cite-opts))
	  (cpr-style--set-opt style 'cite-opts 'after-collapse-delimiter cite-layout-dl))
	(when (and (member collapse '("year-suffix" "year-suffix-ranged"))
		   (null (alist-get 'year-suffix-delimiter cite-opts)))
	  (cpr-style--set-opt style 'cite-opts 'year-suffix-delimiter cite-layout-dl))))))

(defun cpr-style--transform-xmltree (tree)
  "Transform parsed csl xml fragment TREE into a lambda."
  `(lambda (context) ,(cpr-style--transform-xmltree-1 tree)))

(defun cpr-style--transform-xmltree-1 (tree)
  "Transform parsed xml fragment TREE into an eval-able form.
Symbols in car position are prefixed with `cpr--' and the symbol
`context' is inserted everywhere after the second (attrs)
position and before the (possibly empty) body."
  (pcase tree
    ((pred atom) tree)
    (`(names . ,_) (cpr-style--transform-names tree))
    (_
     `(,(intern (concat "cpr--" (symbol-name (car tree))))
       ,(list 'quote (cadr tree))
       context
       ,@(mapcar #'cpr-style--transform-xmltree-1 (cddr tree))))))

(defun cpr-style--transform-names (frag)
  "Transform the content of a cs:names CSL element xml FRAG."
  (let* ((names-attrs (cadr frag))
	 (body (-remove #'stringp (cddr frag)))
	 (vars (alist-get 'variable names-attrs))
	 substs name-attrs name-parts et-al-attrs
	 is-label label-attrs label-before-names)
    (--each body
      (pcase (car it)
	('name
	 (setq name-attrs (cadr it)
	       name-parts (cpr-lib-named-parts-to-alist it)
	       label-before-names t))
	('et-al
	 (setq et-al-attrs (cadr it)))
	('label
	 (setq is-label t
	       label-attrs (cadr it)
	       label-before-names nil))
	('substitute
	 (setq substs
	       (mapcar
		(lambda (x)
		  (if (eq (car x) 'names)
		      `(cpr-name-render-vars ,(alist-get 'variable (cadr x))
					     names-attrs name-attrs name-parts et-al-attrs
					     is-label label-before-names label-attrs context)
		    (cpr-style--transform-xmltree-1 x)))
		(cddr it))))))
    `(if (cpr-var-value 'suppress-author context) (cons nil 'empty-vars)
       (let* ((names-attrs (quote ,names-attrs))
	      (name-attrs (quote ,name-attrs))
	      (count (string= (alist-get 'form name-attrs) "count"))
	      (et-al-attrs (quote ,et-al-attrs))
	      (name-parts (quote ,name-parts))
	      (label-attrs (quote ,label-attrs))
	      (is-label ,is-label)
	      (label-before-names ,label-before-names)
	      (val (cpr-name-render-vars ,vars names-attrs name-attrs name-parts et-al-attrs
					 is-label label-before-names label-attrs context))
	      (result (if (car val)
			  val
			(-if-let ((cont . type) (--first (car it)
							 (list ,@substs)))
			    (cons (cons (list (quote (subst . t))) (list cont)) type)
			  (cons nil 'empty-vars)))))
	 (if count
	     (let* ((number (cpr-rt-count-names (car result)))
		    (str (if (= 0 number) "" (number-to-string number))))
	       (cons str (cdr result)))
	   result)))))

(defun cpr-style-global-opts (style layout)
  "Return the global opts in STYLE for LAYOUT.
LAYOUT is either `bib' or `cite'."
  (-concat (cl-ecase layout
	     (bib (cpr-style-bib-opts style))
	     (cite (cpr-style-cite-opts style)))
	   (cpr-style-opts style)))

(defun cpr-style-bib-opts-to-formatting-params (bib-opts)
  "Convert BIB-OPTS to a formatting parameters alist."
  (let ((result
	 (cl-loop
	  for (opt . val) in bib-opts
	  if (memq opt
		   '(hanging-indent line-spacing entry-spacing second-field-align))
	  collect (cons opt
			(pcase val
			  ("true" t)
			  ("false" nil)
			  ("flush" 'flush)
			  ("margin" 'margin)
			  (_ (string-to-number val)))))))
    (if (alist-get 'second-field-align result)
	result
      (cons (cons 'second-field-align nil)
	    result))))

(provide 'cpr-style)

;;; cpr-style.el ends here
