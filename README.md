# h2

**English** · [中文](README.zh-CN.md)

[![CI](https://github.com/turlamai/h2/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/h2/actions/workflows/ci.yml)

HTTP/2 for Racket: the RFC 7540 frame codec and the full RFC 7541
HPACK (static + dynamic tables, Huffman both ways). Pure protocol
layer — bytes in, structures out; connections and stream state stay
with the caller.

## Install

```
raco pkg install h2
```

## Use

```racket
(require h2)

;; frames
(bytes->frame buffered-bytes 0)          ; one frame + next position
(frame->bytes (make-settings-frame '())) ; the canonical 9 zero-ish bytes
(frame->bytes (make-ping-frame #f #xdeadbeef))
(frame->bytes (make-goaway-frame 7 no-error #"bye"))

;; HPACK — decoder implements the full spec
(define ctx (make-hpack-ctx 4096))
(hpack-decode-headers ctx
                      (bytes #x82 #x86 #x84 #x41 #x0f
                             #x77 #x77 #x77 #x2e #x65 #x78 #x61
                             #x6d #x70 #x6c #x65 #x2e #x63 #x6f #x6d))
;; => '((":method" . "GET") (":scheme" . "http")
;;       (":path" . "/") (":authority" . "www.example.com"))
;; (RFC 7541 C.6.1's own first-request block)

;; encoder: static indexing + literals, Huffman when shorter
(hpack-encode-headers (make-hpack-ctx 4096)
                      (list '(":method" . "GET") '("x-custom" . "v")))
```

- HPACK tested against RFC 7541's own appendix C vectors (integer
  representation, the C.4/C.6 request blocks)
- Huffman encode/decode complete, including EOS-prefix padding rules
- decoder tracks inserts, evictions, and dynamic table size updates
- frame layer covers all ten frame types with typed payload helpers

Limits: the connection layer (preface exchange, stream state machine,
flow control, a working client) is the next milestone.

## Development

```
raco pkg install --auto --link .
raco test tests
raco setup --check-pkg-deps -l h2
```

## License

[MIT](LICENSE)
