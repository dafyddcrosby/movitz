;;;;------------------------------------------------------------------
;;;; 
;;;;    Copyright (C) 2001-2005, 
;;;;    Department of Computer Science, University of Tromso, Norway.
;;;; 
;;;;    For distribution policy, see the accompanying file COPYING.
;;;; 
;;;; Filename:      debugger.lisp
;;;; Description:   Debugging functionality.
;;;; Author:        Frode Vatvedt Fjeld <frodef@acm.org>
;;;; Created at:    Fri Nov 22 10:09:18 2002
;;;;                
;;;; $Id: debugger.lisp,v 1.43 2007/04/12 16:11:15 ffjeld Exp $
;;;;                
;;;;------------------------------------------------------------------

(provide :x86-pc/debugger)

(in-package muerte)

(defparameter *backtrace-be-spartan-p* nil)

(defparameter *backtrace-conflate-names*
    '(nil funcall
      apply
      backtrace

      muerte::funcall%0ops
      muerte::funcall%1op
      muerte::funcall%2op
      muerte::funcall%3op
      muerte::interrupt-default-handler
      muerte::eval-cons
      muerte::eval-funcall
      muerte::eval-form
      muerte::eval-progn
      muerte::slow-method-lookup
      muerte::do-slow-method-lookup
      muerte::initial-discriminating-function
      muerte::discriminating-function-max
      muerte::discriminating-function-max-step2
      invoke-debugger-on-designator))

(defconstant +backtrace-gf-discriminatior-functions+
    '(muerte::discriminating-function-max
      muerte::discriminating-function-max%1op
      muerte::discriminating-function-max%1op%no-eqls
      muerte::discriminating-function-max%2op%no-eqls))

(defvar *backtrace-do-conflate* t)
(defvar *backtrace-length* 14)
(defvar *backtrace-max-args* 16)
(defvar *backtrace-stack-frame-barrier* nil)
(defvar *backtrace-do-fresh-lines* t)
(defvar *backtrace-print-length* 3)
(defvar *backtrace-print-level* 3)
(defvar *backtrace-print-frames* nil)

(defun pointer-in-range (x)
  (with-inline-assembly (:returns :boolean-cf=1)
    (:compile-form (:result-mode :eax) x)
    (:cmpl #x10000000 :eax)))

    
(defun code-vector-offset (code-vector address)
  "If address points somewhere inside code-vector, return the offset."
  (check-type code-vector vector)
  (when (> (truncate address #.movitz::+movitz-fixnum-factor+)
	   (object-location code-vector))
    (let ((delta (- address 8 (* #.movitz::+movitz-fixnum-factor+
				 (object-location code-vector)))))
      (when (<= 0 delta (length code-vector))
	delta))))

(defun funobj-name-or-nil (x)
  (typecase x
    (compiled-function
     (funobj-name x))
    (t nil)))

(defparameter +call-site-numargs-maps+
    '((1 . (#xff #x56
		 #.(cl:ldb (cl:byte 8 0)
			   (bt:slot-offset 'movitz::movitz-funobj 'movitz::code-vector%1op))))
      (2 . (#xff #x56
	    #.(cl:ldb (cl:byte 8 0)
	       (bt:slot-offset 'movitz::movitz-funobj 'movitz::code-vector%2op))))
      (3 . (#xff #x56
	    #.(cl:ldb (cl:byte 8 0)
	       (bt:slot-offset 'movitz::movitz-funobj 'movitz::code-vector%3op))))
      (0 . (#x33 #xc9 #xff #x56		; xorl :ecx :ecx
	    #.(cl:ldb (cl:byte 8 0)
	       (bt:slot-offset 'movitz::movitz-funobj 'movitz::code-vector))))
      (0 . (#xb1 #x00 #xff #x56		; movb 0 :cl
	    #.(cl:ldb (cl:byte 8 0)
	       (bt:slot-offset 'movitz::movitz-funobj 'movitz::code-vector))))
      (2 . (#xff #x57
	    #.(movitz:global-constant-offset 'fast-compare-two-reals)))
      (:ecx . (#xff #x56 #.(cl:ldb (cl:byte 8 0)
			    (bt:slot-offset 'movitz::movitz-funobj 'movitz::code-vector))))))

