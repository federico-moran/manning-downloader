<#
.SYNOPSIS
    Downloads the ebooks you own on Manning, checking that each file is complete.

.DESCRIPTION
    Uses your Manning session cookie (JSESSIONID). The first time, paste it when asked; it is saved encrypted
    for your Windows account (DPAPI) under %LOCALAPPDATA%\manning-downloader, never in the repo. When it
    expires (Manning sends the script to its login page), you are asked again. -ResetSession forgets it.

    Every run reads your bookshelf (the dashboard's list) and Manning's public catalog (for ISBNs), and saves
    both as manning-library.json in the folder: books, liveProjects and liveVideos, with MEAP versions.
    Files are downloaded one at a time, to <name>.part, checked (a complete PDF, EPUB, Kindle file or zip of
    the format asked for), and only then given their real name and recorded in manifest.csv. A file that
    fails the check is downloaded once more, then recorded as failed so the next run retries it.

    Manning gives no size or hash for its files, and stamps each download with your details, so two downloads
    of the same book differ. The SHA-256 in the manifest protects your copy from then on (-VerifyOnly).

    Files already in the manifest are skipped. Code on GitHub is recorded as a link, not downloaded.
    liveProjects and liveVideos are listed in manning-library.json only. Use -WhatIf to see the plan.

    The files carry your name and email (Manning's watermark): don't share them.

.EXAMPLE
    .\Get-ManningLibrary.ps1 -WhatIf

.EXAMPLE
    .\Get-ManningLibrary.ps1 -MaxDownloads 1

.EXAMPLE
    .\Get-ManningLibrary.ps1 -Format pdf, epub, kindle, supplement

.EXAMPLE
    .\Get-ManningLibrary.ps1 -VerifyOnly

.EXAMPLE
    .\Get-ManningLibrary.ps1 -CompareWith "$env:USERPROFILE\OneDrive\Documents\HumbleBundle"
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Folder = (Join-Path $env:USERPROFILE 'OneDrive\Documents\Manning'),
    [ValidateSet('pdf', 'epub', 'kindle', 'supplement')]
    [string[]]$Format = @('pdf', 'epub', 'supplement'),
    [switch]$PlainEpub,           # take the EPUB, not the EPUB3, when a book has both
    [int]$MaxDownloads = [int]::MaxValue,
    [int]$DelaySeconds = 5,       # pause between downloads, to stay at a human pace
    [int]$Retries = 3,
    [switch]$VerifyOnly,          # check the folder against manifest.csv, without contacting Manning
    [string]$CompareWith,         # report which files in another folder are also in this library
    [switch]$ResetSession         # forget the saved session cookie and ask for a new one
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\ManningLibrary.psm1') -Force

$manifestPath = Join-Path $Folder 'manifest.csv'
# The common manifest columns shared with the other store tools, then Manning's own.
$columns = 'store', 'id', 'isbn', 'title', 'authors', 'format', 'file', 'bytes', 'sha256', 'valid', 'status', 'drm', 'version', 'added',
    'source_format', 'meap', 'url', 'modified'
$manifest = @(if (Test-Path -LiteralPath $manifestPath) { Import-Csv -LiteralPath $manifestPath })

function Write-Table($Rows, [string[]]$Property) {
    Write-Host ($Rows | Format-Table $Property -AutoSize | Out-String -Width 300).TrimEnd()
}

# ---- Offline modes ----------------------------------------------------------------------------------
if ($VerifyOnly) {
    if (-not $manifest) { throw "No manifest.csv in $Folder." }
    $result = @(Test-Library -Folder $Folder -Manifest $manifest)
    Write-Host ('{0} files: {1}' -f $result.Count, (($result | Group-Object Status | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '))
    $bad = @($result | Where-Object Status -ne 'ok')
    if ($bad) { Write-Table $bad File, Status }
    return
}
if ($CompareWith) {
    if (-not $manifest) { throw "No manifest.csv in $Folder." }
    $result = @(Compare-Library -Manifest $manifest -Library $Folder -Folder $CompareWith)
    Write-Host ('{0} files in {1}: {2}' -f $result.Count, $CompareWith, (($result | Group-Object Status | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '))
    foreach ($s in 'only-there', 'same-title', 'same-isbn', 'identical') {
        $rows = @($result | Where-Object Status -eq $s)
        $note = if ($s -eq 'same-title') { ' (check by hand: different books can share a title)' }
        if ($rows) { Write-Host "`n$s$note"; Write-Table $rows Other, Ours }
    }
    return
}

# ---- Session cookie ---------------------------------------------------------------------------------
$sessionPath = Join-Path $env:LOCALAPPDATA 'manning-downloader\session.xml'
if ($ResetSession -and (Test-Path -LiteralPath $sessionPath)) { Remove-Item -LiteralPath $sessionPath -WhatIf:$false }

function Get-SessionCookie([switch]$Ask) {
    if (-not $Ask -and (Test-Path -LiteralPath $sessionPath)) {
        $secure = Import-Clixml -LiteralPath $sessionPath
    } else {
        Write-Host 'Paste the value of the JSESSIONID cookie: in your browser, logged in to manning.com,'
        Write-Host 'press F12 > Application > Cookies > https://www.manning.com. It is not shown as you paste.'
        $secure = Read-Host -AsSecureString 'Session cookie'
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $sessionPath) -WhatIf:$false
        $secure | Export-Clixml -LiteralPath $sessionPath -WhatIf:$false  # encrypted for this Windows account (DPAPI)
    }
    [Net.NetworkCredential]::new('', $secure).Password.Trim() -replace '^JSESSIONID=', ''
}
$script:cookie = Get-SessionCookie

# Calls Manning as you: a page's content, or a file saved to -OutFile. The cookie goes only with requests to
# www.manning.com, never with code downloads (those are on Amazon S3). Without a valid session Manning
# redirects to login.manning.com, and PowerShell passes the cookie along to that host too; the cookie is
# then asked for again, once.
function Invoke-Manning([string]$Uri, [string]$OutFile) {
    $own = ([uri]$Uri).Host -eq 'www.manning.com'
    for ($attempt = 1; ; $attempt++) {
        $request = @{ Uri = $Uri; SkipHttpErrorCheck = $true }
        if ($own) { $request.Headers = @{ Cookie = "JSESSIONID=$script:cookie" } }
        if ($OutFile) { $request.OutFile = $OutFile; $request.PassThru = $true }
        try {
            $r = Invoke-WebRequest @request
        } catch {
            if ($attempt -gt $Retries) { throw }
            Write-Warning "  $($_.Exception.Message) - retrying in $(10 * $attempt) s"
            Start-Sleep -Seconds (10 * $attempt)
            continue
        }
        $code = [int]$r.StatusCode
        if ($own -and $r.BaseResponse.RequestMessage.RequestUri.Host -eq 'login.manning.com') {
            if ($attempt -gt 1) { throw 'Manning did not accept the new session cookie either.' }
            Write-Warning 'Manning did not accept the session cookie (it has expired, or you logged out).'
            $script:cookie = Get-SessionCookie -Ask
            continue
        }
        if ($code -in 429, 500, 502, 503, 504 -and $attempt -le $Retries) { Start-Sleep -Seconds (10 * $attempt); continue }
        if ($code -ne 200) { throw "Manning answered $code for $Uri" }
        return $r
    }
}

# ---- Bookshelf and catalog ------------------------------------------------------------------------
$null = New-Item -ItemType Directory -Force -Path $Folder -WhatIf:$false
$shelf = (Invoke-Manning 'https://www.manning.com/dashboard/getLicensesAjax?isDropboxIntegrated=&order=purchaseDate&sort=desc&filter=all').Content
$found = @(ConvertFrom-Bookshelf -Html $shelf)
if (-not $found) { throw 'The bookshelf came back empty: Manning may have changed the dashboard. See docs/design.md.' }
$catalog = (Invoke-Manning 'https://www.manning.com/api/search/productsAutocompleteInfo?new=true').Content | ConvertFrom-Json -DateKind String
$items = @(Add-CatalogInfo -Items $found -Catalog $catalog)
[ordered]@{ fetched = (Get-Date).ToString('s'); items = $items } | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $Folder 'manning-library.json') -Encoding utf8NoBOM -WhatIf:$false
Write-Host ('Bookshelf: {0}; saved manning-library.json.' -f (($items | Group-Object Kind | ForEach-Object { "$($_.Count) $($_.Name)s" }) -join ', '))

# ---- Plan -------------------------------------------------------------------------------------------
foreach ($row in $manifest) {  # recorded but deleted since: download again
    if ($row.status -eq 'present' -and -not (Test-Path -LiteralPath (Join-Path $Folder $row.file))) { $row.status = 'missing' }
}
$plan = @(Get-DownloadPlan -Items $items -Format $Format -PlainEpub:$PlainEpub -Manifest $manifest)
$todo = @($plan | Where-Object Action -eq 'download' | Select-Object -First $MaxDownloads)
Write-Host ('Plan: {0}. This run: {1} files.' -f (($plan | Group-Object Action | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '), $todo.Count)

$rows = [ordered]@{}  # "id|format" -> manifest row
foreach ($r in $manifest) { $rows["$($r.id)|$($r.format)"] = $r }
function Save-Manifest {
    if ($WhatIfPreference) { return }
    $rows.Values | Select-Object $columns | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding utf8BOM -WhatIf:$false
}
function Set-Row($Item, [string]$Status, [string]$Valid = '') {
    $key = "$($Item.Id)|$($Item.Format)"
    $old = $rows[$key]
    $path = if ($Item.File) { Join-Path $Folder $Item.File }
    $present = $path -and $Status -eq 'present'
    $rows[$key] = [pscustomobject]@{
        store = 'manning'; id = $Item.Id; isbn = $Item.Isbn; title = $Item.Title; authors = $Item.Authors; format = $Item.Format
        file = $Item.File
        bytes = $(if ($present) { (Get-Item -LiteralPath $path).Length })
        sha256 = $(if ($present) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() })
        valid = $Valid; status = $Status; drm = 'none'; version = $Item.Version
        added = $(if ($old.added) { $old.added } else { (Get-Date).ToString('s') })
        source_format = $Item.SourceFormat; meap = $Item.Meap; url = $Item.Url
        modified = $(if ($present) { (Get-Item -LiteralPath $path).LastWriteTimeUtc.ToString('s') + 'Z' })
    }
}
foreach ($p in $plan | Where-Object Action -eq 'link') { Set-Row $p 'link' }
foreach ($p in $plan | Where-Object Action -eq 'skip') {
    # The version stays the one downloaded; the catalog may have found an ISBN since.
    $row = $rows["$($p.Id)|$($p.Format)"]
    if (-not $row.isbn -and $p.Isbn) { $row.isbn = $p.Isbn }
}
Save-Manifest

# ---- Download ---------------------------------------------------------------------------------------
$failed = New-Object Collections.Generic.List[object]
for ($n = 0; $n -lt $todo.Count; $n++) {
    $p = $todo[$n]
    if (-not $PSCmdlet.ShouldProcess("$($p.File) ($($p.Title))", 'download')) { continue }
    Write-Host ('({0}/{1}) {2}' -f ($n + 1), $todo.Count, $p.File)
    $part = Join-Path $Folder "$($p.File).part"
    $ok = $false
    foreach ($try in 1, 2) {  # a file that fails the check is downloaded once more
        try {
            $null = Invoke-Manning $p.Url -OutFile $part  # Manning gives no size, so a download always starts over
            $ok = Test-DownloadedFile -Path $part -Format $p.Format
            if (-not $ok) {
                $type = Get-BookFileType -Path $part
                Write-Warning ('  Not a complete {0}: {1}' -f $p.Format, $(if ($type) { "got a $type" } else { 'damaged, cut off, or a web page' }))
            }
        } catch {
            Write-Warning "  $($_.Exception.Message)"
        }
        if ($ok) { break }
    }
    if ($ok) {
        Move-Item -LiteralPath $part -Destination (Join-Path $Folder $p.File) -Force
        if (-not $p.Isbn -and $p.Format -eq 'epub') {
            # Not in Manning's catalog (a withdrawn book): the EPUB's own ISBN, for its other files too.
            $isbn = Get-EpubIsbn -Path (Join-Path $Folder $p.File) | Select-Object -First 1
            if ($isbn) {
                $p.Isbn = $isbn
                foreach ($r in $rows.Values | Where-Object { $_.id -eq "$($p.Id)" -and -not $_.isbn }) { $r.isbn = $isbn }
                foreach ($q in $todo | Where-Object { $_.Id -eq $p.Id }) { $q.Isbn = $isbn }
            }
        }
        Set-Row $p 'present' 'true'
    } else {
        Remove-Item -LiteralPath $part -ErrorAction SilentlyContinue
        $failed.Add($p)
        Set-Row $p 'failed' 'false'
    }
    Save-Manifest
    if ($n -lt $todo.Count - 1) { Start-Sleep -Seconds $DelaySeconds }
}

# ---- Summary ----------------------------------------------------------------------------------------
Write-Host ''
$withdrawn = @($items | Where-Object { $_.Kind -eq 'book' -and ($_.Cancelled -or -not $_.InCatalog) })
$links = @($plan | Where-Object Action -eq 'link')
if ($withdrawn) {
    Write-Host "$($withdrawn.Count) books are canceled MEAPs or no longer in Manning's catalog (downloaded like the others; a refund or exchange is up to you, on the dashboard):"
    Write-Table ($withdrawn | Select-Object Title, @{ n = 'State'; e = { if ($_.Cancelled) { 'canceled' } else { 'not in catalog' } } }) Title, State
}
if ($links) { Write-Host "$($links.Count) books have their code on GitHub (recorded in the manifest as links):"; Write-Table $links Title, Url }
if ($failed) { Write-Warning "$($failed.Count) files failed (recorded as failed; the next run retries them):"; Write-Table $failed File, Title }
if (-not $WhatIfPreference) { Write-Host "Done: $($todo.Count - $failed.Count) of $($todo.Count) downloaded and checked. Manifest: $manifestPath" }
