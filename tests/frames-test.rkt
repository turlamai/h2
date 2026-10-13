#lang racket/base

(require rackunit
         racket/list
         racket/match
         h2)

(define (uint32-of b i)
  (+ (* (bytes-ref b i) 16777216) (* (bytes-ref b (+ i 1)) 65536)
     (* (bytes-ref b (+ i 2)) 256) (bytes-ref b (+ i 3))))

(test-case "empty SETTINGS frame is the canonical nine bytes"
  (check-equal? (frame->bytes (make-settings-frame '()))
                (bytes #x00 #x00 #x00 #x04 #x00 #x00 #x00 #x00 #x00)))

(test-case "settings payload roundtrip"
  (define f (make-settings-frame (list (cons 3 100)        ; MAX_CONCURRENT_STREAMS
                                       (cons 4 65535))))   ; INITIAL_WINDOW_SIZE
  (define bs (frame->bytes f))
  (check-equal? (bytes-length bs) 21)
  (define-values (f2 pos) (bytes->frame bs 0))
  (check-equal? (frame-type f2) settings-frame)
  (check-equal? (frame-length f2) 12)
  (check-equal? (frame-stream-id f2) 0)
  (check-equal? (settings-payload->list (frame-payload f2))
                (list (cons 3 100) (cons 4 65535)))
  (check-equal? pos (bytes-length bs)))

(test-case "ping frame with ack flag"
  (define f (make-ping-frame #t #xdeadbeef))
  (define bs (frame->bytes f))
  (check-equal? (bytes-ref bs 3) ping-frame)
  (check-equal? (bytes-ref bs 4) #x01)              ; ACK
  (define-values (f2 _) (bytes->frame bs 0))
  (check-equal? (frame-flags f2) #x01)
  (check-equal? (bytes-length (frame-payload f2)) 8))

(test-case "goaway and window-update and rst roundtrip"
  (define fs
    (list (make-goaway-frame 7 no-error #"bye")
          (make-window-update-frame 3 65535)
          (make-rst-stream-frame 3 protocol-error)))
  (define bs (frames->bytes fs))
  (define decoded
    (let loop ([pos 0] [acc '()])
      (if (>= pos (bytes-length bs))
          (reverse acc)
          (let-values ([(f next) (bytes->frame bs pos)])
            (loop next (cons f acc))))))
  (check-equal? (map frame-type decoded)
                (list goaway-frame window-update-frame rst-stream-frame))
  (match-define (list g w r) decoded)
  (check-equal? (frame-stream-id g) 0)               ; GOAWAY is always stream 0
  (check-equal? (uint32-of (frame-payload g) 0) 7)   ; last-stream-id in payload
  (check-equal? (subbytes (frame-payload g) 8) #"bye")
  (check-equal? (frame-stream-id w) 3)
  (check-equal? (frame-stream-id r) 3))

(test-case "headers frame with padding and end-stream"
  (define block (bytes #x82 #x86))
  (define f (make-headers-frame 1 block #:end-stream #t #:pad-length 4))
  (define bs (frame->bytes f))
  (check-equal? (bytes-ref bs 4) #x09)              ; END_STREAM | PADDED
  (define-values (f2 _) (bytes->frame bs 0))
  (check-equal? (bytes-ref (frame-payload f2) 0) 4) ; pad length prefix
  (check-equal? (headers-block->bytes (frame-payload f2)) block)
  ;; unpadded roundtrip: no PADDED flag, payload IS the block
  (define f3 (make-headers-frame 1 block))
  (check-equal? (frame-payload f3) block)
  (check-equal? (bytes-ref (frame->bytes f3) 4) #x01))

(test-case "stream id keeps 31 bits"
  (define f (make-headers-frame #x7FFFFFFF (bytes #x82)))
  (define-values (f2 _) (bytes->frame (frame->bytes f) 0))
  (check-equal? (frame-stream-id f2) #x7FFFFFFF))

(test-case "connection preface"
  (check-equal? connection-preface
                #"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"))
