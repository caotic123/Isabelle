; COMMAND-LINE: --produce-abducts
; SCRUBBER: grep -v -E '(\(define-fun)'
; EXIT: 0

; Test that :grammar-assertions restricts which symbols appear in the grammar

(set-logic QF_LIA)
(declare-fun x () Int)
(declare-fun y () Int)

; Name the assertions so we can reference them
(assert (! (> x 0) :named ax1))
(assert (! (> y 0) :named ax2))

; Get abduct using only ax1 for grammar generation
; The resulting abduct should only use x, not y
; Goal requires x + y > 100, so we need a stronger condition
(get-abduct abd (> (+ x y) 100) :grammar-assertions (ax1))
