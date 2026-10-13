<#
.SYNOPSIS
    Adds the library's EPUBs to Calibre, tagged Manning (and MEAP, MEAP cancelled).

.DESCRIPTION
    Reads manifest.csv in the library folder and adds every EPUB that isn't in Calibre yet. A book is
    recognised by its EPUB's SHA-256, so a second run adds nothing, and books added by hand are found too.
    Books already in Calibre get any of those tags they lack; their other tags are kept.
    PDFs (the free samplers among them) and code are left out.

    Calibre must be closed. Before changing anything, metadata.db is copied to metadata.db.<date>.bak in
    the Calibre library. Use -WhatIf to see what would be done.

.EXAMPLE
    .\Update-Calibre.ps1 -WhatIf

.EXAMPLE
    .\Update-Calibre.ps1 -MaxBooks 1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Folder = (Join-Path $env:USERPROFILE 'OneDrive\Documents\Manning'),
    [string]$CalibreLibrary,  # default: the library Calibre last used
    [string]$CalibreDb = (Join-Path $env:ProgramFiles 'Calibre2\calibredb.exe'),
    [string]$SourceTag = 'Manning',
    [int]$MaxBooks = [int]::MaxValue  # add at most this many books, e.g. 1 for a first test
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8  # calibredb prints UTF-8
Import-Module (Join-Path $PSScriptRoot 'src\ManningLibrary.psm1') -Force

if (-not (Test-Path -LiteralPath $CalibreDb)) { throw "calibredb not found at $CalibreDb (use -CalibreDb)." }
if (Get-Process -Name calibre -ErrorAction SilentlyContinue) { throw 'Close Calibre first: calibredb cannot change the library while it is open.' }
if (-not $CalibreLibrary) {
    $settings = Join-Path $env:APPDATA 'calibre\global.py.json'
    if (Test-Path -LiteralPath $settings) { $CalibreLibrary = (Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json).library_path }
    if (-not $CalibreLibrary) { throw 'Could not find the Calibre library (use -CalibreLibrary).' }
}
$manifestPath = Join-Path $Folder 'manifest.csv'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "No manifest.csv in $Folder." }
$manifest = @(Import-Csv -LiteralPath $manifestPath)

