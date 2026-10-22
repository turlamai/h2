# h2

[English](README.md) · **中文**

[![CI](https://github.com/turinglambdaai/h2/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/h2/actions/workflows/ci.yml)

Racket 的 HTTP/2：RFC 7540 帧编解码 + 完整 RFC 7541 HPACK（静态/动态表、Huffman 双向）。纯协议层——字节进、结构出；连接与流状态机留给调用者。

## 安装

```
raco pkg install h2
```

## 使用

```racket
(require h2)

;; 帧层
(bytes->frame buffered-bytes 0)          ; 解一帧 + 下一位置
(frame->bytes (make-settings-frame '())) ; 经典的 9 字节空 SETTINGS
(frame->bytes (make-goaway-frame 7 no-error #"bye"))

;; HPACK——解码器实现完整规范
(define ctx (make-hpack-ctx 4096))
(hpack-decode-headers ctx
                      (bytes #x82 #x86 #x84 #x41 #x0f
                             #x77 #x77 #x77 #x2e #x65 #x78 #x61
                             #x6d #x70 #x6c #x65 #x2e #x63 #x6f #x6d))
;; => '((":method" . "GET") (":scheme" . "http")
;;       (":path" . "/") (":authority" . "www.example.com"))
;; （RFC 7541 C.6.1 的第一个请求块原样）

;; 编码器：静态索引 + 字面量，更短才用 Huffman
(hpack-encode-headers (make-hpack-ctx 4096)
                      (list '(":method" . "GET") '("x-custom" . "v")))
```

- HPACK 对照 RFC 7541 附录 C 自带向量金测（整数表示、C.4/C.6 请求块）
- Huffman 编解码完整实现，含 EOS 前缀填充规则
- 解码器跟踪插入、淘汰与动态表大小更新
- 帧层覆盖全部十种帧类型，带类型化 payload 助手

局限：连接层（preface 交换、流状态机、流控、可用客户端）是下一个里程碑。

## 开发

```
raco pkg install --auto --link .
raco test tests
raco setup --check-pkg-deps -l h2
```

## 许可

[MIT](LICENSE)
