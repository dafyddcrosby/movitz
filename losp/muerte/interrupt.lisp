;;;;------------------------------------------------------------------
;;;; 
;;;;    Copyright (C) 2003-2004, 
;;;;    Department of Computer Science, University of Tromso, Norway.
;;;; 
;;;;    For distribution policy, see the accompanying file COPYING.
;;;; 
;;;; Filename:      interrupt.lisp
;;;; Description:   
;;;; Author:        Frode Vatvedt Fjeld <frodef@acm.org>
;;;; Created at:    Wed Apr  7 01:50:03 2004
;;;;                
;;;; $Id: interrupt.lisp,v 1.1 2004/04/07 00:12:23 ffjeld Exp $
;;;;                
;;;;------------------------------------------------------------------

(in-package #:muerte)

(provide :muerte/interrupt)

(defmacro stack-word (offset)
  `(with-inline-assembly (:returns :eax)
     (:movl (:esp ,(* 4 offset)) :eax)))

(define-compiler-macro int-frame-index (&whole form name &environment env)
  (let ((name (and (movitz:movitz-constantp name env)
		   (movitz:movitz-eval name env))))
    (if (not name)
	form
      (- 5 (position name
		     '(nil :eflags :eip :error-code :exception :ebp nil
		       :ecx :eax :edx :ebx :esi :edi))))))

(defun int-frame-index (name)
  (- 5 (position name
		 '(nil :eflags :eip :error-code :exception :ebp nil
		   :ecx :eax :edx :ebx :esi :edi))))

(define-compiler-macro int-frame-ref (&whole form frame reg type &optional (offset 0) &environment env)
  `(memref ,frame (+ (* 4 (int-frame-index ,reg)) ,offset) 0 ,type))

(defun int-frame-ref (frame reg type &optional (offset 0))
  (int-frame-ref frame reg type offset))

(defun (setf int-frame-ref) (x frame reg type)
  (setf (memref frame (* 4 (int-frame-index reg)) 0 type) x))

(define-primitive-function default-interrupt-trampoline ()
  "Default first-stage interrupt handler."
  #.(cl:list* 'with-inline-assembly '(:returns :nothing)
	      (cl:loop :for i :from 0 :to movitz::+idt-size+
		:append (cl:if (cl:member i '(8 10 11 12 13 14 17))
			    `(((5) :pushl ,i)
			      ((5) :jmp 'ok))
			  `(((2) :pushl 0) ; replace Error Code
			    ((2) :pushl ,i)
			    ((1) :nop)
			    ((5) :jmp 'ok)))))
  (with-inline-assembly (:returns :multiple-values)
   ok
    ;; Stack:
    ;; 20: Interruptee EFLAGS (later EIP)
    ;; 16: Interruptee CS     (later EFLAGS)
    ;; 12: Interruptee EIP
    ;;  8: Error code
    ;;  4: Exception number
    ;;  0: EBP
    (:pushl :ebp)
    (:movl :esp :ebp)
    (:pushl 0)				; 0 means default-interrupt-trampoline frame
    (:pushl :ecx)			; -8
    (:pushl :eax)			; -12
    (:pushl :edx)			; -16
    (:pushl :ebx)			; -20
    (:pushl :esi)			; -24
    (:pushl :edi)			; -28

    ;; rearrange stack for return
    (:movl (:ebp 12) :eax)		; load return address
    (:movl (:ebp 20) :ebx)		; load EFLAGS
    (:movl :ebx (:ebp 16))		; EFLAGS at next-to-bottom of stack
    (:movl :eax (:ebp 20))		; return address at bottom of stack

    (:xorl :eax :eax)			; Ensure safe value
    (:xorl :edx :edx)			; Ensure safe value

    (:movl ':nil-value :edi)		; We want NIL!
    
    (:pushl (:ebp 16))			; EFLAGS
    (:pushl :cs)			; push CS
    (:call (:pc+ 0))			; push EIP.
    ;; Now add a few bytes to the on-stack EIP so the iret goes to
    ;; *DEST* below.
    ((4) :addl 5 (:esp))		; 4 bytes
    ((1) :iretd)			; 1 byte
    
    ;; *DEST* iret branches to here.
    ;; we're now in the context of the interruptee.

    ;; Save/push thread-local values
    (:locally (:movl (:edi (:edi-offset num-values)) :ecx))
    (:jecxz 'push-values-done)
    (:leal (:edi #.(movitz::global-constant-offset 'values)) :eax)
   push-values-loop
    (:locally (:pushl (:eax)))
    (:addl 4 :eax)
    (:subl 1 :ecx)
    (:jnz 'push-values-loop)
   push-values-done
    (:locally (:pushl (:edi (:edi-offset num-values))))
    
    ;; call handler
    (:movl (:ebp 4) :ebx)		; interrupt number into EBX
    (:locally (:movl (:edi (:edi-offset interrupt-handlers)) :eax))
    (:movl (:eax 2 (:ebx 4)) :eax)	; symbol at (aref EBX interrupt-handlers) into :esi
    (:leal (:eax -7) :ecx)
    (:testb 7 :cl)
    (:jnz 'skip-interrupt-handler)	; if it's not a symbol, never mind.
    (:movl (:eax #.(movitz::slot-offset 'movitz::movitz-symbol 'movitz::function-value))
	   :esi)			; load new funobj from symbol into ESI
    (:movl :ebp :ebx)			; pass INT-frame as arg1
    ;; (:movl :ebx (:ebp -4))		; put INT-frame as our fake stack-frame's funobj.
    (:movl (:ebp 4) :eax)		; pass interrupt number as arg 0.
    (:shll #.movitz::+movitz-fixnum-shift+ :eax)
    (:call (:esi #.(movitz::slot-offset 'movitz::movitz-funobj 'movitz::code-vector%2op)))

   skip-interrupt-handler
    ;; Restore thread-local values
    (:popl :ecx)
    (:locally (:movl :ecx (:edi (:edi-offset num-values))))
    (:jecxz 'pop-values-done)
   pop-values-loop
    ;; ((:fs-override) :popl (:edi #.(movitz::global-constant-offset 'values) (:ecx 4) -4))
    (:locally (:popl (:edi (:edi-offset values) (:ecx 4) -4)))
    (:subl 1 :ecx)
    (:jnz 'pop-values-loop)
   pop-values-done

    (:movl (:ebp -28) :edi)
    (:movl (:ebp -24) :esi)
    (:movl (:ebp -20) :ebx)
    (:movl (:ebp -16) :edx)
    (:movl (:ebp -12) :eax)
    (:movl (:ebp -8)  :ecx)

    (:leave)
    (:addl 12 :esp)
    (:popfl)				; pop EFLAGS
    (:ret)))				; pop EIP

(defvar *last-interrupt-frame* nil)

(defun interrupt-default-handler (number int-frame)
  (declare (without-check-stack-limit))
  (macrolet ((@ (fixnum-address &optional (type :lisp))
	       "Dereference the fixnum-address."
	       `(memref ,fixnum-address 0 0 ,type)))
    (let (($eip (+ int-frame (int-frame-index :eip)))
	  ($eax (+ int-frame (int-frame-index :eax)))
	  ($ebx (+ int-frame (int-frame-index :ebx)))
	  ($ecx (+ int-frame (int-frame-index :ecx)))
	  ($edx (+ int-frame (int-frame-index :edx)))
	  ($esi (+ int-frame (int-frame-index :esi)))
	  (*last-interrupt-frame* int-frame))
      (block nil
	(case number
	  (0 (error "Division by zero."))
	  (3 (break "Break instruction at ~@Z." $eip))
	  (6 (error "Illegal instruction at ~@Z." $eip))
	  (13 (error "General protection error. EIP=~@Z, error-code: #x~X, EAX: ~@Z, EBX: ~@Z, ECX: ~@Z"
		     $eip
		     (int-frame-ref int-frame :error-code :unsigned-byte32)
		     $eax $ebx $ecx))
	  (68 (warn "EIP: ~@Z EAX: ~@Z EBX: ~@Z  ECX: ~@Z EDX: ~@Z"
		    $eip $eax $ebx $ecx $edx)
	      (dotimes (i 100000)
		(with-inline-assembly (:returns :nothing) (:nop))))
	  (67 (backtrace :fresh-lines nil :length 6)
	      (dotimes (i 100000)
		(with-inline-assembly (:returns :nothing) (:nop))))
	  (66 (error "Unspecified type error at ~@Z in ~S with EAX=~@Z, ECX=~@Z."
		     $eip (@ (+ int-frame (int-frame-index :esi)))
		     $eax $ecx))
	  (62 (error "Trying to save too many values: ~@Z." $ecx))
	  ((5 55)
	   (let* ((stack (%run-time-context-slot 'movitz::stack-vector))
		  (old-bottom (stack-bottom))
		  (real-bottom (- (object-location stack) 2))
		  (stack-left (- old-bottom real-bottom))
		  (new-bottom (cond
			       ((< stack-left 10)
				(princ "Halting CPU due to stack exhaustion.")
				(halt-cpu))
			       ((<= stack-left 256)
				(format *debug-io*
					"~&This is your LAST chance to pop off stack.~%")
				real-bottom)
			       (t (+ real-bottom (truncate stack-left 2)))))) ; Cushion the fall..
	     (unwind-protect
		 (progn
		   (setf (stack-bottom) new-bottom)
		   (format *debug-io* "~&Stack-warning: Bumped stack-bottom by ~D to #x~X.~%"
			   (- old-bottom new-bottom)
			   new-bottom)
		   (break "Stack overload exception ~D at ESP=~@Z with bottom #x~X."
			  number
			  (+ int-frame (int-frame-index :ebp))
			  old-bottom))
	       (format *debug-io* "~&Stack-warning: Resetting stack-bottom to #x~X.~%"
		       old-bottom)
	       (setf (stack-bottom) old-bottom))))
	  (69
	   (error "Not a function: ~S" (@ $edx)))
	  (70
	   (error "[EIP=~@Z] Index ~@Z out of bounds ~@Z for ~S." $eip $ecx $ebx (@ $eax)))
	  (98
	   (let ((name (@ $ecx)))
	     (when (symbolp name)
	       (error 'undefined-function :name name))))
	  (99
	   (let ((name (@ $edx)))
	     (when (symbolp name)
	       (error 'unbound-variable :name name))))
	  ((100);; 101 102 103 104 105)
	   (let ((funobj (@ (+ int-frame (int-frame-index :esi))))
		 (code (int-frame-ref int-frame :ecx :unsigned-byte8)))
	     (error 'wrong-argument-count
		    :function funobj
		    :argument-count (if (logbitp 7 code)
					(ash (int-frame-ref int-frame :ecx :unsigned-byte32)
					     -24)
				      code))))
	  (108
	   (error 'throw-error :tag (@ $eax)))
	  (110
	   ;; (print-dynamic-context); what's this?
	   (throw :debugger nil))
	  (112
	   (let ((*error-no-condition-for-debugger* t)) ; no space..
	     (error "Out of memory. Please take out the garbage.")))
	  (t (funcall (if (< 16 number 50) #'warn #'error)
		      "Exception occurred: ~D, EIP: ~@Z, EAX: ~@Z, ECX: ~@Z, ESI: ~@Z"
		      number $eip $eax $ecx $esi)))
	nil))))


(defun interrupt-handler (n)
  (let ((vector (load-global-constant interrupt-handlers)))
    (svref vector n)))

(defun (setf interrupt-handler) (handler n)
  (check-type handler symbol)
  (assert (fboundp handler))
  (let ((vector (load-global-constant interrupt-handlers)))
    (setf (svref vector n) handler)))


(defun cli ()
  (with-inline-assembly (:returns :nothing)
    (:cli)))

(defun sti ()
  (with-inline-assembly (:returns :nothing)
    (:sti)))

(define-primitive-function primitive-software-interrupt ()
  "A primitive code-vector that generates software interrupts."
  (macrolet ((make-software-interrupt-code ()
	       (cons 'progn
		     (loop for vector from 0 to 255
			 collect `(with-inline-assembly (:returns :nothing)
				    ;; Each code-entry is 2+1+1=4 bytes.
				    ((2) :int ,vector)
				    ((1) :ret)
				    ((1) :nop))))))
    (make-software-interrupt-code)))

(defun software-interrupt (interrupt-vector &optional (eax 0) (ebx 0))
  "Generate software-interrupt number <interrupt-vector>."
  ;; The problem now is that the x86 INT instruction only takes an
  ;; immediate argument.
  ;; Hence the primitive-function primitive-software-interrupt.
  (check-type interrupt-vector (unsigned-byte 8))
  (let ((code-vector (symbol-value 'primitive-software-interrupt)))
    (check-type code-vector vector)
    (with-inline-assembly-case ()
      (do-case (t :nothing)
	(:compile-two-forms (:ecx :edx) interrupt-vector code-vector)
	(:leal (:edx :ecx 2) :ecx)
	(:compile-two-forms (:eax :ebx) eax ebx)
	(:shrl 2 :eax)
	(:shrl 2 :ebx)
	(:call :ecx)))))