# The books in Calibre, as the arguments of Get-CalibrePlan: InCalibre, the EPUBs that could be from this
# library (SHA-256 -> @{ id; tags }), and ByTitle, every book by its title keys. Only files with the size of
# one of the library's EPUBs are hashed, so the other books in Calibre cost almost nothing.
function Get-InCalibre {
    $json = & $CalibreDb list --library-path $CalibreLibrary --fields 'title,formats,tags' --for-machine
    if ($LASTEXITCODE) { throw "calibredb list failed (exit code $LASTEXITCODE)." }
    $books = @(($json -join "`n") | ConvertFrom-Json)
    $sizes = @{}
    foreach ($r in $manifest | Where-Object { $_.status -eq 'present' -and $_.format -eq 'epub' }) { $sizes[[long]$r.bytes] = $true }
    $found = @{}; $byTitle = @{}
    foreach ($b in $books) {
        $book = @{ id = $b.id; tags = @($b.tags); title = $b.title }
        foreach ($k in Get-CalibreTitleKey $b.title) { $byTitle[$k] = @($byTitle[$k]) + $book | Where-Object { $_ } }
        foreach ($f in @($b.formats) | Where-Object { $_ -like '*.epub' }) {
            if (-not (Test-Path -LiteralPath $f) -or -not $sizes[(Get-Item -LiteralPath $f).Length]) { continue }
            $found[(Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant()] = $book
        }
    }
    Write-Host "Calibre library: $CalibreLibrary ($($books.Count) books)"
    @{ InCalibre = $found; ByTitle = $byTitle }
}

$inCalibre = Get-InCalibre
$plan = @(Get-CalibrePlan -Manifest $manifest @inCalibre -SourceTag $SourceTag)
$toAdd = @($plan | Where-Object Action -eq 'add' | Select-Object -First $MaxBooks)
$toTag = @($plan | Where-Object Action -eq 'tag')
Write-Host ('{0} EPUBs in the library: {1}.' -f $plan.Count, (($plan | Group-Object Action | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '))
# Books found by title are in Calibre with another store's copy: list them, to check they are the same book.
$byTitle = @($plan | Where-Object Match -eq 'title')
if ($byTitle) {
    Write-Host "`nIn Calibre with another copy (same title), given the Manning tag but not added again:"
    $byTitle | ForEach-Object { "  $($_.Title)  ->  #$($_.Id) $(@($inCalibre.ByTitle[$_.Title.Trim().ToLowerInvariant()])[0].title)" } | Out-Host
}
$toCheck = @($plan | Where-Object Action -eq 'check')
if ($toCheck) {
    Write-Host "`nSeveral books in Calibre have these titles; nothing done, check by hand:"
    $toCheck | ForEach-Object { "  $($_.Title)" } | Out-Host
}

if (($toAdd -or $toTag) -and -not $WhatIfPreference) {
    $backup = Join-Path $CalibreLibrary ('metadata.db.{0}.bak' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath (Join-Path $CalibreLibrary 'metadata.db') -Destination $backup
    Write-Host "Backed up the Calibre database to $backup"
}

# ---- Add: books with the same tags go in one calibredb call, at most 40 at a time ----------------------
$added = 0; $failed = 0
foreach ($group in $toAdd | Group-Object { $_.Tags -join ',' }) {
    $items = @($group.Group)
    for ($i = 0; $i -lt $items.Count; $i += 40) {
        $batch = @($items[$i..([Math]::Min($i + 39, $items.Count - 1))])
        if (-not $PSCmdlet.ShouldProcess("$($batch.Count) books ($(($batch.File) -join ', '))", "add, tagged $($group.Name)")) { continue }
        # An array even for one book: splatting a single string passes each character as an argument, and
        # calibredb then reads "\" and "." as folders and adds whatever is in them.
        $paths = @($batch | ForEach-Object { Join-Path $Folder $_.File })
        $absent = @($paths | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
        if ($absent) { throw "Not found, nothing added: $($absent -join ', ')" }
        # --duplicates: books are matched by SHA-256 above; Calibre's own check goes by title, and different
        # books can share one (O'Reilly's and Packt's "Bash Cookbook").
        $out = & $CalibreDb add --library-path $CalibreLibrary --duplicates --tags $group.Name @paths
        if ($LASTEXITCODE) { Write-Warning "calibredb add failed (exit code $LASTEXITCODE): $($out -join ' ')"; $failed += $batch.Count }
        else { $added += $batch.Count; Write-Host "  Added $added of $($toAdd.Count)" }
    }
}

# ---- Tag books already in Calibre ---------------------------------------------------------------------
$tagged = 0
foreach ($t in $toTag) {
    if (-not $PSCmdlet.ShouldProcess("#$($t.Id) $($t.Title)", "set tags $($t.Tags -join ', ')")) { continue }
    $null = & $CalibreDb set_metadata --library-path $CalibreLibrary $t.Id --field "tags:$($t.Tags -join ',')"
    if ($LASTEXITCODE) { Write-Warning "Could not tag #$($t.Id) $($t.Title) (exit code $LASTEXITCODE)"; $failed++ } else { $tagged++ }
}

# ---- Check: every book added is now found in Calibre by its SHA-256 ---------------------------------------
Write-Host ''
if ($WhatIfPreference) {
    Write-Host "Would add $($toAdd.Count) books and tag $($toTag.Count) (nothing changed: -WhatIf)."
    return
}
if ($added -or $tagged) {
    $books = Get-InCalibre
    $after = @(Get-CalibrePlan -Manifest $manifest @books -SourceTag $SourceTag)
    $inCalibre = @($after | Where-Object Action -eq 'skip').Count
    Write-Host "Added $added and tagged $tagged$(if ($failed) { "; $failed failed" }). Now $inCalibre of $($after.Count) EPUBs are in Calibre with their tags."
    # A book added this run must be found by its file: found by title, it would be found as itself.
    $notFound = @($toAdd | Where-Object { $_.File -in @($after | Where-Object Match -ne 'file').File })
    if ($notFound) { Write-Warning "$($notFound.Count) books added this run are not found by SHA-256 (Calibre may have changed the file):"; $notFound | ForEach-Object { "  $($_.File)" } | Out-Host }
} else {
    Write-Host 'Nothing to do: every EPUB is in Calibre with its tags.'
}
