# Vendored: swift-markdown (the GFM AST)

`Sources/Markdown` and `Sources/CAtomic` are the **0.7.0** sources of
[apple/swift-markdown](https://github.com/swiftlang/swift-markdown)
(Apache License 2.0), vendored because the package's own manifest carries a
Windows-only `.unsafeFlags` entry that SwiftPM refuses in any package
dependency — SpeechLogic is a package, so the dependency route dead-ends
even though the flags never apply on Apple platforms.

The C engine underneath is NOT vendored: `cmark-gfm` and
`cmark-gfm-extensions` come from the
[swiftlang/swift-cmark](https://github.com/swiftlang/swift-cmark) package
(exact 0.7.0), whose manifest is clean. Module names match what these
sources import (`cmark_gfm`, `cmark_gfm_extensions`, `CAtomic`), so the
files are unchanged apart from this note.

Upstream: swift-markdown 0.7.0, commit 704a1218d0e3b5b85a884f1153a065eef7e8d4c2.