(defun stack-frame-numargs (stack frame)
  "Try to determine how many arguments was presented to the stack-frame."
  (if (eq (stack-frame-funobj stack frame)
	  (load-global-constant complicated-class-of))
      1
    (multiple-value-bind (call-site code funobj)
	(stack-frame-call-site stack frame)
      (when (and call-site code)
	(dolist (map +call-site-numargs-maps+
		  #+ignore (warn "no match at ~D for ~S frame ~S [~S]."
				 call-site
				 (stack-frame-funobj stack (stack-frame-uplink stack frame))
				 frame funobj))
	  (when (not (mismatch code (cdr map)
			       :start1 (max 0 (- call-site (length (cdr map))))
			       :end1 call-site))
	    (return
	      (cond
	       ((integerp (car map))
		(car map))
	       ((eq :ecx (car map))
		(let ((load-ecx-index (- call-site 4)))
		  (loop while (and (plusp load-ecx-index)
				   (= #x90 (aref code load-ecx-index))) ; Skip any NOPs
		      do (decf load-ecx-index))
		  (let ((opcode0 (aref code (1- load-ecx-index)))
			(opcode1 (aref code load-ecx-index)))
		    (cond
		     ((= #xb1 opcode0)
		      ;; Assume it's a (:movb x :cl) instruction
		      (aref code load-ecx-index))
		     ((and (= #x33 opcode0) (= #xc9 opcode1))
		      ;; XORL :ECX :ECX
		      0)
		     ((eq funobj #'apply)
		      (- (stack-frame-uplink stack frame)
			 frame
			 2))
		     (t ;; now we should search further for where ecx may be set..
		      (format *debug-io* "{no ECX at ~D in ~S, opcode #x~X #x~X}"
			      call-site funobj opcode0 opcode1)
		      nil)))))))))))))

(defun signed8-index (s8)
  "Convert a 8-bit twos-complement signed integer bitpattern to
its natural value divided by 4."
  (assert (= 0 (ldb (byte 2 0) s8)))
  (values (if (> s8 #x7f)
	      (truncate (- s8 #x100) 4)
	    (truncate s8 4))))

(defun match-code-pattern (pattern code-vector start-ip &optional register)
  "Return success-p, result-register, result-position, ip.
It is quite possible to return success without having found the result-{register,position}."
  (do (result-register
       result-position
       (ip start-ip)
       (pattern pattern (cdr pattern)))
      ((endp pattern)
       (values t result-register result-position ip))
    (let ((p (car pattern)))
      (cond
       ((not (below ip (length code-vector)))
	;; mismatch because code-vector is shorter than pattern
	(return nil))
       ((listp p)
	(case (car p)
	  (:set-result
	   (setf result-register (second p)
		 result-position (third p)))
	  (:or
	   (dolist (sub-pattern (cdr p) (return-from match-code-pattern nil))
	     (multiple-value-bind (success-p sub-result-register sub-result-position new-ip)
		 (match-code-pattern sub-pattern code-vector ip register)
	       (when success-p
		 (when sub-result-register
		   (setf result-register sub-result-register
			 result-position sub-result-position))
		 (setf ip new-ip)
		 (return)))))
	  (:* (let ((max-times (second p)) ; (:kleene-star <max-times> <sub-pattern>)
		    (sub-pattern (third p)))
		(dotimes (i max-times)
		  (multiple-value-bind (success-p sub-result-register sub-result-position new-ip)
		      (match-code-pattern sub-pattern code-vector ip register)
		    (unless success-p
		      (return))
		    (when sub-result-register
		      (setf result-register sub-result-register
			    result-position sub-result-position))
		    (setf ip new-ip)))))
	  (:constant
	   (when (eq (second p) register)
	     (setf result-register :constant
		   result-position (third p))))
	  (t (when (and register
			(eq (car p) register))
	       (setf result-register (second p)
		     result-position (or (third p) (aref code-vector ip))))
	     (incf ip))))
       (t (unless (= p (aref code-vector ip))
	    ;; mismatch
	    (return nil))
	  (incf ip))))))
	    
(defparameter *call-site-patterns*
    '(((6 22 . ((:* 4 ((:or (#x8b #x44 #x24 (:eax :esp)) ; #<asm MOVL [#x8+%ESP] => %EAX>
			    (#x8b #x5c #x24 (:ebx :esp)) ; #<asm MOVL [#x4+%ESP] => %EBX>
			    (#x8b #x45 (:eax :ebp)) ; (:movl (:ebp x) :eax)
			    (#x8b #x46 (:eax :esi)) ; (:movl (:esi x) :eax)
			    (#x8b #x5d (:ebx :ebp)) ; (:movl (:ebp x) :ebx)
			    (#x8b #x5e (:ebx :esi)) ; (:movl (:esi x) :ebx)
			    (#x33 #xdb (:constant :ebx 0))
			    )))
		(:* 1 ((:or ((:or (#x8b #x56 (:edx :esi)) ;     (:movl (:esi x) :edx)
				  (#x8b #x54 #x37 (:edx :esi+edi))) ;#<asm MOVL [#x39+%EDI+%ESI] => %EDX>
			     #x8b #x72 #xf9) ;     (:movl (:edx -7) :esi)
			    (#x8b #x74 #x7e (:any-offset)) ; #<asm MOVL [#x28+%ESI+%EDI*2] => %ESI>
			    (#x8b #x76 (:any-offset))))) ; #<asm MOVL [#x56+%ESI] => %ESI>
		(:* 1 ((:or (#xb1 (:cl-numargs))))) ; (:movb x :cl)
		(:* 1 ((:or (#x8b #x55 (:edx :ebp))
			    (#x8b #x56 (:edx :esi)))))
		(:* 4 (#x90))		; (:nop)
		#xff #x56 (:code-vector)))) ; (:call (:esi x))
      ;; APPLY 3 args
      ((20 20 . (#x8b #x5d (:ebx :ebp)	; #<asm MOVL [#x-c+%EBP] => %EBX>
		 #x8d #x4b #xff		; #<asm LEAL [#x-1+%EBX] %ECX>
		 #xf6 #xc1 #x07		; #<asm TESTB #x7 %CL>
		 #x75 #x15		; #<asm JNE %PC+#x15> ; branch to #:|sub-prg-label-#?317| at 258
		 #x89 #x43 #x03		; #<asm MOVL %EAX => [#x3+%EBX]>
		 #x8b #x45 (:eax :ebp)	; #<asm MOVL [#x-8+%EBP] => %EAX>
		 #xff #x56 (:code-vector)))) ; #<asm CALL [#x6+%ESI]>
      ;; Typical FUNCALL
      ((28 38 . ((:* 1 (#x8b #x45 (:eax :ebp))) ; #<asm MOVL [#x-18+%EBP] => %EAX>
		 (:* 1 (#x8b #x5d (:ebx :ebp))) ; #<asm MOVL [#x-14+%EBP] => %EBX>
		 (:or (#x8b #x55 (:edx :ebp)) ; #<asm MOVL [#x-1c+%EBP] => %EDX>
		      (#x5a)		; #<asm POPL %EDX>
		      ())
		 #x8d #x4a (:or (#x01) (#xf9)) ; #<asm LEAL [#x1+%EDX] %ECX>
		 (:or (#xf6 #xc1 #x07)	; #<asm TESTB #x7 %CL>
		      (#x80 #xe1 #x07))	; #<asm ANDB #x7 %CL>
		 #x75 (:any-label)	; #<asm JNE %PC+#x5> ; branch to #:|NOT-SYMBOL-#?909| at 284
		 #x8b #x72 #xfd		; #<asm MOVL [#x-3+%EDX] => %ESI>
		 #xeb (:any-label)	; #<asm JMP %PC+#xe> ; branch to #:|FUNOBJ-OK-#?911| at 298
					; #:|NOT-SYMBOL-#?909| 
		 (:or (#x41		; #<asm INCL %ECX>
		       #xf6 #xc1 #x07)	; #<asm TESTB #x7 %CL>
		      (#x80 #xf9 #x07)	; #<asm CMPB #x7 %CL>
		      (#x8d #x4a #xfa	; #<asm LEAL [#x-6+%EDX] %ECX>
			    #xf6 #xc1 #x07)) ; #<asm TESTB #x7 %CL>
		 #x75 (:any-label)	; #<asm JNE %PC+#xd> ; branch to #:|NOT-FUNOBJ-#?910| at 303
		 #x80 #x7a #xfe #x10	; #<asm CMPB #x10 [#x-2+%EDX]> ; #x4
		 #x75 (:any-label)	; #<asm JNE %PC+#x7> ; branch to #:|NOT-FUNOBJ-#?910| at 303
		 (:or (#x89 #xd6)	; #<asm MOVL %EDX => %ESI>
		      (#x8b #xf2))	; #<asm MOVL %EDX => %ESI>
					; #:|FUNOBJ-OK-#?911| 
		 #xff #x56 (:code-vector)))) ; #<asm CALL [#x6+%ESI]>
      ))

(defun call-site-find (stack frame register)
  "Based on call-site's code, figure out where eax and ebx might be
located in the caller's stack-frame or funobj-constants."
  (macrolet ((success (result)
	       `(return-from call-site-find (values ,result t))))
    (multiple-value-bind (call-site-ip code-vector funobj)
	(stack-frame-call-site stack frame)
      (when (eq funobj #'apply)
	(let ((apply-frame (stack-frame-uplink stack frame)))
	  (when (eq 2 (stack-frame-numargs stack apply-frame))
	    (let ((applied (call-site-find stack apply-frame :ebx)))
	      ;; (warn "reg: ~S, applied: ~S" register applied)
	      (case register
		(:eax (success (first applied)))
		(:ebx (success (second applied))))))))
      (when (and call-site-ip code-vector)
	(loop for ((pattern-min-length pattern-max-length . pattern)) in *call-site-patterns*
	    do (loop for pattern-length from pattern-max-length downto pattern-min-length
		   do (multiple-value-bind (success-p result-register result-position match-ip)
			  (match-code-pattern pattern code-vector (- call-site-ip pattern-length) register)
			(when (and success-p (= call-site-ip match-ip))
			  (case result-register
			    (:constant
			     (success result-position))
			    (:ebp
			     (success (stack-frame-ref stack
						       (stack-frame-uplink stack frame)
						       (signed8-index result-position))))
			    (:esi
			     (when funobj
			       (success (funobj-constant-ref
					 funobj
					 (signed8-index (- result-position
							   #.(bt:slot-offset 'movitz::movitz-funobj
									     'movitz::constant0)))))))
			    (:esp
			     (success (stack-frame-ref stack frame
						       (+ 2 (signed8-index result-position))))))))))))))

(defparameter *stack-frame-setup-patterns*
    '(((:* 1 (#x64 #x62 #x67 (any-offset))) ; #<asm (FS-OVERRIDE) BOUND [#x-19+%EDI] %ESP>
       (:* 1 (#x55 #x8b #xec #x56))	; pushl ebp, movl esp
       (:* 2 (#x80 #xf9 (cmpargs)
		   (:or (#x72 (label))
			(#x75 (label))
			(#x77 (label))
			(#x0f #x82 (label) (label) (label) (label))
			(#x0f #x85 (label) (label) (label) (label))
			(#x0f #x87 (label) (label) (label) (label)))))
       (:* 1 (#x84 #xc9			; #<asm TESTB %CL %CL>
		   (:or (#x78 (label))	; #<asm JS %PC+#xed>
			(#x0f #x88 (label) (label) (label) (label)))
		   #x83 #xe2 #x7f))	; #<asm ANDL #x7f %ECX>
       (:* 1 (#x89 #x55 (:edx :ebp)))
       (:or (#x50 #x53 #x52 (:set-result (-4 -2 -3)))
	    (#x50 #x53 (:set-result (nil -2 -3)))
	    (#x50 #x52 (:set-result (-3 -2)))
	    (#x50 (:set-result (nil -2)))
	    (#x53 (:set-result (nil nil -2)))
	    (#x52 (:set-result (-2)))))))

(defun funobj-stack-frame-map (funobj &optional numargs)
  "Try to find funobj's stack-frame map, which is a list that says
what the stack-frame contains at that position. Some funobjs' map
depend on the number of arguments presented to it, so numargs can
be provided for those cases."
  (multiple-value-bind (code-vector start-ip)
      (let ((x (case numargs
		 (1 (funobj-code-vector%1op funobj))
		 (2 (funobj-code-vector%2op funobj))
		 (3 (funobj-code-vector%3op funobj))
		 (t (let ((setup-start (ldb (byte 5 0)
					    (funobj-debug-info funobj))))
		      (if (= setup-start 31) 0 setup-start))))))
	(cond
	 ((integerp x)
	  (values (funobj-code-vector funobj) x))
	 ((or (eq x (symbol-value 'muerte::trampoline-funcall%1op))
	      (eq x (symbol-value 'muerte::trampoline-funcall%2op))
	      (eq x (symbol-value 'muerte::trampoline-funcall%3op)))
	  (values (funobj-code-vector funobj) 0))
	 (t (values x 0))))
    (multiple-value-bind (successp map)
	(match-code-pattern (car *stack-frame-setup-patterns*) code-vector start-ip)
      (if successp
	  map
	#+ignore
	(multiple-value-bind (successp result-register result-position)
	    (match-code-pattern (car *stack-frame-setup-patterns*)
				code-vector start-ip :edx)
	  (when (and successp (eq :ebp result-register))
	    (list (signed8-index result-position))))))

    #+ignore
    (cdr (dolist (pattern-map *stack-frame-setup-patterns*)
	   (when (match-code-pattern (car pattern-map) code-vector setup-start)
	     (return pattern-map))))))

(defun print-stack-frame-arglist (stack frame stack-frame-map
				  &key (numargs (stack-frame-numargs stack frame))
				       (edx-p nil))
  (flet ((stack-frame-register-value (stack frame register stack-map-pos)
	   (multiple-value-bind (val success-p)
	       (call-site-find stack frame register)
	     (cond
	      (success-p
	       (values val t))
	      (stack-map-pos
	       (values (stack-frame-ref stack frame stack-map-pos)
		       t))
	      (t (values nil nil)))))
	 (debug-write (x)
	   (if *backtrace-be-spartan-p*
	       (print-word x t)
	     (typecase x
	       (muerte::tag3
		(format t "{tag3 ~Z}" x))
	       ((and (not null) muerte::tag5)
		(format t "{tag5 ~Z}" x))
	       ((and (not character) (not restart) muerte::tag2)
		(format t "{tag2 ~Z}" x))
	       ((or null integer character)
		(write x))
	       (t (if (pointer-in-range x)
		      (write x)
		    (format t "{out-of-range ~Z}" x)))))))
    (if (not numargs)
	(write-string " ...")
      (prog () ;; (numargs (min numargs *backtrace-max-args*)))
	(multiple-value-bind (edx foundp)
	    (stack-frame-register-value stack frame :edx (pop stack-frame-map))
	  (when edx-p
	    (write-string " {edx: ")
	    (if foundp
		(debug-write edx)
	      (write-string "unknown"))
	    (write-string "}")))
	(when (zerop numargs)
	  (return))
	(write-char #\space)
	(if (first stack-frame-map)
	    (debug-write (stack-frame-ref stack frame (first stack-frame-map)))
	  (multiple-value-bind (eax eax-p)
	      (call-site-find stack frame :eax)
	    (if eax-p
		(debug-write eax)
	      (write-string "{eax unknown}"))))
	(when (> 2 numargs)
	  (return))
	(write-char #\space)
	(if (second stack-frame-map)
	    (debug-write (stack-frame-ref stack frame (second stack-frame-map)))
	  (multiple-value-bind (ebx ebx-p)
	      (call-site-find stack frame :ebx)
	    (if ebx-p
		(debug-write ebx)
	      (write-string "{ebx unknown}"))))
	(loop for i downfrom (1- numargs) to 2
	    as printed-args upfrom 2
	    do (when (> printed-args *backtrace-max-args*)
		 (write-string " ...")
		 (return))
	       (write-char #\space)
	       (debug-write (stack-frame-ref stack frame i))))))
  (values))

(defun safe-print-stack-frame-arglist (&rest args)
  (declare (dynamic-extent args))
  (handler-case (apply #'print-stack-frame-arglist args)
    (serious-condition (conditon)
      (declare (ignore conditon))
      (write-string "#<error printing frame>"))))

(defun location-index (vector location)
  (assert (location-in-object-p vector location))
  (- location (object-location vector) 2))

(defun find-primitive-code-vector-by-eip (eip &optional (context (current-run-time-context)))
  (loop with location = (truncate eip 4)
      for (slot-name type) in (slot-value (class-of context) 'slot-map)
      do (when (eq type 'code-vector-word)
	   (let ((code-vector (%run-time-context-slot nil slot-name)))
	     (when (location-in-object-p code-vector location)
	       (return (values slot-name (code-vector-offset code-vector eip))))))))

(defun backtrace (&key (stack nil)
		       ((:frame initial-stack-frame-index)
			(if stack
			    (stack-frame-ref stack 0 0)
			  (or *debugger-invoked-stack-frame*
			      (current-stack-frame))))
		       ;; (relative-uplinks (not (eq stack (%run-time-context-slot 'stack-vector))))
		       ((:spartan *backtrace-be-spartan-p*))
		       ((:fresh-lines *backtrace-do-fresh-lines*) *backtrace-do-fresh-lines*)
		       (conflate *backtrace-do-conflate*)
		       (length *backtrace-length*)
		       print-returns conflate-interrupts
		       ((:print-frames *backtrace-print-frames*) *backtrace-print-frames*))
  (let ((*print-safely* t)
	(*standard-output* *debug-io*)
	(*print-length* *backtrace-print-length*)
	(*print-level* *backtrace-print-level*))
    (loop with conflate-count = 0 with count = 0 with next-frame = nil
	for frame = initial-stack-frame-index
	then (or next-frame
		 (let ((uplink (stack-frame-uplink stack frame)))
		   (assert (typep uplink 'fixnum) ()
		     "Weird uplink ~S for frame ~S." uplink frame)
		   (assert (> uplink frame) ()
		     "Backtracing uplink ~S from frame index ~S." uplink frame)
		   uplink))
	     ;; as xxx = (warn "frame: ~S" frame)
	as funobj = (stack-frame-funobj stack frame)
	do (setf next-frame nil)
	   (flet ((print-leadin (stack frame count conflate-count)
		    (when *backtrace-do-fresh-lines*
		      (fresh-line))
		    (cond
		     ((plusp count)
		      (write-string " <")
		      (if (plusp conflate-count)
			  (write conflate-count :base 10 :radix nil)
			(write-string "="))
		      (write-char #\space))
		     (t (format t "~& |= ")))
		    (when print-returns
		      (format t "{< ~D}" (stack-frame-call-site stack frame)))
		    (when *backtrace-print-frames*
		      (format t "#x~X " frame))))
	     (handler-case
		 (typecase funobj
		   ((eql 0)
		    (let ((eip (dit-frame-ref stack frame :eip :unsigned-byte32))
			  (casf (dit-frame-casf stack frame)))
		      (multiple-value-bind (function-name code-vector-offset)
			  (let ((casf-funobj (stack-frame-funobj stack casf)))
			    (cond
			     ((eq 0 casf-funobj)
			      (values 'default-interrupt-trampoline
				      (code-vector-offset (symbol-value 'default-interrupt-trampoline)
							  eip)))
			     ((not (typep casf-funobj 'function))
			      ;; Hm.. very suspicius
			      (warn "Weird frame ~S" frame)
			      (values nil))
			     (t (let ((x (code-vector-offset (funobj-code-vector casf-funobj) eip)))
				  (cond
				   ((not (eq nil x))
				    (values (funobj-name casf-funobj) x))
				   ((not (logbitp 10 (dit-frame-ref stack frame :eflags :unsigned-byte16)))
				    (let ((funobj2 (dit-frame-ref stack frame :esi :lisp)))
				      (or (when (typep funobj2 'function)
					    (let ((x (code-vector-offset (funobj-code-vector funobj2) eip)))
					      (when x
						(values (funobj-name funobj2) x))))
					  (find-primitive-code-vector-by-eip eip)))))))))
			;; (setf next-frame (dit-frame-casf stack frame))
			(if (and conflate-interrupts conflate
				 ;; When the interrupted function has a stack-frame, conflate it.
				 (typep funobj 'function)
				 (= 1 (ldb (byte 1 5) (funobj-debug-info funobj))))
			    (incf conflate-count)
			  (progn
			    (incf count)
			    (print-leadin stack frame count conflate-count)
			    (setf conflate-count 0)
			    (let ((exception (dit-frame-ref stack frame :exception-vector :unsigned-byte32)))
			      (if function-name
				  (format t "DIT exception ~D in ~W at PC offset ~D."
					  exception
					  function-name
					  code-vector-offset)
				(format t "DIT exception ~D at EIP=~S with ESI=~S."
					exception
					eip
					(dit-frame-ref stack frame :esi :unsigned-byte32)))))))))
		   (function
		    (let ((name (funobj-name funobj)))
		      (cond
		       ((and conflate (member name *backtrace-conflate-names* :test #'equal))
			(incf conflate-count))
		       (t (incf count)
			  #+ignore (when (and *backtrace-stack-frame-barrier*
					      (<= *backtrace-stack-frame-barrier* stack-frame))
				     (write-string " --|")
				     (return))
			  (unless (or (not (integerp length))
				      (< count length))
			    (write-string " ...")
			    (return))
			  (print-leadin stack frame count conflate-count)
			  (setf conflate-count 0)
			  (write-char #\()
			  (let* ((numargs (stack-frame-numargs stack frame))
				 (map (and funobj (funobj-stack-frame-map funobj numargs))))
			    (cond
			     ((and (car map) (eq name 'unbound-function))
			      (let ((real-name (stack-frame-ref stack frame (car map))))
				(format t "{unbound ~S}" real-name)))
			     ((and (car map)
				   (member name +backtrace-gf-discriminatior-functions+))
			      (let ((gf (stack-frame-ref stack frame (car map))))
				(cond
				 ((typep gf 'muerte::standard-gf-instance)
				  (format t "{gf ~S}" (funobj-name gf)))
				 (t (write-string "[not a gf??]")))
				(safe-print-stack-frame-arglist stack frame map :numargs numargs)))
			     (t (write name)
				(safe-print-stack-frame-arglist stack frame map
								:numargs numargs
								:edx-p (eq 'muerte::&edx
									   (car (funobj-lambda-list funobj)))))))
			  (write-char #\))
			  (when (and (symbolp name)
				     (string= name 'toplevel-function))
			    (write-char #\.)
			    (return))
			  (write-char #\newline)))))
		   (t (print-leadin stack frame count conflate-count)
		      (format t "?: ~Z" funobj)))
	       (serious-condition (c)
		 (let ((*print-safely* t))
		   (format t " - Backtracing error at ~S funobj ~S: ~A"
			   frame
			   (stack-frame-funobj nil frame)
			   c)))))
	until (zerop (stack-frame-uplink stack frame))))
  (values))

(defun locate-function (instruction-location)
  "Try to find a function whose code-vector matches instruction-location, or just a code-vector."
  (check-type instruction-location fixnum)
  (labels ((match-funobj (function instruction-location &optional (limit 5))
	     (cond
	      ((location-in-code-vector-p%unsafe (funobj-code-vector function)
						 instruction-location)
	       function)
	      ((not (plusp limit))
	       nil)			; recurse no more.
	      ;; Search for a local function.
	      ((loop for i from (funobj-num-jumpers function) below (funobj-num-constants function)
		   as x = (funobj-constant-ref function i)
		   thereis (and (typep x 'function)
				(match-funobj x instruction-location (1- limit)))))
	      ;; Search a GF's method functions.
	      ((when (typep function 'generic-function)
		 (loop for m in (generic-function-methods function)
		     thereis (match-funobj (method-function m) instruction-location (1- limit))))))))
    (or (loop for (slot-name type) in (slot-value (class-of (current-run-time-context)) 'slot-map)
	    do (when (and (eq type 'code-vector-word)
			  (location-in-object-p (%run-time-context-slot nil slot-name)
						instruction-location))
		 (return (values slot-name :run-time-context))))
	(with-hash-table-iterator (hashis *setf-namespace*)
	  (do () (nil)
	    (multiple-value-bind (morep setf-name symbol)
		(hashis)
	      (declare (ignore setf-name))
	      (cond
	       ((not morep)
		(return nil))
	       ((fboundp symbol)
		(let ((it (match-funobj (symbol-function symbol) instruction-location)))
		  (when it (return it))))))))
	(do-all-symbols (symbol)
	  (when (fboundp symbol)
	    (let ((it (match-funobj (symbol-function symbol) instruction-location)))
	      (when it (return it))))
	  (when (and (boundp symbol)
		     (typep (symbol-value symbol) 'code-vector)
		     (location-in-code-vector-p%unsafe (symbol-value symbol) instruction-location))
	    (return (values symbol :symbol-value)))))))

