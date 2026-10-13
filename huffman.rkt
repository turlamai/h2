#lang racket/base

;; RFC 7541 §5.2 Huffman coding, both directions.  The code table is
;; generated from the RFC (hpack-tables.rkt).  Encoding pads with 1
;; bits to the next byte boundary (never a whole byte); decoding
;; rejects any padding that is not a prefix of EOS.

(require racket/contract
         racket/list
         "hpack-tables.rkt")

(provide (contract-out
          [huffman-encode (-> string? bytes?)]
          [huffman-decode (-> bytes? string?)]
          [huffman-encoded-length-bits (-> string? exact-nonnegative-integer?)]))

;; symbol -> (code . bit-length); index 0 is unused, 256 is EOS
(define code-table huffman-codes)

;; ---- encode ------------------------------------------------------------------

(define (sym-entry sym)
  (define e (and (<= 0 sym 256) (vector-ref code-table sym)))
  (unless e
    (raise-argument-error 'huffman-encode "a Huffman-encodable symbol" sym))
  e)

(define (huffman-encoded-length-bits s)
  (for/sum ([ch (in-string s)])
    (cdr (sym-entry (char->integer ch)))))

(define (huffman-encode s)
  (define-values (bits len)
    (for/fold ([bits 0] [len 0]) ([ch (in-string s)])
      (define e (sym-entry (char->integer ch)))
      (values (+ (* bits (arithmetic-shift 1 (cdr e))) (car e))
              (+ len (cdr e)))))
  (define rem (remainder len 8))
  (define pad (if (= rem 0) 0 (- 8 rem)))
  (define padded (+ (* bits (arithmetic-shift 1 pad))
                    (sub1 (arithmetic-shift 1 pad))))   ; pad ones
  (define total-bytes (quotient (+ len pad) 8))
  ;; wire order is MSB first: byte k holds bits [8k, 8k+8) from the top
  (let loop ([k 0] [acc '()])
    (if (= k total-bytes)
        (list->bytes (reverse acc))
        (loop (add1 k)
              (cons (bitwise-and (arithmetic-shift padded (* -8 (- total-bytes 1 k))) #xFF)
                    acc)))))

;; ---- decode ------------------------------------------------------------------

;; Per-length code -> symbol maps; canonical codes mean a decoded
;; prefix either lands in exactly one length's table or is not (yet) a
;; symbol.
(define decode-index
  (let ([idx (make-vector 31 #f)])
    (for ([sym (in-range 257)])
      (define e (vector-ref code-table sym))
      (when e
        (define len (cdr e))
        (define tbl (or (vector-ref idx len) (make-hash)))
        (hash-set! tbl (car e) sym)
        (vector-set! idx len tbl)))
    idx))

(define (huffman-decode bstr)
  (define out (open-output-string))
  (define total (* 8 (bytes-length bstr)))
  (let loop ([pos 0] [code 0] [len 0])
    (cond
      [(= pos total)
       ;; padding: the bits since the last symbol must be all 1s and
       ;; shorter than 8 bits — but there may be none at all when the
       ;; encoded length lands exactly on a byte boundary
       (unless (< len 8) (raise-huffman "padding longer than 7 bits"))
       (unless (or (= len 0) (bits-all-ones bstr (- pos len)))
         (raise-huffman "padding is not a prefix of EOS"))
       (get-output-string out)]
      [else
       (define code2 (+ (* code 2) (bit-at bstr pos)))
       (define len2 (add1 len))
       (define tbl (vector-ref decode-index len2))
       (define sym (and tbl (hash-ref tbl code2 #f)))
       (cond
         [(not sym)
          (when (= len2 30) (raise-huffman "invalid Huffman code"))
          (loop (add1 pos) code2 len2)]
         [(= sym 256) (raise-huffman "EOS symbol in the middle of a string")]
         [else
          (write-char (integer->char sym) out)
          (loop (add1 pos) 0 0)])])))

(define (raise-huffman why)
  (raise-argument-error 'huffman-decode (format "valid Huffman data (~a)" why) 'input))

(define (bit-at bstr bit-pos)
  (define byte (bytes-ref bstr (quotient bit-pos 8)))
  ;; MSB-first: bit i of a byte is (byte >> (7 - i mod 8)) & 1 — the
  ;; shift amount is negative (arithmetic-shift positive = left)
  (bitwise-and (arithmetic-shift byte (- (remainder bit-pos 8) 7)) 1))

(define (bits-all-ones bstr from-bit)
  (let loop ([i from-bit])
    (or (>= i (* 8 (bytes-length bstr)))
        (and (= (bit-at bstr i) 1) (loop (add1 i))))))
