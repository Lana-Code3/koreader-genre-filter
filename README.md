# KOReader Genre Filter

[![CI](https://github.com/Lana-Code3/koreader-genre-filter/actions/workflows/ci.yml/badge.svg)](https://github.com/Lana-Code3/koreader-genre-filter/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
![KOReader](https://img.shields.io/badge/KOReader-v2026.03-informational)
![Platform](https://img.shields.io/badge/device-Kobo%20%7C%20any%20KOReader-lightgrey)

A [KOReader](https://github.com/koreader/koreader) plugin that searches your
library by **genre/tag** with **include and exclude** lists, optionally narrowed
by **reading status** and **words in the title or description**. Results open
either in KOReader's normal results list or in a **two-column large-cover
gallery** that shows each book's title, author, reading status and tags.

```
Include: Sci-Fi             Exclude: Fantasy, Horror
Status:  Finished           Words:   "time travel"
```

> **Status:** written against the KOReader **v2026.03** source. The matching
> logic has unit tests (`tests/`). The UI parts have been developed against the
> KOReader source but need testing on real devices, so feel free to
> [open an issue](../../issues) if something looks wrong.

---

<details>
<summary><b>Features</b></summary>

- **Include / exclude genres.** Books must match the included genres and are
  dropped if they have *any* excluded genre. Include can match *any* or *all*
  of the listed genres.
- **Word search** in the title and (optionally) the description. All words must
  match; use quotes for phrases: `"murder", "time travel"`.
- **Reading status filter** (New, Reading, On hold, Finished), including
  status from the **native Kobo reader**, not just KOReader's own
  ([details](#reading-status-and-the-kobo-reader)).
- **Browse genres:** lists every genre found in your library with book counts.
  Tap to include, hold to exclude.
- **Two result views:** the standard KOReader results list, or a two-column
  cover gallery (2x4, 2x3 or 2x2 books per page; fewer rows = bigger covers).
- **Tags on every book** in the gallery; **synopsis on long-press**.
- **Back-to-filter arrow** in the results, and a **Show results** button that
  behaves like the keyboard's Return key.
- **Keyboard toggle** button to push the keyboard down while you read the
  dialog and pull it up again to type.
- Remembers your last filter and options.
- Optional gesture/Dispatcher action.

</details>

<details>
<summary><b>Requirements</b></summary>

| | |
|---|---|
| KOReader | v2026.03 (earlier/later versions may work, but are untested) |
| CoverBrowser plugin | Must be enabled (it is by default). It indexes book metadata and covers; the cover gallery depends on it |
| Metadata | Books need genres in their metadata (EPUB subjects, Calibre tags, PDF keywords) |
| Kobo status | Kobo device with the stock `KoboReader.sqlite` library database (optional) |

</details>

<details>
<summary><b>Installation</b></summary>

### Kobo (KFMon / NickelMenu / OCP-style packages)

KOReader lives in the hidden `.adds` folder on the device.

1. Download `genre_filter-kobo-<version>.zip` from the
   [Releases](../../releases) page.
2. Connect the Kobo over USB (it shows up as `KOBOeReader`).
3. Unzip the archive **into the root of the device**. It contains
   `.adds/koreader/plugins/genre_filter.koplugin/` and merges with the existing
   `.adds` folder. Hidden folders must be visible: macOS **Cmd+Shift+.**,
   Windows **Explorer > View > Hidden items**.
4. Eject safely and restart KOReader.

Resulting layout:

```
KOBOeReader/
└── .adds/
    └── koreader/
        └── plugins/
            └── genre_filter.koplugin/
                ├── _meta.lua
                ├── main.lua
                ├── genre_filter_matcher.lua
                └── genre_filter_gallery.lua
```

Combined KOReader + Plato packages work too: Plato ignores KOReader plugins and
is not touched.

### Other devices

Download `genre_filter.koplugin-<version>.zip`, extract the
`genre_filter.koplugin` folder into KOReader's `plugins/` directory
(`koreader/plugins/` on most platforms), and restart KOReader.

### Check it worked

Open the file browser, go to the **Search** tab (magnifier icon). You should see
**Genre filter search**. If not, open the top menu and check *More tools > Plugin
management*.

</details>

<details>
<summary><b>Usage</b></summary>

Open **Search > Genre filter search**.

| Control | What it does |
|---|---|
| **Include genres** | Comma-separated list, e.g. `Sci-Fi` |
| **Exclude genres** | Comma-separated list, e.g. `Fantasy, Horror`. Any match removes the book |
| **Words in title or description** | Optional. All words must appear; `"quoted phrases"` are kept together |
| **Keyboard** | Hides the keyboard if it is up, shows it if it is down |
| **Browse genres** | Scans your library and lists genres with counts. Tap = include, hold = exclude |
| **Options** | Require all included genres, exact tag names only, word search in description, include subfolders |
| **Status: any** | Pick one or more reading statuses |
| **View: ...** | Cycles: list, covers 2x4, covers 2x3, covers 2x2 |
| **Search home folder** | Runs the search in your home folder |
| **Show results** | Runs the search in the folder you are currently browsing (same as pressing Return on the keyboard) |

At least one of genres, words or a status must be set.

### Results

- **Tap** a book to open it.
- **Long-press** a book:
  - Cover gallery: *Synopsis & tags*, *Open*, *More actions...* (KOReader's
    full book dialog).
  - List view: KOReader's normal dialog with an extra *Synopsis & tags* button.
- **Arrow at the bottom left** returns to the filter dialog.
- **Top-left menu icon** switches to select mode (add to collection, etc.), as
  in the built-in file search.

</details>

<details>
<summary><b>How matching works</b></summary>

Genres come from each book's *keywords* metadata (EPUB `dc:subject`, Calibre
tags, PDF keywords). Multiple tags can be separated by commas, semicolons,
pipes or newlines.

- Case-insensitive. Hyphens, underscores and repeated spaces are equivalent:
  `Sci-Fi` = `sci fi` = `SCI  FI`.
- **Default (whole words):** the term must appear as whole words inside a tag.
  `Romance` matches `Contemporary Romance` but not `Romanced`; `Comedy`
  matches `Romantic Comedy`.
- **Exact tag names only** (Options): the tag must equal the term.
- **Excludes are strict:** one excluded tag removes the book.
- **Include list:** matches *any* listed genre by default; enable *Require all
  included genres* for AND. With no include list you get everything except the
  excluded genres.
- Books that have no tags never match an include list.
- Books whose metadata has not been indexed yet are **skipped and counted**; the
  plugin then offers to run KOReader's metadata extraction for the folder.

| Include | Exclude | Keeps | Drops |
|---|---|---|---|
| Romance, Drama | Comedy | Romance / Drama / Romance+Drama | anything tagged Comedy, books with neither genre |
| Sci-Fi | Fantasy, Horror | Sci-Fi | Sci-Fi that is also Fantasy or Horror |

</details>

<details>
<summary><b>Reading status and the Kobo reader</b></summary>

KOReader's reading status lives in per-book sidecar files, which only exist for
books you opened in KOReader. Books read in the **native Kobo reader** therefore
look "New" to KOReader.

To fix that, the plugin reads Kobo's own library database
(`/mnt/onboard/.kobo/KoboReader.sqlite`) **read-only** and looks up each book's
`ReadStatus` (Unread / Reading / Finished) and percent read.

- Both sources are combined: a book matches a status if **either** reader
  reports it. Finished in Kobo + New in KOReader = **Finished**.
- The gallery's status line uses the same combined information.
- Kobo has no "On hold" status, so that option only matches books set to On
  hold in KOReader.
- Kobo only writes its status when you leave a book, so a book you are reading
  right now may show its previous state.
- If the database is not found (non-Kobo device, emulator), the plugin tells you
  that only KOReader's status was used.

The database is never modified.

</details>

<details>
<summary><b>Settings</b></summary>

Your last filter and options are stored in KOReader's global settings under the
key `genre_filter`. Delete that key (or reset settings) to start fresh.

</details>

<details>
<summary><b>Project layout</b></summary>

```
genre_filter.koplugin/
├── _meta.lua                  plugin name and description (KOReader requires the underscore)
├── main.lua                   menu entry, dialog, library scan, results, Kobo status lookup
├── genre_filter_matcher.lua   pure-Lua include/exclude and word matching (unit tested)
└── genre_filter_gallery.lua   2-column cover gallery, lazy-loaded
tests/matcher_test.lua         unit tests for the matcher
scripts/make-release.sh        builds the release zips
.github/workflows/ci.yml       syntax check, tests, release on tag
```

How it works, briefly:

- The folder scan runs in a **subprocess** (like KOReader's built-in file
  search), so the UI stays responsive and the search can be cancelled.
- Metadata is read through KOReader's own BookInfo / CoverBrowser cache without
  opening the books.
- Standard-list results are handed to KOReader's `FileSearcher`, so tap-to-open,
  long-press actions, select mode and CoverBrowser's display modes keep working.
- The gallery is a `Menu` using CoverBrowser's `CoverMenu` for drawing and
  background cover extraction, with its own two-column item layout.

</details>

<details>
<summary><b>Development</b></summary>

```sh
# unit tests (Lua 5.1 or LuaJIT)
lua tests/matcher_test.lua

# build release zips into ./dist
scripts/make-release.sh v0.1.0
```

Pushing a tag like `v0.1.0` makes GitHub Actions run the tests and attach both
zips to a release.

To try changes quickly, copy `genre_filter.koplugin/` into your KOReader
`plugins/` folder and restart KOReader (or use the emulator on desktop).

</details>

<details>
<summary><b>Troubleshooting</b></summary>

| Problem | Fix |
|---|---|
| Menu entry missing | Check the folder is named `genre_filter.koplugin` and sits directly in `plugins/`; check Plugin management |
| "N books were skipped" | Their metadata is not indexed. Accept the plugin's extraction offer, or use the **+** menu > *Extract and cache book information* (shown while the file browser uses a CoverBrowser cover/list display mode) |
| Genre search finds nothing | The books may have no keywords in their metadata. Use *Browse genres* to see what exists |
| No covers in the gallery | CoverBrowser must be enabled; covers fill in as extraction finishes |
| Status filter ignores Kobo books | Check `/mnt/onboard/.kobo/KoboReader.sqlite` exists; the plugin shows a notice when it cannot read it |

</details>

<details>
<summary><b>Contributing</b></summary>

Issues and pull requests are welcome. Please include your device, KOReader
version and the filter you used when reporting a bug (the issue template asks
for this).

</details>

<details>
<summary><b>License</b></summary>

[GNU AGPL v3.0](LICENSE), the same license as KOReader. This plugin adapts
patterns from KOReader's `FileSearcher` and CoverBrowser code, which are
AGPL-3.0.

</details>

<details>
<summary><b>Acknowledgements</b></summary>

- The [KOReader](https://github.com/koreader/koreader) project and contributors.
- Kobo is a trademark of Rakuten Kobo Inc. This project is not affiliated with
  or endorsed by KOReader, Kobo or Rakuten.

</details>
