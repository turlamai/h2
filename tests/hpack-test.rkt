#lang racket/base

(require rackunit
         racket/list
         h2)

;; ---- RFC 7541 C.1 integer vectors ----------------------------------------

(test-case "integer representation (RFC 7541 C.1)"
  (check-equal? (hpack-encode-integer 10 5) (bytes #x0a))          ; C.1.1
  (check-equal? (hpack-encode-integer 1337 5) (bytes #x1f #x9a #x0a)) ; C.1.2
  (check-equal? (hpack-encode-integer 42 8) (bytes #x2a))          ; C.1.3
  (check-equal? (hpack-encode-integer 0 7) (bytes #x00))
  ;; decode returns the value and the next position
  (define-values (v next) (hpack-decode-integer (bytes #x1f #x9a #x0a) 0 5))
  (check-equal? v 1337)
  (check-equal? next 3)
  (define-values (v2 next2) (hpack-decode-integer (bytes #x0a) 0 5))
  (check-equal? v2 10)
  (check-equal? next2 1))

;; ---- RFC 7541 Huffman (C.4.1 / C.6.1 famous vector) ------------------------

(test-case "huffman encode/decode"
  (define encoded (huffman-encode "www.example.com"))
  (check-equal? encoded
                (bytes #xf1 #xe3 #xc2 #xe5 #xf2 #x3a #x6b #xa0 #xab #x90 #xf4 #xff))
  (check-equal? (huffman-decode encoded) "www.example.com")
  ;; short symbol, no padding-heavy tail
  (check-equal? (huffman-decode (huffman-encode "a")) "a")
  (check-equal? (huffman-decode (huffman-encode "custom-header")) "custom-header"))

;; ---- RFC 7541 C.6.1 first request (indexed + literal) ------------------------

(test-case "C.6.1 request header block decodes"
  (define ctx (make-hpack-ctx 4096))
  (define block
    (bytes #x82 #x86 #x84 #x41 #x0f
           #x77 #x77 #x77 #x2e #x65 #x78 #x61 #x6d #x70 #x6c #x65 #x2e #x63 #x6f #x6d))
  (define headers (hpack-decode-headers ctx block))
  (check-equal? headers
                '((":method" . "GET")
                  (":scheme" . "http")
                  (":path" . "/")
                  (":authority" . "www.example.com"))))

(test-case "literal without indexing (C.4.1 shape)"
  (define ctx (make-hpack-ctx 4096))
  (define block
    (bytes #x00 #x0a #x63 #x75 #x73 #x74 #x6f #x6d #x2d #x6b #x65 #x79
           #x0d #x63 #x75 #x73 #x74 #x6f #x6d #x2d #x68 #x65 #x61 #x64 #x65 #x72))
  (check-equal? (hpack-decode-headers ctx block)
                '(("custom-key" . "custom-header"))))

;; ---- encoder/decoder roundtrips -----------------------------------------------

(test-case "encode -> decode roundtrip"
  (define enc (make-hpack-ctx 4096))
  (define dec (make-hpack-ctx 4096))
  (define headers
    (list (cons ":method" "GET")
          (cons ":path" "/feed.xml")
          (cons "accept-encoding" "gzip")
          (cons "x-custom" "some value")))
  (define block (hpack-encode-headers enc headers))
  (check-equal? (hpack-decode-headers dec block) headers)
  ;; repeat: same block decodes again (encoder is stateless by strategy)
  (check-equal? (hpack-decode-headers dec block) headers))

(test-case "static-table exact matches become indexed bytes"
  ;; (:method GET) is static entry 2 -> one byte 0x82, same as the RFC
  (define enc (make-hpack-ctx 4096))
  (check-equal? (hpack-encode-headers enc (list (cons ":method" "GET")))
                (bytes #x82)))

;; ---- dynamic table ---------------------------------------------------------------

(test-case "decoder inserts and indexes dynamic entries"
  (define ctx (make-hpack-ctx 4096))
  (define block
    (bytes-append
     (bytes #x40)                                    ; literal + incremental indexing, name idx 0
     (hpack-encode-string "custom-key")
     (hpack-encode-string "custom-header")))
  (check-equal? (hpack-decode-headers ctx block) '(("custom-key" . "custom-header")))
  ;; the inserted entry is dynamic index 62
  (define replay (bytes #xbe))
  (check-equal? (hpack-decode-headers ctx replay) '(("custom-key" . "custom-header"))))

(test-case "size updates and eviction"
  (define ctx (make-hpack-ctx 4096))
  (define insert-big
    (bytes-append
     (bytes #x40)
     (hpack-encode-string "big")
     (hpack-encode-string (make-string 200 #\z))))
  (hpack-decode-headers ctx insert-big)
  (check-equal? (hpack-ctx-size ctx) (+ 3 200 32))
  ;; resize below the entry size: evicts everything
  (define resize (bytes #x30))                       ; 001 10000 = size update to 16
  (hpack-decode-headers ctx resize)
  (check-equal? (hpack-ctx-size ctx) 0)
  ;; the evicted entry no longer resolves
  (check-exn exn:fail? (λ () (hpack-decode-headers ctx (bytes #xbe)))))

(test-case "utf-8 values survive the roundtrip"
  (define enc (make-hpack-ctx 4096))
  (define dec (make-hpack-ctx 4096))
  (define headers (list (cons "title" "汽车行业日报")))
  (check-equal? (hpack-decode-headers dec (hpack-encode-headers enc headers)) headers))
