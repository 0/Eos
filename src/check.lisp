;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; indent-tabs-mode: nil -*-

(in-package :Eos)

(defvar *test-dribble* t)

(defmacro with-*test-dribble* (stream &body body)
  `(let ((*test-dribble* ,stream))
     (declare (special *test-dribble*))
     ,@body))

(defmacro bind-run-state (requested-vars &body body)
  `(let ,requested-vars
     (declare (special ,@(mapcar 'car requested-vars)))
     ,@body))
(defmacro with-run-state (requested-vars &body body)
  `(locally (declare (special ,@requested-vars)) ,@body))

(defclass test-result ()
  ((reason :accessor reason :initarg :reason :initform "no reason given")
   (test-case :accessor test-case :initarg :test-case)
   (test-expr :accessor test-expr :initarg :test-expr))
  (:documentation "All checking macros will generate an object of type TEST-RESULT."))

(defclass test-passed (test-result) ()
  (:documentation "Class for successful checks."))

(defgeneric test-passed-p (object)
  (:method ((o t)) nil)
  (:method ((o test-passed)) t))

(define-condition check-failure (error)
  ((reason :accessor reason :initarg :reason :initform "no reason given")
   (test-case :accessor test-case :initarg :test-case)
   (test-expr :accessor test-expr :initarg :test-expr))
  (:documentation "Signaled when a check fails.")
  (:report  (lambda (c stream)
              (format stream "The following check failed: ~S~%~A."
                      (test-expr c) (reason c)))))

(defmacro process-failure (&rest args)
  `(progn
     (with-simple-restart (ignore-failure "Continue the test run.")
       (error 'check-failure ,@args))
     (add-result 'test-failure ,@args)))

(defclass test-failure (test-result) ()
  (:documentation "Class for unsuccessful checks."))

(defgeneric test-failure-p (object)
  (:method ((o t)) nil)
  (:method ((o test-failure)) t))

(defclass unexpected-test-failure (test-failure)
  ((actual-condition :accessor actual-condition :initarg :condition))
  (:documentation "Represents the result of a test which neither
passed nor failed, but signaled an error we couldn't deal
with.

Note: This is very different than a SIGNALS check which instead
creates a TEST-PASSED or TEST-FAILURE object."))

(defclass test-skipped (test-result) ()
  (:documentation "A test which was not run. Usually this is due
to unsatisfied dependencies, but users can decide to skip test
when appropiate."))

(defgeneric test-skipped-p (object)
  (:method ((o t)) nil)
  (:method ((o test-skipped)) t))

(defun add-result (result-type &rest make-instance-args)
  "Create a TEST-RESULT object of type RESULT-TYPE passing it the
  initialize args MAKE-INSTANCE-ARGS and adds the resulting
  object to the list of test results."
  (with-run-state (result-list current-test)
    (let ((result (apply #'make-instance result-type
                         (append make-instance-args (list :test-case current-test)))))
      (format *test-dribble* (etypecase result
                               (test-passed             ".") (test-skipped "s")
                               (unexpected-test-failure "X") (test-failure "f")))
      (push result result-list))))

(defmacro is (test &rest reason-args)
  "The DWIM checking operator.

If TEST returns a true value a test-passed result is generated,
otherwise a test-failure result is generated. The reason, unless
REASON-ARGS is provided, is generated based on the form of TEST:

 (predicate expected actual) - Means that we want to check
 whether, according to PREDICATE, the ACTUAL value is
 in fact what we EXPECTED.

 (predicate value) - Means that we want to ensure that VALUE
 satisfies PREDICATE.

 Wrapping the TEST form in a NOT simply preducse a negated reason
 string."
  (assert (listp test) (test) "Argument to IS must be a list, not ~S" test)
  (let (bindings effective-test default-reason-args)
    (with-gensyms (e a v)
      (flet ((process-entry (predicate expected actual &optional negatedp)
               ;; make sure EXPECTED is holding the entry that starts with 'values
               (when (and (consp actual) (eq (car actual) 'values))
                 (assert (not (and (consp expected) (eq (car expected) 'values))) ()
                         "Both the expected and actual part is a values expression.")
                 (rotatef expected actual))
               (let (setf-forms)
                 (if (and (consp expected) (eq (car expected) 'values))
                     (progn
                       (setf expected (copy-list expected))
                       (setf setf-forms (loop :for cell := (rest expected) :then (cdr cell)
                                              :for i :from 0
                                              :while cell
                                              :when (eq (car cell) '*)
                                              :collect `(setf (elt ,a ,i) nil)
                                              :and :do (setf (car cell) nil)))
                       (setf bindings (list (list e `(list ,@(rest expected)))
                                            (list a `(multiple-value-list ,actual)))))
                     (setf bindings (list (list e expected) (list a actual))))
                 (setf effective-test `(progn
                                        ,@setf-forms
                                        ,(if negatedp
                                             `(not (,predicate ,e ,a))
                                             `(,predicate ,e ,a)))))))
        (list-match-case test
          ((not (?predicate ?expected ?actual))
           (process-entry ?predicate ?expected ?actual t)
           (setf default-reason-args
                 (list "~S evaluated to ~S, which is ~S to ~S (it should not be)"
                       `',?actual a `',?predicate e)))
          ((not (?satisfies ?value))
           (setf bindings (list (list v ?value))
                 effective-test `(not (,?satisfies ,v))
                 default-reason-args
                 (list "~S evaluated to ~S, which satisfies ~S (it should not)"
                       `',?value v `',?satisfies)))
          ((?predicate ?expected ?actual)
           (process-entry ?predicate ?expected ?actual)
           (setf default-reason-args
                 (list "~S evaluated to ~S, which is not ~S to ~S."
                       `',?actual a `',?predicate e)))
          ((?satisfies ?value)
           (setf bindings (list (list v ?value))
                 effective-test `(,?satisfies ,v)
                 default-reason-args
                 (list "~S evaluated to ~S, which does not satisfy ~S"
                       `',?value v `',?satisfies)))
          (?_
           (setf bindings '()
                 effective-test test
                 default-reason-args (list "~S was NIL." `',test)))))
      `(let ,bindings
         (if ,effective-test
             (add-result 'test-passed :test-expr ',test)
             (process-failure :reason (format nil ,@(or reason-args default-reason-args))
                              :test-expr ',test))))))

(defmacro skip (&rest reason)
  "Generates a TEST-SKIPPED result."
  `(add-result 'test-skipped :reason (format nil ,@reason)))

(defmacro is-true (condition &rest reason-args)
  "Like IS this check generates a pass if CONDITION returns true
  and a failure if CONDITION returns false. Unlike IS this check
  does not inspect CONDITION to determine how to report the
  failure."
  `(if ,condition
    (add-result 'test-passed :test-expr ',condition)
    (process-failure
     :reason ,(if reason-args
                  `(format nil ,@reason-args)
                  `(format nil "~S did not return a true value" ',condition))
     :test-expr ',condition)))

(defmacro is-false (condition &rest reason-args)
  "Generates a pass if CONDITION returns false, generates a
  failure otherwise. Like IS-TRUE, and unlike IS, IS-FALSE does
  not inspect CONDITION to determine what reason to give it case
  of test failure"
  (with-gensyms (value)
    `(let ((,value ,condition))
       (if ,value
           (process-failure
            :reason ,(if reason-args
                         `(format nil ,@reason-args)
                         `(format nil "~S returned the value ~S, which is true" ',condition ,value ))
            :test-expr ',condition)
           (add-result 'test-passed :test-expr ',condition)))))

(defmacro signals (condition-spec &body body)
  "Generates a pass if BODY signals a condition of type
CONDITION. BODY is evaluated in a block named NIL, CONDITION is
not evaluated."
  (let ((block-name (gensym)))
    (destructuring-bind (condition &optional reason-control reason-args)
        (ensure-list condition-spec)
      `(block ,block-name
         (handler-bind ((,condition (fun (add-result 'test-passed :test-expr ',condition)
                                         (return-from ,block-name t))))
           (block nil ,@body))
         (process-failure
          :reason ,(if reason-control
                       `(format nil ,reason-control ,@reason-args)
                       `(format nil "Failed to signal a ~S" ',condition))
          :test-expr ',condition)
         (return-from ,block-name nil)))))

(defmacro finishes (&body body)
  "Generates a pass if BODY executes to normal completion. In
other words if body does signal, return-from or throw this test
fails."
  `(let (ok)
     (unwind-protect (progn ,@body (setf ok t))
       (if ok
           (add-result 'test-passed :test-expr ',body)
           (process-failure
            :reason (format nil "Test didn't finish")
            :test-expr ',body)))))

(defmacro pass (&rest message-args)
  "Simply generate a PASS."
  `(add-result 'test-passed :test-expr ',message-args
               ,@(when message-args `(:reason (format nil ,@message-args)))))

(defmacro fail (&rest message-args)
  "Simply generate a FAIL."
  `(process-failure :test-expr ',message-args
                    ,@(when message-args `(:reason (format nil ,@message-args)))))
