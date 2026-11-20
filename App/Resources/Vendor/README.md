# Vendored JavaScript

`mermaid.min.js` — Mermaid 11, MIT licensed, from
https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js

Bundled rather than fetched at runtime so diagrams render offline and the app
makes no network request to display a note. It is ~3.4 MB, which is the price
of Mermaid support; there is no smaller renderer for the syntax.

To update: download the file, check the diff is only the library, and confirm
`MermaidRenderer` still gets a `ready` and a `done` message back.

`highlight.min.js` — highlight.js 11.11.1 (BSD-3-Clause), the "common" build of
36 languages, from
https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.11.1/highlight.min.js

Runs in JavaScriptCore (no web view) to colour fenced code blocks; see
`CodeHighlighter`. It makes no network requests (checked: no fetch or
XMLHttpRequest in the file). To update: replace the file and run the
CodeHighlighter tests.

`ThirdPartyLicenses.txt` — the full licence texts of both, shipped in the app
bundle as the BSD and MIT licences ask of a binary distribution.
