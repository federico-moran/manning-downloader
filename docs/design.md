# Design

Decisions made before building (2026-10-11), and why. They come from a probe of a real account's dashboard (DevTools, a saved HAR file, and a cookie test), not from documentation: Manning publishes no API for customers.

## How it talks to Manning

| Purpose | Request | Answer |
| --- | --- | --- |
| Your bookshelf | `GET /dashboard/getLicensesAjax?isDropboxIntegrated=&order=purchaseDate&sort=desc&filter=all` | An HTML table, every row at once (no paging) |
| Book details | `GET /api/search/productsAutocompleteInfo?new=true` | Public JSON: the whole catalogue (about 2,300 products, 2.3 MB) |
| A file | `GET /dashboard/download?productId=<id>&downloadFormat=PDF\|EPUB\|EPUB3\|KINDLE` | The file itself, at once (`Content-Disposition: attachment`), chunked: no size given |
| Code samples | The row's "download code samples" link | Usually a zip on `manning-content.s3.amazonaws.com`; sometimes a GitHub repository |

Each bookshelf row is `<tr class="license-row" is-meap is-book is-video>`, with the title (`data-sort`), authors, the book's page (`/books/<slug>`), the MEAP version (`version: 12, last updated: 2026-07-14`), a `meap-cancelled` mark, the code link, and one download link per format. The product ID in the download links is the catalogue's `id`, which gives the ISBN, `lastSignificantDate`, `nextEdition` and tags.

**Login:** only the `JSESSIONID` cookie matters; tested one cookie at a time, it alone returns the whole bookshelf. Without it, Manning answers 303 to `login.manning.com/login`; the script follows redirects and treats ending up there as "session expired". (`TGC`, the single sign-on cookie, could renew the session automatically, but that flow wasn't probed; asking again is simpler.)

**A standalone script, not a browser script.** PacktPub's downloader had to run in the browser because of a bot check. Manning (2026) is plain nginx with no challenge: a script with the cookie gets the same answers as the browser. So this works like the Humble tool, with its advantages: file names, checks as it goes, a manifest, no browser tab. If Manning ever starts blocking scripts, the fallback is a console script like PacktPub's.

## What the probe found (one account, 2026-10-11)

144 items: 92 books (76 with PDF and EPUB, 43 also Kindle, 2 also EPUB3, 15 PDF only; 6 MEAPs, one of them cancelled), 49 liveProjects and 3 liveVideos. Code: 60 zips on S3, 6 GitHub links. 90 of the 92 books are in the catalogue; the other 2 are withdrawn MEAPs (their slugs end in `-cx`). 13 books have a newer edition, 10 of which were on the bookshelf too.

## Decisions

| Area | Decision | Why |
| --- | --- | --- |
| Language and shape | PowerShell 7; logic in a module, network calls in the script | As in the Humble tool |
| Cookie | `JSESSIONID` only, pasted once, saved with DPAPI under `%LOCALAPPDATA%`; asked again when Manning redirects to its login page; `-ResetSession` | The only cookie needed; a run takes under an hour |
| Scope | Books only. liveProjects and liveVideos are listed in `manning-library.json`, not downloaded | Nothing to download for liveProjects; liveVideo is another site, for 3 videos |
| Formats | `-Format`, default PDF, EPUB and code; Kindle (`.mobi`) only when asked for | The Kindle copies are made from Calibre's EPUBs; Manning's own Kindle note says to use EPUB since 2023 |
| EPUB3 | Taken instead of the EPUB when offered; `-PlainEpub` for the other | One EPUB per book, so no duplicates in Calibre |
| Code | Files on S3 downloaded as `supplement`, keeping their type (59 zips and one `.tgz` in the probed account); GitHub repos recorded as `link` (status `link`, URL in the manifest) | A repo is live code, not a fixed file, and on another site |
| Book details | From the catalogue, joined by product ID; for a book not in it, the ISBN inside its EPUB | One request gives ISBNs for almost every book, PDF-only ones included |
| Withdrawn books | Cancelled MEAPs and books gone from the catalogue are downloaded, and listed at the end of the run | The files may disappear; a refund or exchange is the owner's decision |
| Folder | `OneDrive\Documents\Manning`, flat | Like the other libraries |
| File names | The title, safe for Windows (`:` becomes ` -`); `<title> - code.zip`; a second book with the same title gets its ID: `Title (1234).pdf` | Readable; the manifest ties each file to its ID and ISBN |
| Checking | Download to `.part`, then check it's a complete file of the format asked for (PDF with its end marker, EPUB, Kindle `BOOKMOBI`, zip, or a gzip whose decompressed size matches the size in its trailer: .NET reads a cut-off gzip without complaint). Failing once: downloaded again; twice: `failed` | Manning gives no size or hash, and its watermark makes every download different, so structure is all there is to check. A login page saved by mistake fails this check too |
| Resuming | An interrupted `.part` is downloaded again from the start | No size is given, so a partial file can't be resumed safely |
| Manifest | The common format proposed for every store: `store, id, isbn, title, authors, format, file, bytes, sha256, valid, status, drm, version, added`, then `source_format, meap, url, modified` | First tool with it; the shared module can build on it later |
| Version | `MEAP v12 (2026-07-14)` for a MEAP, the catalogue's last-update date otherwise, as it was when the file was downloaded | What a later "new version" check compares; the hash can't be used |
| Duplicates with other libraries | All downloaded; `-CompareWith` (SHA-256, ISBN, then exact title) shows the overlap | A Manning copy may be newer than a Humble one; keeping one is decided in Calibre |
| Pace | One file at a time, 5 s apart, 3 retries with growing waits | Human pace |

## Later

- **v1.1:** report MEAPs with a newer version, books that are now final, and newer editions not on the bookshelf (all already in `manning-library.json`); `-Update` downloads new versions and keeps the old file, renamed with the date (the Humble tool's rule).
- **Calibre:** an `Update-Calibre.ps1` like the Humble tool's, tagged `Manning`.

## Code layout

- [`src/ManningLibrary.psm1`](../src/ManningLibrary.psm1): the logic, with no network calls. Tested: `ConvertFrom-Bookshelf`, `Add-CatalogInfo`, `Get-DownloadPlan`, `Get-BookFileType` and `Test-DownloadedFile`, `Test-Library`, `Get-EpubIsbn`, `Compare-Library`.
- [`Get-ManningLibrary.ps1`](../Get-ManningLibrary.ps1): session, HTTP, downloading, writing the manifest, output. Not unit tested; checked by a real `-WhatIf` and a one-file run.
- [`tests/fixtures`](../tests/fixtures): a made-up bookshelf and catalogue in the shape of the real answers. Never real ones: they contain order IDs.

## Open questions

- How long a session lasts.
- Whether two downloads of the same book differ (the watermark). Nothing depends on it.
