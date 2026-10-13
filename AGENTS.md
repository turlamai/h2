# AGENTS.md

## What this is

`h2` — HTTP/2 protocol layer for Racket: RFC 7540 frames + RFC 7541
HPACK. Single-collection package (`h2` = collection = package name;
"http2" is taken on the catalog by a stub). Family protocol-library
line. M0 = protocol core; connection layer is the next milestone.

## Layout

- `hpack-tables.rkt` — GENERATED from the RFC 7541 text (appendix A
  static table, appendix B Huffman codes). Never edit by hand; the
  generator parses the RFC and asserts binary-vs-hex-vs-length.
- `huffman.rkt` — §5.2 Huffman both ways; canonical decode index built
  per code length
- `hpack.rkt` — integers, string literals, static/dynamic tables,
  header-list encode/decode
- `frames.rkt` — RFC 7540 §4/§6 frame codec + typed payload helpers
- `main.rkt` — re-exports

## Invariants

- bit-at is MSB-first with a NEGATIVE arithmetic-shift (positive
  shifts left — this bit us once).
- Huffman decode: padding may be ZERO bits (byte-aligned string);
  nonzero padding must be all 1s and shorter than 8; EOS mid-stream is
  an error.
- hpack-encode-string only Huffman-codes ASCII strings (the table has
  no entries above 255).
- The encoder is stateless by strategy (static indexing + literal
  without indexing); encoder and decoder contexts are independent.
- Dynamic table evicts oldest-first; entry overhead is name+value+32.
- GOAWAY frames are always stream 0; last-stream-id rides in the
  payload.

## Conventions

- Code comments in English.
- Golden vectors come from the RFC's own appendix C, not
  self-roundtrips.

## Quality gates (before any release)

1. `raco test tests` — all green
2. `raco setup --check-pkg-deps -l h2` — zero violations
3. `raco setup -l h2` — docs build clean, zero undefined tags
