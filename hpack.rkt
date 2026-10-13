#lang racket/base

;; RFC 7541 HPACK: integer and string-literal primitives, static and
;; dynamic table indexing, and header-list encode/decode.  The encoder
;; uses the simplest legal strategy — indexed for exact static-table
;; matches, literal without indexing for everything else — so its
;; state stays appendix-free; the decoder implements the full spec.

(require racket/contract
         racket/list
         racket/format
         "huffman.rkt"
         "hpack-tables.rkt")

;; ---- integers (§5.1) -----------------------------------------------------------

;; Encode value with a prefix-bits-wide field in the first byte; the
;; high bits of the first byte carry prefix.
(define (hpack-encode-integer value prefix-bits)
  (define max-prefix (sub1 (arithmetic-shift 1 prefix-bits)))
  (if (< value max-prefix)
      (bytes value)
      (let ([rest (- value max-prefix)])
        (let loop ([v rest] [acc (list max-prefix)])
          (if (zero? v)
              (list->bytes (reverse acc))
              (let ([b (remainder v 128)])
                (loop (quotient v 128)
                      (cons (if (zero? (quotient v 128)) b (bitwise-ior b #x80))
                            acc))))))))

;; Decode from bstr at byte offset pos with prefix-bits-wide field.
;; Returns (values value next-pos).
(define (hpack-decode-integer bstr pos prefix-bits)
  (define max-prefix (sub1 (arithmetic-shift 1 prefix-bits)))
  (define first (bytes-ref bstr pos))
  (define mask (bitwise-and first max-prefix))
  (if (< mask max-prefix)
      (values mask (add1 pos))
      (let loop ([v mask] [m 0] [p (add1 pos)])
        (define b (bytes-ref bstr p))
        (define v2 (+ v (* (bitwise-and b 127) (arithmetic-shift 1 m))))
        (if (zero? (bitwise-and b #x80))
            (values v2 (add1 p))
            (loop v2 (+ m 7) (add1 p))))))

;; ---- string literals (§5.2) ------------------------------------------------------

(define (hpack-encode-string s)
  (define raw-len (string-utf-8-length s))
  ;; the Huffman table covers ASCII only; non-ASCII goes out literal
  (define ascii? (for/and ([ch (in-string s)]) (< (char->integer ch) 256)))
  (define use-huffman?
    (and ascii? (<= (bytes-length (huffman-encode s)) raw-len)))
  (define len (if use-huffman? (bytes-length (huffman-encode s)) raw-len))
  (define int-bytes (hpack-encode-integer len 7))
  ;; H flag lives in the top bit of the first byte
  (define first-byte (if use-huffman?
                         (bitwise-ior (bytes-ref int-bytes 0) #x80)
                         (bytes-ref int-bytes 0)))
  (bytes-append (bytes first-byte)
                (subbytes int-bytes 1)
                (if use-huffman? (huffman-encode s) (string->bytes/utf-8 s))))

(define (hpack-decode-string bstr pos)
  (define-values (len next) (hpack-decode-integer bstr pos 7))
  (define huffman? (not (zero? (bitwise-and (bytes-ref bstr pos) #x80))))
  (if huffman?
      (values (huffman-decode (subbytes bstr next (+ next len))) (+ next len))
      (values (bytes->string/utf-8 (subbytes bstr next (+ next len))) (+ next len))))

;; ---- tables ------------------------------------------------------------------------

;; static-table entries are 1-based: index i → (list-ref static-table (sub1 i))

(struct hpack-ctx (max-size-box entries) #:mutable #:reflection-name 'hpack-ctx)

(define (make-hpack-ctx max-size)
  (hpack-ctx (box max-size) '()))

(define (hpack-ctx-size ctx)
  (for/sum ([e (in-list (hpack-ctx-entries ctx))])
    (entry-size e)))

(define (entry-size e)
  (+ (string-utf-8-length (car e)) (string-utf-8-length (cdr e)) 32))

(define (entry-at ctx idx)  ; idx is 1-based across static-then-dynamic
  (if (<= idx 61)
      (list-ref static-table (sub1 idx))
      (let ([dynamic-idx (- idx 62)])  ; dynamic newest has idx 62
        (list-ref (hpack-ctx-entries ctx) dynamic-idx))))

;; dynamic-table insert: newest first; evict oldest while over max
(define (dynamic-insert! ctx e)
  (set-hpack-ctx-entries! ctx (cons e (hpack-ctx-entries ctx)))
  (let loop ()
    (when (> (hpack-ctx-size ctx) (unbox (hpack-ctx-max-size-box ctx)))
      (define es (hpack-ctx-entries ctx))
      (when (pair? es)
        (set-hpack-ctx-entries! ctx (reverse (cdr (reverse es))))
        (loop)))))

(define (dynamic-resize! ctx new-max)
  (set-box! (hpack-ctx-max-size-box ctx) new-max)
  (let loop ()
    (when (> (hpack-ctx-size ctx) new-max)
      (define es (hpack-ctx-entries ctx))
      (when (pair? es)
        (set-hpack-ctx-entries! ctx (reverse (cdr (reverse es))))
        (loop)))))

;; ---- decode (§6) ---------------------------------------------------------------------

(define (hpack-decode-headers ctx bstr)
  (let loop ([pos 0] [acc '()])
    (cond
      [(>= pos (bytes-length bstr)) (reverse acc)]
      [else
       (define first (bytes-ref bstr pos))
       (cond
          [(not (zero? (bitwise-and first #x80)))           ; 1xxxxxxx: indexed
           (define-values (idx next) (hpack-decode-integer bstr pos 7))
           (when (zero? idx) (raise-hpack "indexed field with index 0"))
           (define e (entry-at ctx idx))
           (loop next (cons (cons (car e) (cdr e)) acc))]
          [(not (zero? (bitwise-and first #xC0)))           ; 01xxxxxx: literal + incremental indexing
           (define-values (pair next) (decode-literal ctx bstr pos 6))
           (dynamic-insert! ctx pair)
           (loop next (cons pair acc))]
          [(not (zero? (bitwise-and first #xE0)))           ; 001xxxxx: dynamic table size update
           (define-values (new-max next) (hpack-decode-integer bstr pos 5))
           (dynamic-resize! ctx new-max)
           (loop next acc)]
          [(not (zero? (bitwise-and first #x10)))           ; 0001xxxx: never indexed
           (define-values (pair next) (decode-literal ctx bstr pos 4))
           (loop next (cons pair acc))]
          [else                                             ; 0000xxxx: literal without indexing
           (define-values (pair next) (decode-literal ctx bstr pos 4))
           (loop next (cons pair acc))])])))

;; name reference: index 0 = literal name follows; else static/dynamic index
(define (decode-literal ctx bstr pos prefix-bits)
  (define-values (idx next) (hpack-decode-integer bstr pos prefix-bits))
  (define-values (name pos2)
    (if (zero? idx)
        (hpack-decode-string bstr next)
        (let ([e (entry-at ctx idx)])
          (values (car e) next))))
  (define-values (value pos3) (hpack-decode-string bstr pos2))
  (values (cons name value) pos3))

(define (raise-hpack why)
  (raise-argument-error 'hpack-decode-headers (format "valid HPACK data (~a)" why) 'input))

;; ---- encode ---------------------------------------------------------------------------

;; Strategy: exact (name,value) static match → indexed; otherwise
;; literal without indexing, name indexed when a static name matches.
;; Encoding decisions consult the static table only (encoder and
;; decoder contexts stay independent); the decoder-side context still
;; tracks inserts and size updates for the peer's bytes.
(define (hpack-encode-headers ctx headers)
  (apply
   bytes-append
   (for/list ([e (in-list headers)])
     (define idx (static-index e))
     (cond
       [idx (bytes (+ #x80 idx))]
       [(static-name-index (car e))
        => (λ (nidx)
             ;; 0000xxxx first byte carries the 4-bit name index
             (bytes-append (hpack-encode-integer nidx 4)
                           (hpack-encode-string (cdr e))))]
       [else
        (bytes-append (bytes #x00)
                      (hpack-encode-string (car e))
                      (hpack-encode-string (cdr e)))]))))

(define (static-index e)
  (for/first ([i (in-naturals 1)]
              [entry (in-list static-table)]
              #:when (and (equal? (car entry) (car e)) (equal? (cdr entry) (cdr e))))
    i))

(define (static-name-index name)
  (for/first ([i (in-naturals 1)]
              [entry (in-list static-table)]
              #:when (equal? (car entry) name))
    i))

(provide (contract-out
          [hpack-encode-integer (-> exact-nonnegative-integer? exact-integer? bytes?)]
          [hpack-decode-integer (-> bytes? exact-nonnegative-integer? exact-nonnegative-integer?
                                    (values exact-nonnegative-integer? exact-nonnegative-integer?))]
          [hpack-encode-string (-> string? bytes?)]
          [hpack-decode-string (-> bytes? exact-nonnegative-integer?
                                   (values string? exact-nonnegative-integer?))]
          [hpack-ctx? (-> any/c boolean?)]
          [make-hpack-ctx (-> exact-nonnegative-integer? hpack-ctx?)]
          [hpack-ctx-size (-> hpack-ctx? exact-nonnegative-integer?)]
          [hpack-decode-headers (-> hpack-ctx? bytes? (listof (cons/c string? string?)))]
          [hpack-encode-headers (-> hpack-ctx? (listof (cons/c string? string?)) bytes?)]))

