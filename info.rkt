#lang info

(define collection "h2")
(define version "0.1")
(define deps '("base"))
(define build-deps '("scribble-lib" "racket-doc" "rackunit-lib"))
(define scribblings '(("scribblings/h2.scrbl" ())))
(define pkg-desc "HTTP/2 for Racket: RFC 7540 frames and RFC 7541 HPACK")
(define license 'MIT)
(define pkg-authors '(turinglambdaai))
(define test-omit-paths '("scribblings"))
