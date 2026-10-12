# Playbook: downloading your Manning library

A checklist for each run. For what the tool does, see the [README](../README.md).

## 1. Get your session cookie

1. Log in at <https://www.manning.com> and open your dashboard.
2. **F12** → **Application** → **Cookies** → `https://www.manning.com` → copy the value of `JSESSIONID`.

## 2. Preview

In a PowerShell 7 terminal in the repo folder:

```powershell
.\Get-ManningLibrary.ps1 -WhatIf
```

Paste the cookie when asked. It reads your bookshelf and Manning's catalogue, saves `manning-library.json` in `OneDrive\Documents\Manning`, and prints the plan: how many files would be downloaded, and how many code links are on GitHub. Manning gives no file sizes, so there's no total; expect a few GB for about a hundred books.

If it says the bookshelf came back empty, Manning has changed its dashboard: see [design.md](design.md).

## 3. One-file test

```powershell
.\Get-ManningLibrary.ps1 -MaxDownloads 1
```

Check that the file opens, and that `manifest.csv` has a row for it with `valid = true` and `status = present`.

## 4. Full run

```powershell
.\Get-ManningLibrary.ps1
```

Leave the terminal open. To stop, press **Ctrl+C**; run the same command again to carry on (an unfinished file starts over). If the session expires during the run, you're asked for a new `JSESSIONID`: copy it from the browser again.

At the end it lists files that failed (run again to retry), books with their code on GitHub, and cancelled or withdrawn MEAPs.

## 5. Verify

```powershell
.\Get-ManningLibrary.ps1 -VerifyOnly
```

Re-checks every file against its SHA-256 in the manifest, without contacting Manning. Use it on backups too (`-Folder E:\Backup\Manning`).

## 6. Compare with the other libraries

```powershell
.\Get-ManningLibrary.ps1 -CompareWith "$env:USERPROFILE\OneDrive\Documents\HumbleBundle"
.\Get-ManningLibrary.ps1 -CompareWith "$env:USERPROFILE\OneDrive\Documents\PacktPub"
```

**same-isbn** files are the same book (matched by an ISBN from Manning's catalogue, inside an EPUB, in the other library's manifest, or in a file name). **same-title** files have exactly the same title: check them by hand. Which copy to keep is decided in Calibre.

## Next time (new purchases)

Run step 4 again. Only new files are downloaded.
