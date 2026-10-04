# twos.koplugin

A [KOReader](https://koreader.rocks/) plugin that exports your book highlights to
[Twos](https://www.twosapp.com/) (via its official API).

Each book becomes a Twos list named `Title - Author`, and every highlight is
uploaded as a note styled as a blockquote:

- Highlights get the `#highlights` tag
- A KOReader note attached to a highlight becomes an indented sub-note with the
  `#booknotes` tag, and the highlighted passage gets `#booknotes` too
- Exports can optionally be backdated to the time you made the highlight
- Re-running an export is safe: duplicates are skipped

## Installation

Copy the `twos.koplugin` folder into KOReader's `plugins` directory, then
restart KOReader.

## Setup

1. Create an API key at [Twos → Settings → API Keys](https://www.twosapp.com/settings/api-keys)
   with the scopes `write:lists`, `write:things`, `search`, and `read:lists`
2. In KOReader, open the plugin menu (Tools → Export to NewTwos → Settings)
   and set the key

## Usage

- **Export this book's highlights** — sends the highlights of the book you are
  currently reading
- **Export all books' highlights** — sends highlights from every book in your
  reading history (including the one you are reading)

Both actions are also available as dispatcher gestures/profiles.

Settings let you choose the list emoji, toggle blockquote styling, and toggle
backdating.

## Note

This plugin is vibe-coded: it was built with AI assistance rather than
hand-written line by line. It works, but expect the usual quirks.
