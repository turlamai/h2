#lang scribble/manual

@(require (for-label h2
                     racket/base)
          scribble/example)

@title{h2: HTTP/2 Frames and HPACK}
@defmodule[h2]

RFC 7540 frame codec and RFC 7541 HPACK for Racket — the protocol
layer of HTTP/2, the sibling of the @tt{websocket} package. Pure bytes
in, structures out: connections, stream state machines, and flow
control stay with the caller (and are the next milestone).

@section{Frames}

Every frame is a @racket[frame?] — length, type, flags, stream id,
payload. The nine-byte header is decoded with
@racket[bytes->frame]; building helpers exist for the payloads that
matter early: SETTINGS, PING, GOAWAY, WINDOW_UPDATE, RST_STREAM, and
HEADERS with padding.

@defstruct*[frame ([length exact-nonnegative-integer?]
                   [type exact-nonnegative-integer?]
                   [flags exact-nonnegative-integer?]
                   [stream-id exact-nonnegative-integer?]
                   [payload bytes?])]

@defproc[(frame->bytes [f frame?]) bytes?]

@defproc[(bytes->frame [bstr bytes?] [pos exact-nonnegative-integer?])
         (values frame? exact-nonnegative-integer?)]

Decode one frame at @racket[pos]; the caller buffers at least
length+9 bytes. Stream ids keep 31 bits (the reserved bit reads 0).

@defproc[(frames->bytes [fs (listof frame?)]) bytes?]

@defthing[connection-preface bytes?]

The fixed client preface @tt{PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n} (§3.5).

Frame type constants:

@defthing[data-frame exact-nonnegative-integer?]
@defthing[headers-frame* exact-nonnegative-integer?]
@defthing[priority-frame exact-nonnegative-integer?]
@defthing[rst-stream-frame exact-nonnegative-integer?]
@defthing[settings-frame exact-nonnegative-integer?]
@defthing[push-promise-frame exact-nonnegative-integer?]
@defthing[ping-frame exact-nonnegative-integer?]
@defthing[goaway-frame exact-nonnegative-integer?]
@defthing[window-update-frame exact-nonnegative-integer?]
@defthing[continuation-frame exact-nonnegative-integer?]

Error codes:

@defthing[no-error exact-nonnegative-integer?]
@defthing[protocol-error exact-nonnegative-integer?]
@defthing[internal-error exact-nonnegative-integer?]
@defthing[flow-control-error exact-nonnegative-integer?]

@defproc[(make-settings-frame [pairs (listof (cons/c exact-nonnegative-integer? exact-nonnegative-integer?))]) frame?]

@defproc[(settings-payload->list [payload bytes?])
         (listof (cons/c exact-nonnegative-integer? exact-nonnegative-integer?))]

@defproc[(make-ping-frame [ack? boolean?] [opaque exact-nonnegative-integer?]) frame?]

@defproc[(make-goaway-frame [last-stream-id exact-nonnegative-integer?]
                            [error-code exact-nonnegative-integer?]
                            [debug-bytes bytes?]) frame?]

GOAWAY frames are always stream 0; @racket[last-stream-id] rides in
the payload.

@defproc[(make-window-update-frame [stream-id exact-nonnegative-integer?]
                                   [increment exact-nonnegative-integer?]) frame?]

@defproc[(make-rst-stream-frame [stream-id exact-nonnegative-integer?]
                                [error-code exact-nonnegative-integer?]) frame?]

@defproc[(make-headers-frame [stream-id exact-nonnegative-integer?]
                             [block bytes?]
                             [#:end-stream end-stream boolean? #t]
                             [#:pad-length pad-length (or/c exact-nonnegative-integer? #f) #f])
         frame?]

@defproc[(headers-block->bytes [payload bytes?]) bytes?]

Strips HPACK-unrelated padding from a PADDED HEADERS/DATA payload —
call it only when the PADDED flag is set.

@section{HPACK}

@defproc[(make-hpack-ctx [max-size exact-nonnegative-integer?]) hpack-ctx?]

@defproc[(hpack-ctx? [v any/c]) boolean?]

@defproc[(hpack-ctx-size [ctx hpack-ctx?]) exact-nonnegative-integer?]

The dynamic-table context (in octets, per §4.1's 32-byte entry
overhead). Decoder contexts track inserts, evictions, and size
updates; encoder contexts may stay fresh — the built-in encoder uses
only static-table indexing and literals without indexing, which is
always legal.

@defproc[(hpack-decode-headers [ctx hpack-ctx?] [bstr bytes?])
         (listof (cons/c string? string?))]

Full §6: indexed, literal with/without/never indexing, dynamic table
size updates. Invalid data (including an indexed field with index 0)
raises.

@defproc[(hpack-encode-headers [ctx hpack-ctx?]
                               [headers (listof (cons/c string? string?))])
         bytes?]

Exact static-table matches become one indexed byte (e.g.
@racket[(:method . GET)] → @racket[#x82], same shape as the RFC's own
examples); everything else goes out as literal without indexing,
Huffman-coded when the table actually makes it shorter (ASCII only).

@defproc[(hpack-encode-integer [value exact-nonnegative-integer?]
                               [prefix-bits exact-integer?]) bytes?]

@defproc[(hpack-decode-integer [bstr bytes?] [pos exact-nonnegative-integer?]
                               [prefix-bits exact-integer?])
         (values exact-nonnegative-integer? exact-nonnegative-integer?)]

§5.1; the prefix's high bits are the caller's opcode bits.

@defproc[(hpack-encode-string [s string?]) bytes?]
@defproc[(hpack-decode-string [bstr bytes?] [pos exact-nonnegative-integer?])
         (values string? exact-nonnegative-integer?)]

§5.2 string literals with the Huffman flag.

@section{Huffman}

@defproc[(huffman-encode [s string?]) bytes?]

RFC 7541 Appendix B coding, padded with 1 bits (never a whole byte).

@defproc[(huffman-decode [bstr bytes?]) string?]

Rejects padding that is not a prefix of EOS, mid-stream EOS, and
invalid codes.

@defproc[(huffman-encoded-length-bits [s string?])
         exact-nonnegative-integer?]

For size decisions before encoding.

@section{Status and limits}

Frames + HPACK are complete and golden-vector tested against RFC
7541's appendix C. The connection layer — preface exchange, stream
state machine, flow control, and a working h2c client — is the next
milestone; until it lands, this package is the protocol core other
code can build on, tested the same way the RFC tests itself.
