# Zuzu Web Console (experimental)

This extra provides a browser-based console that mirrors the Zuzu
REPL behavior, including:

- Persistent per-session runtime state.
- Persistence also works when using multiple Starman workers.
- Multi-line continuation handling for unfinished input.
- Optional semicolon inference like CLI REPL mode.
- Immediate syntax highlighting while you type.

## Run it

From repository root:

	plackup -Ilib extras/webconsole/app.psgi

Then open:

	http://127.0.0.1:5000/

## Notes

- This is intentionally isolated under `extras/webconsole`.
- No core runtime files are modified.
- Syntax highlighting uses the existing `public/zuzu-highlight-js/zuzu-highlight.js`
  implementation copied from the site assets.
