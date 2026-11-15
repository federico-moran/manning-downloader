# Manning Downloader

> Built by a non-developer, fully agentically, after taking Matt Pocock's course: [see how](#how-this-was-built).

Downloads the ebooks you own on [Manning](https://www.manning.com/dashboard), checking that every file is complete.

A PowerShell 7 script using your own logged-in session. It's a sibling of [humblebundle-downloader](https://github.com/federico-moran/humblebundle-downloader), built the same way, and of [packtpub-downloader](https://github.com/federico-moran/packtpub-downloader). See [docs/design.md](docs/design.md) for how it talks to Manning and why.

## What it does

- Reads your bookshelf (the list on your dashboard) and Manning's public catalogue, and saves both as `manning-library.json`: every book, liveProject and liveVideo, with ISBNs, MEAP versions and newer editions.
- Downloads each book's PDF and EPUB (the EPUB3 when Manning offers one), and the code samples Manning hosts, one file at a time, 5 seconds apart.
- Checks each file is a complete PDF, EPUB or zip of the format asked for before giving it its real name. A file that fails is downloaded once more, then recorded as failed.
- Keeps `manifest.csv` in the folder: every file with its ISBN, title, authors, version, size and SHA-256. Re-runs skip what's there.
- Names files by title (`ASP.NET Core in Action, Third Edition.pdf`). Code is saved as `<title> - code.zip`; code on GitHub is recorded as a link instead.
- Cancelled MEAPs and books no longer in Manning's catalogue are downloaded like the others, and listed at the end.

liveProjects and liveVideos are listed in `manning-library.json` but not downloaded.

## Setup

1. PowerShell 7 (`pwsh`).
2. Your session cookie. Log in at manning.com, press **F12** → **Application** → **Cookies** → `https://www.manning.com`, and copy the value of `JSESSIONID`. The script asks for it the first time (it isn't shown as you paste) and saves it encrypted for your Windows account in `%LOCALAPPDATA%\manning-downloader`. When it expires, you're asked again.

**The cookie is your login.** Never paste it anywhere else, and don't commit it. **The files carry your name and email** (Manning stamps every download): keep the library folder private.

## Usage

```powershell
.\Get-ManningLibrary.ps1 -WhatIf          # read your bookshelf and show what would be downloaded
.\Get-ManningLibrary.ps1 -MaxDownloads 1  # download one file, to check everything works
.\Get-ManningLibrary.ps1                  # download everything
```

| Option | Default | |
| --- | --- | --- |
| `-Folder` | `OneDrive\Documents\Manning` | Where the files, `manifest.csv` and `manning-library.json` go |
| `-Format` | `pdf, epub, supplement` | Also `kindle` (`.mobi`); `supplement` is the code samples |
| `-PlainEpub` | off | Take the EPUB, not the EPUB3, when a book has both |
| `-MaxDownloads` | all | Stop after this many files |
| `-DelaySeconds` | 5 | Pause between downloads |
| `-VerifyOnly` | | Check the folder against `manifest.csv`, offline |
| `-CompareWith <folder>` | | List which files in another folder are also here (same SHA-256, same ISBN, or exactly the same title), and which are only there |
| `-ResetSession` | | Forget the saved cookie |

For the full run checklist, see the [playbook](docs/playbook.md).

### Calibre

```powershell
.\Update-Calibre.ps1 -WhatIf  # preview
.\Update-Calibre.ps1          # add the EPUBs to Calibre
```

Adds every EPUB in the library that isn't in Calibre yet, tagged `Manning`, plus `MEAP` for books still in early access and `MEAP cancelled` for cancelled ones. Books are recognised by their EPUB's SHA-256, so a re-run adds only new books, and gives books already there any tags they lack. A Manning book already in Calibre from another store (Humble bundles include Manning books) is found by its title, with or without a subtitle: it isn't added again, it gets the `Manning` tag, and it's listed so you can check it is the same book. A title that matches several books is left alone and listed. PDFs are left out, and with them the free samplers, which are PDF only. Close Calibre first; the script backs up its database before changing anything. `-MaxBooks 1` adds one book, for a first test.

## Development

```powershell
Invoke-Pester ./tests
```

The logic is in [`src/ManningLibrary.psm1`](src/ManningLibrary.psm1) and tested with Pester 5+ using a made-up bookshelf and catalogue ([`tests/fixtures`](tests/fixtures)); [`Get-ManningLibrary.ps1`](Get-ManningLibrary.ps1) handles the session, the network and the output, and [`Update-Calibre.ps1`](Update-Calibre.ps1) the calls to `calibredb`.

Only use this for books you've bought, at the gentle default pace.

## How this was built

I'm not a developer. This year I took Matt Pocock's [AI Coding for Real Engineers](https://www.aihero.dev/cohorts/ai-coding-for-real-engineers-m0k0w) course, and this tool and its two siblings were my first projects afterwards. They were built fully agentically: Claude Code wrote all the code and the docs. My part was choosing the problems, finding out how each store's site works, making the decisions (each design doc records them and why), and testing everything against my own libraries. I followed the course's process, with Matt's [skills](https://github.com/mattpocock/skills) installed in Claude Code.

I built the three between 2026-09-27 and 2026-10-11. Together they've downloaded and checked about 2,550 files, and the Humble and Manning tools have 105 automated tests between them.

This was the third and quickest, because it reuses the Humble tool's design. The new problem was checking files with nothing to check them against: Manning publishes no sizes or hashes, and stamps every download with the buyer's details, so no two downloads are identical. So each file is checked for being complete and of the right type instead: a PDF with its end marker, an EPUB, a zip, or a gzip whose size matches its trailer. 232 files came down, all passing.

The siblings: [packtpub-downloader](https://github.com/federico-moran/packtpub-downloader), my favourite, and [humblebundle-downloader](https://github.com/federico-moran/humblebundle-downloader).

A personal project: issues are welcome, but fixes aren't promised. Not affiliated with or endorsed by Matt Pocock, AI Hero, PacktPub, Humble Bundle or Manning.

## License

[MIT](LICENSE)
