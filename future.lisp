(in-package :cl-async-future)

(defclass future ()
  ((callbacks :accessor future-callbacks :initform nil
    :documentation "A list that holds all callbacks associated with this future.")
   (forwarded-future :accessor future-forward-to :initform nil
    :documentation "Can hold a reference to another future, which will receive
                    callbacks and event handlers added to this one once set.
                    This allows a future to effectively take over another future
                    by taking all its callbacks/events.")
   (event-handler :accessor future-event-handler :initarg :event-handler :initform nil
    :documentation "Holds a callback that will handle events as they happen on
                    the future. If events occur and there is no handler, they
                    will be saved, in order, and sent to the handler once one is
                    attached.")
   (preserve-callbacks :accessor future-preserve-callbacks :initarg :preserve-callbacks :initform nil
    :documentation "When nil (the default) detaches callbacks after running
                    future.")
   (reattach-callbacks :accessor future-reattach-callbacks :initarg :reattach-callbacks :initform t
    :documentation "When a future's callback returns another future, bind all
                    callbacks from this future onto the returned one. Allows
                    values to transparently be derived from many layers deep of
                    futures, almost like a real call stack.")
   (finished :accessor future-finished :initform nil
    :documentation "Marks if a future has been finished or not.")
   (events :accessor future-events :initform nil
    :documentation "Holds events for this future, to be handled with event-handler.")
   (values :accessor future-values :initform nil
    :documentation "Holds the finished value(s) of the computer future. Will be
                    apply'ed to the callbacks."))
  (:documentation
    "Defines a class which represents a value that MAY be ready sometime in the
     future. Also supports attaching callbacks to the future such that they will
     be called with the computed value(s) when ready."))

(defmethod print-object ((future future) s)
  (format s "#<Future (~s callbacks) (ev handler: ~s) (finished: ~a) (forward: ~a)>"
          (length (future-callbacks future))
          (not (not (future-event-handler future)))
          (future-finished future)
          (not (not (future-forward-to future)))))

(defun make-future (&key preserve-callbacks (reattach-callbacks t))
  "Create a blank future."
  (make-instance 'future :preserve-callbacks preserve-callbacks
                         :reattach-callbacks reattach-callbacks))

(defun futurep (future)
  "Is this a future?"
  (subtypep (type-of future) 'future))

(defun setup-future-forward (future-from future-to)
  "Set up future-from to send all callbacks, events, handlers, etc to the
   future-to future. This includes all current objects, plus objects that may be
   added later on. For instance, if you forward future A to future B, adding an
   event handler to future A will then add it to future B (assuming future B has
   no current event handler). The same goes for callbacks as well, they will be
   added to the new future-to if added to the future-from."
  ;; a future "returned" another future. reattach the callbacks from
  ;; the original future onto the returned on
  (setf (future-callbacks future-to) (future-callbacks future-from))
  ;; if the new future doesnt have an explicit error handler, attach
  ;; the handler from one future level up
  (unless (future-event-handler future-to)
    (setf (future-event-handler future-to) (future-event-handler future-from)))
  ;; forward the current future to the new one. all 
  (setf (future-forward-to future-from) future-to))

(defun lookup-actual-future (future)
  "This function follows forwarded futures until it finds the last in the chain
   of forwarding."
  (when (futurep future)
    (loop while (future-forward-to future) do
      (setf future (future-forward-to future))))
  future)

(defun run-event-handler (future)
  "If an event handler exists for this future, run all events through the
   handler and clear the events out once run."
  (let ((event-handler (future-event-handler future)))
    (when event-handler
      (dolist (event (nreverse (future-events future)))
        (funcall event-handler event))
      (setf (future-events future) nil))))

(defun set-event-handler (future cb)
  "Sets the event handler for a future. If the handler is attached after events
   have already been caught, they will be passed into the handler, in order,
   directly after it is added."
  (when (futurep future)
    (let ((forwarded-future (lookup-actual-future future)))
      (when (or (equal future forwarded-future)
                (not (future-event-handler forwarded-future)))
        (setf (future-event-handler forwarded-future) cb)
        (run-event-handler forwarded-future))))
  future)

(defun signal-event (future condition)
  "Signal that an event has happened on a future. If the future has an event
   handler, the given condition will be passed to it, otherwise the event will
   be saved until an event handler has been attached."
  (let ((forwarded-future (lookup-actual-future future)))
    (push condition (future-events forwarded-future))
    (run-event-handler forwarded-future)))

(defun run-future (future)
  "Run all callbacks on a future *IF* the future is finished (and has computed
   values). If preserve-callbacks in the future is set to nil, the future's
   callbacks will be detached after running."
  (when (future-finished future)
    (let ((callbacks (future-callbacks future))
          (values (future-values future)))
      (dolist (cb (reverse callbacks))
        (apply cb values)))
    ;; clear out the callbacks if specified
    (unless (future-preserve-callbacks future)
      (setf (future-callbacks future) nil))
    future))

(defun finish (future &rest values)
  "Mark a future as finished, along with all values it's finished with. If
   finished with another future, forward the current future to the new one."
  (let ((new-future (car values)))
    (cond ((and (futurep new-future)
                (future-reattach-callbacks future))
           ;; set up the current future to forward all callbacks/handlers/events
           ;; to the new future from now on.
           (setup-future-forward future new-future)
           ;; run the new future
           (run-future new-future))
          (t
           ;; just a normal finish, run the future
           (setf (future-finished future) t
                 (future-values future) values)
           (run-future future)))))

(defun attach-cb (future-values cb)
  "Attach a callback to a future. The future must be the first value in a list
   of values (car future-values) OR the future-values will be apply'ed to cb."
  (let* ((future future-values)
         (future (if (futurep future)
                     (lookup-actual-future future)  ; follow forwarded futures
                     (car future-values)))
         (cb-return-future (make-future))
         (cb-wrapped (lambda (&rest args)
                       (let ((cb-return (multiple-value-list (apply cb args))))
                         (apply #'finish (append (list cb-return-future)
                                                 cb-return))))))
    ;; if we were indeed passed a future, attach the callback to it AND run the
    ;; future if it has finished.
    (if (futurep future)
        (progn
          (push cb-wrapped (future-callbacks future))
          (run-future future))
        ;; not a future, just a value. run the callback directly
        (apply cb-wrapped future-values))
    cb-return-future))

(defmacro attach (future-gen cb)
  "Macro wrapping attachment of callback to a future (takes multiple values into
   account, which a simple function cannot)."
  `(let ((future-gen-vals (multiple-value-list ,future-gen)))
     (cl-async-future::attach-cb future-gen-vals ,cb)))

;; -----------------------------------------------------------------------------
;; start our syntactic abstraction section (rolls off the tongue nicely)
;; -----------------------------------------------------------------------------

(defmacro %alet (bindings &body body)
  "Asynchronous let. Allows calculating a number of values in parallel via
   futures, and runs the body when all values have computed with the bindings
   given available to the body.
   
   Also returns a future that fires with the values returned from the body form,
   which allows arbitrary nesting to get a final value(s)."
  (let* ((ignore-bindings nil)
         (bindings (loop for (bind form) in bindings
                         collect (list (if bind
                                           bind
                                           (let ((igsym (gensym "alet-ignore")))
                                             (push igsym ignore-bindings)
                                             igsym))
                                       form)))
         (bind-vars (loop for (bind nil) in bindings collect bind))
         (num-bindings (length bindings))
         (finished-future (gensym "finished-future"))
         (finished-vals (gensym "finished-vals"))
         (finished-cb (gensym "finished-cb"))
         (args (gensym "args")))
    `(let* ((,finished-future (make-future))
            (,finished-vals nil)
            (,finished-cb
              (let ((c 0))
                (lambda ()
                  (incf c)
                  (when (<= ,num-bindings c)
                    (let ((vars (loop for bind in ',bind-vars collect (getf ,finished-vals bind))))
                      (apply #'finish (append (list ,finished-future) vars))))))))
       ;; for each binding, attach a callback to the future it generates that
       ;; marks itself as complete. once all binding forms report in, the main
       ;; future "finished-future" is triggered, which runs the body
       ,@(loop for (bind form) in bindings collect
           `(let ((future-gen (multiple-value-list ,form)))
              ;; forward events we get on this future to the finalizing future,
              ;; but only if the future doesn't already have an event handler
              (when (and (futurep (car future-gen))
                         (not (future-event-handler (car future-gen))))
                (set-event-handler (car future-gen)
                  (lambda (ev)
                    (signal-event ,finished-future ev))))
              ;; when this future finishes, call the finished-cb, which tallies
              ;; up the number of finishes until it equals the number of
              ;; bindings.
              (attach (apply #'values future-gen)
                (lambda (&rest ,args)
                  (setf (getf ,finished-vals ',bind) (car ,args))
                  (funcall ,finished-cb)))))
       ;; return our future which gets fired when all bindings have completed.
       ;; gets events forwarded to it from the binding futures.
       (attach ,finished-future
         (lambda ,bind-vars
           ,(when ignore-bindings
              `(declare (ignore ,@ignore-bindings)))
           ,@body)))))

(defmacro %alet* (bindings &body body)
  "Asynchronous let*. Allows calculating a number of values in sequence via
   futures, and run the body when all values have computed with the bindings
   given available to the body.
   
   Also returns a future that fires with the values returned from the body form,
   which allows arbitrary nesting to get a final value(s)."
  (if bindings
      (let* ((binding (car bindings))
             (bind (car binding))
             (ignore-bind (not bind))
             (bind (if ignore-bind (gensym "async-ignore") bind))
             (future (cadr binding))
             (args (gensym "args")))
        ;; since this is in the tail-position, no need to explicitely set
        ;; callbacks/event handler since they will be reattached automatically.
        `(attach ,future
           (lambda (&rest ,args)
             (let ((,bind (car ,args)))
               ,(when ignore-bind `(declare (ignore ,bind)))
               ;; being recursive helps us keep the code cleaner...
               (alet* ,(cdr bindings) ,@body)))))
      `(progn ,@body)))

(defmacro %multiple-future-bind ((&rest bindings) future-gen &body body)
  "Like multiple-value-bind, but instead of a form that evaluates to multiple
   values, takes a form that generates a future."
  (let ((args (gensym "args")))
    `(attach ,future-gen
       (lambda (&rest ,args)
         (let (,@bindings)
           ,@(loop for b in bindings collect
               `(setf ,b (car ,args)
                      ,args (cdr ,args)))
           ,@body)))))

(defmacro %wait-for (future-gen &body body)
  "Wait for a future to finish, ignoring any values it returns. Can be useful
   when you want to run an async action but don't care about the return value
   (or it doesn't return a value) and you want to continue processing when it
   returns."
  (let ((ignore-var (gensym "async-ignore")))
    `(attach ,future-gen
       (lambda (&rest ,ignore-var)
         (declare (ignore ,ignore-var))
         ,@body))))

;; -----------------------------------------------------------------------------
;; define the public interfaces for our heroic syntax macros
;; -----------------------------------------------------------------------------
(defmacro alet (bindings &body body)
  "Asynchronous let. Allows calculating a number of values in parallel via
   futures, and runs the body when all values have computed with the bindings
   given available to the body.
   
   Also returns a future that fires with the values returned from the body form,
   which allows arbitrary nesting to get a final value(s)."
  `(%alet ,bindings ,@body))

(defmacro alet* (bindings &body body)
  "Asynchronous let*. Allows calculating a number of values in sequence via
   futures, and run the body when all values have computed with the bindings
   given available to the body.
   
   Also returns a future that fires with the values returned from the body form,
   which allows arbitrary nesting to get a final value(s)."
  `(%alet ,bindings ,@body))

(defmacro multiple-future-bind ((&rest bindings) future-gen &body body)
  "Like multiple-value-bind, but instead of a form that evaluates to multiple
   values, takes a form that generates a future."
  `(%multiple-future-bind ,bindings ,future-gen ,@body))

(defmacro wait-for (future-gen &body body)
  "Wait for a future to finish, ignoring any values it returns. Can be useful
   when you want to run an async action but don't care about the return value
   (or it doesn't return a value) and you want to continue processing when it
   returns."
  `(%wait-for ,future-gen ,@body))

(defmacro future-handler-case (body-form &rest error-forms)
  "Wrap all of our lovely syntax macros up with an event handler. This is more
   or less restricted to the form it's run in."
  (let ((event-handler (gensym "errhandler")))
    `(let ((,event-handler (lambda (ev)
                             (handler-case (error ev)
                               ,@error-forms))))
       (handler-case
         (macrolet ((wrap-event-handler (future-gen handler)
                      (let ((vals (gensym "future-vals")))
                        `(let ((,vals (multiple-value-list ,future-gen)))
                           (if (futurep (car ,vals))
                               (set-event-handler (car ,vals) ,handler)
                               (apply #'values ,vals))))))
           (macrolet ((alet (bindings &body body)
                        `(%alet ,(loop for (bind form) in bindings
                                       collect `(,bind (wrap-event-handler ,form ,',event-handler)))
                           ,@body))
                      (alet* (bindings &body body)
                        `(%alet* ,(loop for (bind form) in bindings
                                        collect `(,bind (wrap-event-handler ,form ,',event-handler)))
                           ,@body))
                      (multiple-future-bind ((&rest bindings) future-gen &body body)
                        `(%multiple-future-bind ,bindings
                             (wrap-event-handler ,future-gen ,',event-handler)
                           ,@body))
                      (wait-for (future-gen &body body)
                        `(%wait-for (wrap-event-handler ,future-gen ,',event-handler)
                           ,@body)))
             ,body-form))
         ,@error-forms))))
