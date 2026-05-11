# ZuzuScript Web Console

This repository contains an experimental PSGI browser console for
ZuzuScript. It mirrors CLI REPL behaviour in a browser, keeps per-session
runtime state, and highlights input while editing.

Use Oxford English in documentation: mostly standard British English, with
`-ize` word endings.

## Relationship To Other Projects

The webconsole is backed by the Perl runtime and uses the browser
highlighter as a submodule:

- `app.psgi` loads `Zuzu` modules from the Perl runtime library path.
- `public/zuzu-highlight-js` is the highlighter submodule.

This project is host tooling, not a separate language implementation.
Parser, runtime, and stdlib bugs should normally be fixed in `zuzu-perl` or
`stdlib`, then consumed here.

## Project Shape

- `app.psgi` is the PSGI application and API backend.
- `public/index.html` is the browser UI shell.
- `public/app.js` handles editing, highlighting, requests, and output.
- Sessions are JSON files under `ZUZU_WEB_CONSOLE_SESSION_DIR`, defaulting
  to `/tmp/zuzu-webconsole-sessions`.

The backend denies high-risk runtime capabilities by default: `fs`, `net`,
`proc`, `db`, and `perl`.

## Running And Validation

In this split-repository workspace, run with the sibling Perl runtime on
`@INC`:

```bash
plackup -I../zuzu-perl/lib app.psgi
```

If this repository is cloned standalone, make the `zuzu-perl` library
available through `PERL5LIB` or an equivalent `plackup -I...` path before
starting the app.

Then open:

```text
http://127.0.0.1:5000/
```

Useful environment variables:

- `ZUZU_WEB_CONSOLE_SESSION_DIR` for session storage.
- `ZUZU_WEB_CONSOLE_EVAL_TIMEOUT` for evaluation timeout seconds.
- `ZUZU_WEB_CONSOLE_MAX_UNSHARED_KB` and
  `ZUZU_WEB_CONSOLE_MIN_SHARED_KB` for worker memory limits.

For frontend-only changes, at least run JavaScript syntax checks on files
you touch. For backend changes, smoke-test a simple expression and a
multi-line input through the browser or API.

## Maintenance Notes

Keep the webconsole isolated. Do not copy parser/runtime logic into this
repo. If syntax highlighting changes are needed, update the highlighter
submodule source rather than maintaining a divergent local tokenizer.
