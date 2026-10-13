#lang racket/base

;; RFC 7540 §4/§6: the 9-byte frame header, all ten frame types, and
;; typed helpers for the payloads this family needs (SETTINGS, PING,
;; GOAWAY, WINDOW_UPDATE, RST_STREAM, HEADERS with padding/priority
;; stripping).  Pure bytes in, structures out; connections live
;; elsewhere.

(require racket/contract
         racket/list
         racket/match)

(provide (contract-out
          [struct frame ([length exact-nonnegative-integer?]
                         [type exact-nonnegative-integer?]
                         [flags exact-nonnegative-integer?]
                         [stream-id exact-nonnegative-integer?]
                         [payload bytes?])]
          [frame->bytes (-> frame? bytes?)]
          [bytes->frame (-> bytes? exact-nonnegative-integer? (values frame? exact-nonnegative-integer?))]
          [frames->bytes (-> (listof frame?) bytes?)]
          [connection-preface bytes?]
          [frame-type/c contract?]
          [data-frame frame-type/c] [headers-frame* frame-type/c]
          [priority-frame frame-type/c] [rst-stream-frame frame-type/c]
          [settings-frame frame-type/c] [push-promise-frame frame-type/c]
          [ping-frame frame-type/c] [goaway-frame frame-type/c]
          [window-update-frame frame-type/c] [continuation-frame frame-type/c]
          [make-settings-frame (-> (listof (cons/c exact-nonnegative-integer? exact-nonnegative-integer?)) frame?)]
          [settings-payload->list (-> bytes? (listof (cons/c exact-nonnegative-integer? exact-nonnegative-integer?)))]
          [make-ping-frame (-> boolean? exact-nonnegative-integer? frame?)]
          [make-goaway-frame (-> exact-nonnegative-integer? exact-nonnegative-integer? bytes? frame?)]
          [make-window-update-frame (-> exact-nonnegative-integer? exact-nonnegative-integer? frame?)]
          [make-rst-stream-frame (-> exact-nonnegative-integer? exact-nonnegative-integer? frame?)]
          [make-headers-frame (->* (exact-nonnegative-integer? bytes?)
                                   (#:end-stream boolean?
                                    #:pad-length (or/c exact-nonnegative-integer? #f))
                                   frame?)]
          [headers-block->bytes (-> bytes? bytes?)]
          [error-code/c contract?]
          [no-error error-code/c] [protocol-error error-code/c]
          [internal-error error-code/c] [flow-control-error error-code/c]))

;; ---- frame types (§6) ------------------------------------------------------------

(define data-frame 0)
(define headers-frame* 1)
(define priority-frame 2)
(define rst-stream-frame 3)
(define settings-frame 4)
(define push-promise-frame 5)
(define ping-frame 6)
(define goaway-frame 7)
(define window-update-frame 8)
(define continuation-frame 9)

(define frame-type/c (integer-in 0 9))

;; error codes (§7)
(define no-error 0)
(define protocol-error 1)
(define internal-error 2)
(define flow-control-error 3)
(define error-code/c (integer-in 0 #xFFFFFFFF))

(struct frame (length type flags stream-id payload) #:transparent)

;; the fixed client connection preface (§3.5)
(define connection-preface #"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")

;; ---- header codec ------------------------------------------------------------------

(define (uint24 b i)
  (+ (* (bytes-ref b i) 65536)
     (* (bytes-ref b (add1 i)) 256)
     (bytes-ref b (+ i 2))))

(define (set-uint24! b i v)
  (bytes-set! b i (bitwise-and (arithmetic-shift v -16) #xFF))
  (bytes-set! b (add1 i) (bitwise-and (arithmetic-shift v -8) #xFF))
  (bytes-set! b (+ i 2) (bitwise-and v #xFF)))

(define (uint32 b i)
  (bitwise-and
   (+ (* (bytes-ref b i) 16777216)
      (* (bytes-ref b (add1 i)) 65536)
      (* (bytes-ref b (+ i 2)) 256)
      (bytes-ref b (+ i 3)))
   #xFFFFFFFF))

(define (set-uint32! b i v)
  (bytes-set! b i (bitwise-and (arithmetic-shift v -24) #xFF))
  (bytes-set! b (add1 i) (bitwise-and (arithmetic-shift v -16) #xFF))
  (bytes-set! b (+ i 2) (bitwise-and (arithmetic-shift v -8) #xFF))
  (bytes-set! b (+ i 3) (bitwise-and v #xFF)))

(define (frame->bytes f)
  (unless (<= (bytes-length (frame-payload f)) #xFFFFFF)
    (raise-argument-error 'frame->bytes "a payload of at most 16777215 bytes" f))
  (define out (make-bytes (+ 9 (bytes-length (frame-payload f)))))
  (set-uint24! out 0 (bytes-length (frame-payload f)))
  (bytes-set! out 3 (frame-type f))
  (bytes-set! out 4 (frame-flags f))
  ;; reserved bit stays 0; stream id is 31 bits
  (set-uint32! out 5 (bitwise-and (frame-stream-id f) #x7FFFFFFF))
  (bytes-copy! out 9 (frame-payload f))
  out)

;; Decode one frame at pos; returns (values frame next-pos).  Requires
;; the caller to have buffered length+9 bytes.
(define (bytes->frame bstr pos)
  (define len (uint24 bstr pos))
  (define type (bytes-ref bstr (+ pos 3)))
  (define flags (bytes-ref bstr (+ pos 4)))
  (define sid (uint32 bstr (+ pos 5)))
  (define payload (subbytes bstr (+ pos 9) (+ pos 9 len)))
  (values (frame len type flags sid payload)
          (+ pos 9 len)))

(define (frames->bytes fs)
  (apply bytes-append (map frame->bytes fs)))

;; ---- typed payload helpers --------------------------------------------------------

(define (make-settings-frame pairs)
  (define payload (make-bytes (* 6 (length pairs))))
  (for ([p (in-list pairs)] [i (in-naturals)])
    (set-uint16! payload (* i 6) (car p))
    (set-uint32! payload (+ (* i 6) 2) (cdr p)))
  (frame (bytes-length payload) settings-frame 0 0 payload))

(define set-uint16!
  (λ (b i v)
    (bytes-set! b i (bitwise-and (arithmetic-shift v -8) #xFF))
    (bytes-set! b (add1 i) (bitwise-and v #xFF))))

(define (settings-payload->list payload)
  (for/list ([i (in-range (quotient (bytes-length payload) 6))])
    (cons (+ (* (bytes-ref payload (* i 6)) 256)
             (bytes-ref payload (+ (* i 6) 1)))
          (uint32 payload (+ (* i 6) 2)))))

(define (make-ping-frame ack? opaque)
  (define payload (make-bytes 8))
  (set-uint32! payload 0 opaque)
  (frame 8 ping-frame (if ack? #x01 #x00) 0 payload))

(define (make-goaway-frame last-stream-id error-code debug-bytes)
  (define payload (make-bytes (+ 8 (bytes-length debug-bytes))))
  (set-uint32! payload 0 (bitwise-and last-stream-id #x7FFFFFFF))
  (set-uint32! payload 4 error-code)
  (bytes-copy! payload 8 debug-bytes)
  (frame (bytes-length payload) goaway-frame 0 0 payload))

(define (make-window-update-frame stream-id increment)
  (define payload (make-bytes 4))
  (set-uint32! payload 0 (bitwise-and increment #x7FFFFFFF))
  (frame 4 window-update-frame 0 (bitwise-and stream-id #x7FFFFFFF) payload))

(define (make-rst-stream-frame stream-id error-code)
  (define payload (make-bytes 4))
  (set-uint32! payload 0 error-code)
  (frame 4 rst-stream-frame 0 (bitwise-and stream-id #x7FFFFFFF) payload))

(define (make-headers-frame stream-id block
                            #:end-stream [end-stream #t]
                            #:pad-length [pad-length #f])
  (define padded? (and pad-length #t))
  (define payload
    (if padded?
        (let ([p (make-bytes (+ 1 (bytes-length block) pad-length))])
          (bytes-set! p 0 pad-length)
          (bytes-copy! p 1 block)
          p)
        block))
  (define flags
    (bitwise-ior (if end-stream #x01 0)          ; END_STREAM
                 (if padded? #x08 0)))           ; PADDED
  (frame (bytes-length payload) headers-frame* flags
         (bitwise-and stream-id #x7FFFFFFF) payload))

;; Strip padding from a HEADERS/DATA payload per PADDED flag handling;
;; returns the inner block.
(define (headers-block->bytes payload)
  (if (zero? (bytes-length payload))
      payload
      (let ([pad (bytes-ref payload 0)])
        (subbytes payload 1 (- (bytes-length payload) pad)))))
