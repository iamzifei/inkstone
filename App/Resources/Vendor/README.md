# Vendored JavaScript

`mermaid.min.js` — Mermaid 11, MIT licensed, from
https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js

Bundled rather than fetched at runtime so diagrams render offline and the app
makes no network request to display a note. It is ~3.4 MB, which is the price
of Mermaid support; there is no smaller renderer for the syntax.

To update: download the file, check the diff is only the library, and confirm
`MermaidRenderer` still gets a `done` message back.
