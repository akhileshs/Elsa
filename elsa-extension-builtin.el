(require 'elsa-analyser)

;; * boolean functions
(defun elsa--analyse:not (form scope state)
  (elsa--analyse-function-call form scope state)
  (let* ((args (cdr (oref form sequence)))
         (arg-type (oref (car args) type)))
    (cond
     ((elsa-type-accept (elsa-type-nil) arg-type) ;; definitely false
      (oset form type (elsa-type-t)))
     ((not (elsa-type-accept arg-type (elsa-type-nil))) ;; definitely true
      (oset form type (elsa-type-nil)))
     (t (oset form type (elsa-make-type T?))))))

(defun elsa--analyse--eq (eq-form symbol-form constant-form)
  (let ((name (elsa-form-name symbol-form))
        (type))
    (setq type
          (cond
           ((elsa-form-keyword-p constant-form) (elsa-make-type Keyword))
           ((elsa--quoted-symbol-p constant-form) (elsa-make-type Symbol))
           ((and (elsa-form-symbol-p constant-form)
                 (eq (elsa-form-name constant-form) t))
            (elsa-make-type T))
           ((and (elsa-form-symbol-p constant-form)
                 (eq (elsa-form-name constant-form) nil))
            (elsa-make-type Nil))
           ((elsa-form-integer-p constant-form) (elsa-make-type Int))
           ((elsa-form-float-p constant-form) (elsa-make-type Float))))
    (when type (oset eq-form narrow-types (list (elsa-variable :name name :type type))))))

(defun elsa--analyse:eq (form scope state)
  (elsa--analyse-function-call form scope state)
  (let* ((args (elsa-cdr form))
         (first (car args))
         (second (cadr args)))
    (cond
     ((and (elsa-form-symbol-p first)
           (elsa-scope-get-var scope (elsa-form-name first)))
      (elsa--analyse--eq form first second))
     ((and (elsa-form-symbol-p second)
           (elsa-scope-get-var scope (elsa-form-name second)))
      (elsa--analyse--eq form second first)))
    (when (elsa-type-equivalent-p
           (elsa-type-empty)
           (elsa-type-intersect first second))
      (oset form type (elsa-type-nil)))))

;; * list functions
(defun elsa--analyse:car (form scope state)
  (elsa--analyse-function-call form scope state)
  (-when-let* ((arg (cadr (oref form sequence)))
               (arg-type (oref arg type)))
    (cond
     ((elsa-type-list-p arg-type)
      (oset form type (elsa-type-make-nullable (oref arg-type item-type))))
     ((elsa-type-cons-p arg-type)
      (oset form type (oref arg-type car-type))))))

(defun elsa--analyse:cons (form scope state)
  (elsa--analyse-function-call form scope state)
  (-when-let* ((car-type (oref (nth 1 (oref form sequence)) type))
               (cdr-type (oref (nth 2 (oref form sequence)) type)))
    (oset form type (elsa-type-cons :car-type car-type :cdr-type cdr-type))))

(defun elsa--analyse:elt (form scope state)
  (elsa--analyse-function-call form scope state)
  (-when-let* ((arg (cadr (oref form sequence)))
               (arg-type (oref arg type)))
    (when (elsa-instance-of arg-type (elsa-make-type Sequence))
      (let* ((item-type (elsa-type-get-item-type arg-type))
             ;; with lists it returns nil when overflowing, otherwise
             ;; throws an error
             (item-type (if (elsa-type-list-p arg-type)
                            (elsa-type-make-nullable item-type)
                          item-type)))
        (oset form type item-type)))))

;; * predicates
(defun elsa--analyse:stringp (form scope state)
  (elsa--analyse-function-call form scope state)
  (-when-let (arg (elsa-nth 1 form))
    (oset form type
          (cond
           ((elsa-type-accept (elsa-type-string) arg)
            (elsa-type-t))
           ;; if the arg-type has string as a component, for
           ;; example int | string, then it might evaluate
           ;; sometimes to true and sometimes to false
           ((elsa-type-accept arg (elsa-type-string))
            (elsa-make-type T?))
           (t (elsa-type-nil))))))

;; * control flow
(defun elsa--analyse:when (form scope state)
  (let ((condition (elsa-nth 1 form))
        (body (elsa-nthcdr 2 form))
        (return-type (elsa-type-empty)))
    (elsa--analyse-form condition scope state)
    (elsa--with-narrowed-variables condition scope
      (--each body (elsa--analyse-form it scope state)))
    (when body
      (setq return-type (oref (-last-item body) type)))
    (when (elsa-type-accept condition (elsa-type-nil))
      (setq return-type (elsa-type-make-nullable return-type))
      (when (elsa-type-accept (elsa-type-nil) condition)
        (setq return-type (elsa-type-nil))))
    (oset form type return-type)))

(defun elsa--analyse:unless (form scope state)
  (let ((condition (elsa-nth 1 form))
        (body (elsa-nthcdr 2 form))
        (return-type (elsa-type-nil))
        (vars-to-pop))
    (elsa--analyse-form condition scope state)
    (--each (oref condition narrow-types)
      (-when-let (scope-var (elsa-scope-get-var scope it))
        (elsa-scope-add-variable scope (elsa-type-diff scope-var it))
        (push it vars-to-pop)))
    (--each body (elsa--analyse-form it scope state))
    (--each vars-to-pop (elsa-scope-remove-variable scope it))
    (if (not (elsa-type-accept condition (elsa-type-nil)))
        (elsa-type-nil)
      (when body
        (setq return-type (oref (-last-item body) type)))
      (unless (elsa-type-equivalent-p (elsa-type-nil) condition)
        (setq return-type (elsa-type-make-nullable return-type))))
    (oset form type return-type)))


(provide 'elsa-extension-builtin)
