# koreader-twos — agent notes

KOReader plugin (`twos.koplugin/`) that exports book highlights to Twos via
its public API (https://www.twosapp.com/api/v1). Developed vibe-coded with AI
assistance; the user tests on a real device and gives feedback.

## Layout

- `twos.koplugin/main.lua` — plugin entry, menus, settings, export actions
- `twos.koplugin/twosapi.lua` — HTTP client for the Twos API
- `twos.koplugin/collector.lua` — highlight extraction from docs/history,
  conversion to Twos "thing" items
- `session-ses_0184.md` — transcript of the original development session
  (gitignored, never commit or push it)

## Non-negotiable design decisions (user-chosen)

- One Twos list per book, titled `Title - Author` (author appended only when
  known; format chosen to avoid hardcoded English words)
- Highlights: things tagged `#highlights`, blockquote-styled (optional setting)
- KOReader notes: exported as **indented subnotes** (`tabs = 1`) tagged
  `#booknotes`, directly after their highlight; the highlighted passage also
  gets `#booknotes` only when it has a note
- Emoji: exactly 6 options (open book, book, books, memo, bookmark, pencil)
  plus None. Menu labels are TEXT ONLY — KOReader cannot render emoji chars
  in menus. The emoji value itself is still sent to the API.
- Exports must be safe to re-run: bulk upload uses `skip_duplicates: true`

## API constraints (verified against the OpenAPI spec)

- `POST /things/bulk` accepts max 500 items per call (plugin chunks at 500)
  and does NOT accept the native thing `note` field — that's why notes are
  subnote things, not attached notes. Do not "fix" this.
- `GET /search` caps at 50 lists and is not a complete enumeration; that is
  why `findOrCreateList` falls back to paging `GET /lists` before creating.
  Removing the fallback can create duplicate lists.
- Rate limit is 1000 requests/hour; 429 sets `rate_limited` and stops early.
- `skip_duplicates` dedupes by url, else text, within the target list.
- Backdating: KOReader datetimes are local time; converted with
  `os.time` then `os.date("!%Y-%m-%dT%TZ", ...)`.

## KOReader behavior to remember

- Sidecar `.sdr` files are flushed lazily, so highlights in the currently
  open book may not be on disk yet. `exportAllBooks` merges the live
  in-memory annotations into the history-based results — keep that logic.
- Plugin settings live in `<koreader settings dir>/twos.lua`, loaded via
  LuaSettings, flushed on the `FlushSettings` event (guarded by `self.updated`).

## Development workflow

- No KOReader source checkout here (`.luarc.json` expects `./koreader/frontend`).
  Only syntax checks are possible: `luajit -bl <file> /dev/null` for each
  `.lua` file. The user does the real testing on a device.
- Repo: https://github.com/nchrtd22/koreader-twos (private), branch `main`.
  Never push the session transcript; it is gitignored.
- API spec for reference: `curl https://www.twosapp.com/api/v1/openapi.json`

## Known open ideas (not bugs)

- Optional feature: append page/chapter to exported highlight text
  (fields are collected in entries but currently unused)
- `X-RateLimit-Remaining` header could pre-empt 429s
- Legacy highlight parsing iterates pages via `pairs()` (nondeterministic
  order; only affects very old sidecar formats)
