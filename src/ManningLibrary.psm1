# Logic for Get-ManningLibrary.ps1, kept free of network calls so it can be tested.

$script:base = 'https://www.manning.com'

# The bookshelf as the dashboard gets it (getLicensesAjax: an HTML table, one row per product you own),
# as one item per row: books, liveProjects and liveVideos alike.
function ConvertFrom-Bookshelf {
    [CmdletBinding()]
    param([string]$Html)
    $decode = { param($s) [Net.WebUtility]::HtmlDecode(($s -replace '<[^>]+>', '' -replace '\s+', ' ')).Trim() }
    foreach ($m in [regex]::Matches($Html, '(?s)<tr([^>]*class="license-row"[^>]*)>(.*?)</tr>')) {
        $attrs = $m.Groups[1].Value
        $row = $m.Groups[2].Value
        $kind = if ($attrs -match 'is-book="true"') { 'book' } elseif ($attrs -match 'is-video="true"') { 'video' }
            elseif ($row -match 'liveproject\.manning\.com') { 'project' } else { 'other' }
        $formats = [ordered]@{}
        $id = $null
        foreach ($d in [regex]::Matches($row, 'productId=(\d+)&(?:amp;)?downloadFormat=(\w+)')) {
            $id = [int]$d.Groups[1].Value
            $formats[$d.Groups[2].Value.ToUpperInvariant()] = $true
        }
        if (-not $id -and $row -match 'data-product-id="(\d+)"') { $id = [int]$Matches[1] }
        $title = if ($row -match 'data-sort="([^"]*)"') { & $decode $Matches[1] }
        # The foreword line follows a <br>: only the authors before it.
        $authors = if ($row -match '(?s)class="product-authorship">(.*?)</div>') { & $decode ($Matches[1] -split '<br\s*/?>')[0] }
        $meap = [regex]::Match($row, 'meap-last-updated">\s*version:\s*(\d+),\s*last updated:\s*([\d-]+)')
        [pscustomobject]@{
            Kind        = $kind
            Id          = $id
            Title       = $title
            Authors     = $authors
            Slug        = if ($row -match 'href="/books/([^"/?]+)"') { $Matches[1] }
            Link        = if ($row -match '(?s)product-cover-image-column">\s*<a href="([^"]+)"') { [Net.WebUtility]::HtmlDecode($Matches[1]) }
            IsMeap      = $attrs -match 'is-meap="true"'
            MeapVersion = if ($meap.Success) { [int]$meap.Groups[1].Value }
            MeapUpdated = if ($meap.Success) { $meap.Groups[2].Value }
            Cancelled   = $row -match 'class="meap-cancelled"'
            Formats     = @($formats.Keys)
            CodeUrl     = if ($row -match '<a href="([^"]+)"[^>]*title="download code samples"') { [Net.WebUtility]::HtmlDecode($Matches[1]) }
        }
    }
}

# Adds what Manning's public catalogue (productsAutocompleteInfo) says about each item, matched by product ID:
# ISBN, last update, subtitle, tags, and the newer edition if there is one. Withdrawn products aren't in it.
function Add-CatalogInfo {
    [CmdletBinding()]
    param([object[]]$Items, [object[]]$Catalog)
    $byId = @{}
    foreach ($p in $Catalog) { if ($null -ne $p.id) { $byId[[int]$p.id] = $p } }
    $owned = @{}
    foreach ($i in $Items) { if ($i.Id) { $owned[[int]$i.Id] = $true } }
    foreach ($i in $Items) {
        $p = if ($i.Id) { $byId[[int]$i.Id] }
        $next = if ($p.nextEdition) { [int]$p.nextEdition }
        $info = [ordered]@{
            InCatalog        = [bool]$p
            Isbn             = if ($p.isbn) { ConvertTo-Isbn13 $p.isbn }
            # The date as Manning wrote it (read the JSON with -DateKind String); a parsed date is taken as it is.
            LastUpdated      = if ($p.lastSignificantDate -is [datetime]) { $p.lastSignificantDate.ToString('yyyy-MM-dd') }
                elseif ($p.lastSignificantDate) { ([string]$p.lastSignificantDate).Substring(0, 10) }
            Subtitle         = $p.subtitle
            Tags             = @($p.tags | Where-Object { $_ })
            NextEdition      = $next
            NextEditionTitle = if ($next) { $byId[$next].title }
            NextEditionOwned = [bool]($next -and $owned[$next])
        }
        $copy = $i.PSObject.Copy()
        foreach ($k in $info.Keys) { $copy | Add-Member -NotePropertyName $k -NotePropertyValue $info[$k] -Force }
        $copy
    }
}

# A title as a file name Windows accepts: "Title: Subtitle" becomes "Title - Subtitle".
function ConvertTo-FileName([string]$Title) {
    $s = $Title -replace ':', ' -' -replace '[/\\]', '-' -replace '"', "'" -replace '[<>|?*\x00-\x1F]', ''
    ($s -replace '\s+', ' ').Trim().TrimEnd('.', ' ')
}

# What to do with each file of each book: one item per book and format, with the action to take.
# Formats: pdf, epub (the EPUB3 when offered, unless -PlainEpub), kindle (.mobi) and supplement (the code).
# Code on GitHub is a repository, not a file: it is recorded as a link.
function Get-DownloadPlan {
    [CmdletBinding()]
    param(
        [object[]]$Items,
        [string[]]$Format = @('pdf', 'epub', 'supplement'),
        [switch]$PlainEpub,
        [object[]]$Manifest = @()  # rows of manifest.csv from earlier runs
    )
    $have = @{}   # "id|format" -> manifest row of a file already downloaded, or a link already recorded
    $taken = @{}  # file name -> "id|format" of the file using it
    foreach ($row in $Manifest) {
        $key = "$($row.id)|$($row.format)"
        if ($row.file) { $taken[$row.file] = $key }
        if ($row.status -in 'present', 'link') { $have[$key] = $row }
    }
    foreach ($item in $Items | Where-Object { $_.Kind -eq 'book' -and $_.Id }) {
        $name = ConvertTo-FileName $item.Title
        $version = if ($item.IsMeap -and $item.MeapVersion) { 'MEAP v{0} ({1})' -f $item.MeapVersion, $item.MeapUpdated } else { $item.LastUpdated }
        $meap = if ($item.Cancelled) { 'cancelled' } elseif ($item.IsMeap) { 'meap' }
        foreach ($fmt in 'pdf', 'epub', 'kindle', 'supplement' | Where-Object { $_ -in $Format }) {
            $source = switch ($fmt) {
                'pdf' { if ('PDF' -in $item.Formats) { 'PDF' } }
                'epub' { if ('EPUB3' -in $item.Formats -and -not $PlainEpub) { 'EPUB3' } elseif ('EPUB' -in $item.Formats) { 'EPUB' } }
                'kindle' { if ('KINDLE' -in $item.Formats) { 'KINDLE' } }
                'supplement' { if ($item.CodeUrl) { 'CODE' } }
            }
            if (-not $source) { continue }
            $key = "$($item.Id)|$fmt"
            $action = 'download'
            $url = "$script:base/dashboard/download?productId=$($item.Id)&downloadFormat=$source"
            $file = switch ($fmt) { 'pdf' { "$name.pdf" } 'epub' { "$name.epub" } 'kindle' { "$name.mobi" } 'supplement' { "$name - code.zip" } }
            if ($fmt -eq 'supplement') {
                $url = $item.CodeUrl
                $path = ([uri]$url).AbsolutePath
                if (([uri]$url).Host -ne 'manning-content.s3.amazonaws.com') { $action = 'link'; $file = '' }
                elseif ($path -match '(\.tar\.gz|\.tgz)$') { $file = "$name - code$($Matches[1])" }  # not every book's code is a zip
            }
            if ($have[$key]) {
                $action = 'skip'
                $file = $have[$key].file
            } elseif ($file -and $taken[$file] -and $taken[$file] -ne $key) {
                # Another book has this name (same title): tell them apart by Manning's ID.
                $file = '{0} ({1}){2}' -f $file.Substring(0, $file.Length - [IO.Path]::GetExtension($file).Length), $item.Id, [IO.Path]::GetExtension($file)
            }
            if ($file) { $taken[$file] = $key }
            [pscustomobject]@{
                Action       = $action
                Id           = $item.Id
                Format       = $fmt
                SourceFormat = $source
                File         = $file
                Url          = $url
                Title        = $item.Title
                Authors      = $item.Authors
                Isbn         = $item.Isbn
                Version      = $version
                Meap         = $meap
            }
        }
    }
}

# What a downloaded file really is, judged by its content: 'pdf', 'epub', 'mobi', 'zip' or 'gzip' when it is
# complete, otherwise nothing (an HTML page, such as the login page, is nothing).
function Get-BookFileType {
    [CmdletBinding()]
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        # A zip's index is at its end, so a cut-off zip can't be opened.
        $zip = [IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $first = $zip.Entries | Select-Object -First 1
            if ($first.FullName -eq 'mimetype') {
                $r = New-Object IO.StreamReader($first.Open())
                try { if ($r.ReadToEnd().Trim() -eq 'application/epub+zip') { return 'epub' } } finally { $r.Dispose() }
            }
            return 'zip'
        } finally { $zip.Dispose() }
    } catch [IO.InvalidDataException] { }  # not a zip, or a cut-off one
    $s = [IO.File]::OpenRead($Path)
    try {
        $head = New-Object byte[] 68
        $n = $s.Read($head, 0, 68)
        if ($n -ge 5 -and [Text.Encoding]::ASCII.GetString($head, 0, 5) -eq '%PDF-') {
            $n = [int][Math]::Min(2048, $s.Length)
            $null = $s.Seek(-$n, 'End')
            $tail = New-Object byte[] $n
            $null = $s.Read($tail, 0, $n)
            if ([Text.Encoding]::ASCII.GetString($tail).Contains('%%EOF')) { return 'pdf' }  # no end marker: cut off
        } elseif ($n -ge 68 -and [Text.Encoding]::ASCII.GetString($head, 60, 8) -eq 'BOOKMOBI') {
            return 'mobi'  # Kindle (MOBI or AZW3)
        } elseif ($n -ge 18 -and $head[0] -eq 0x1f -and $head[1] -eq 0x8b) {
            # A gzip (.tgz). .NET reads a cut-off one without complaint, so compare what it decompresses with
            # the size the gzip records in its last 4 bytes (modulo 4 GB).
            $null = $s.Seek(-4, 'End')
            $tail = New-Object byte[] 4
            $null = $s.Read($tail, 0, 4)
            $recorded = [BitConverter]::ToUInt32($tail, 0)
            $null = $s.Seek(0, 'Begin')
            $gz = [IO.Compression.GZipStream]::new($s, [IO.Compression.CompressionMode]::Decompress, $true)
            try {
                $buffer = New-Object byte[] 65536
                [long]$total = 0
                while (($read = $gz.Read($buffer, 0, $buffer.Length)) -gt 0) { $total += $read }
                if (($total % 4294967296) -eq $recorded) { return 'gzip' }
            } catch [IO.InvalidDataException] { } finally { $gz.Dispose() }
        }
    } finally { $s.Dispose() }
}

# Whether a downloaded file is complete and of the format asked for. Manning publishes no size or hash, and
# its watermark makes every download different, so the file's structure is the only check there is.
function Test-DownloadedFile {
    [CmdletBinding()]
    param([string]$Path, [string]$Format)
    $expected = @{ pdf = @('pdf'); epub = @('epub'); kindle = @('mobi'); supplement = @('zip', 'gzip') }[$Format]
    (Get-BookFileType -Path $Path) -in $expected
}

# Checks the folder against the manifest without contacting Manning (-VerifyOnly), e.g. for a backup copy.
function Test-Library {
    [CmdletBinding()]
    param([string]$Folder, [object[]]$Manifest)
    foreach ($row in $Manifest | Where-Object { $_.status -eq 'present' -and $_.file }) {
        $path = Join-Path $Folder $row.file
        $status = if (-not (Test-Path -LiteralPath $path)) { 'missing' }
            elseif ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $row.sha256) { 'changed' }
            else { 'ok' }
        [pscustomobject]@{ File = $row.file; Status = $status }
    }
    foreach ($part in Get-ChildItem -LiteralPath $Folder -Filter '*.part' -File) {
        [pscustomobject]@{ File = $part.Name; Status = 'unfinished' }
    }
}

# A string as an ISBN-13 (an ISBN-10 is converted), or nothing when it isn't a valid ISBN.
function ConvertTo-Isbn13([string]$Text) {
    $s = ($Text -replace '^\s*(urn:)?(isbn)?\W*', '' -replace '[\s-]', '').ToUpperInvariant()
    if ($s -match '^\d{9}[\dX]$') {
        $sum = 0
        for ($i = 0; $i -lt 10; $i++) { $sum += (10 - $i) * $(if ($s[$i] -eq 'X') { 10 } else { [int][string]$s[$i] }) }
        if ($sum % 11) { return }
        $s = '978' + $s.Substring(0, 9)
    } elseif ($s -notmatch '^97[89]\d{10}$') { return }
    $sum = 0
    for ($i = 0; $i -lt 12; $i++) { $sum += [int][string]$s[$i] * (1 + 2 * ($i % 2)) }
    $check = (10 - $sum % 10) % 10
    if ($s.Length -eq 13 -and [int][string]$s[12] -ne $check) { return }
    $s.Substring(0, 12) + $check
}

# The ISBNs an EPUB gives for itself (the identifiers in its package file), as ISBN-13s.
# Often both the print and the ebook ISBN.
function Get-EpubIsbn {
    [CmdletBinding()]
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try { $zip = [IO.Compression.ZipFile]::OpenRead($Path) } catch { return }  # missing, not a zip, or cut off
    try {
        $read = { param($entry) $r = New-Object IO.StreamReader($entry.Open()); try { $r.ReadToEnd() } finally { $r.Dispose() } }
        $opf = $null
        $container = $zip.GetEntry('META-INF/container.xml')
        if ($container -and (& $read $container) -match 'full-path="([^"]+)"') { $opf = $zip.GetEntry($Matches[1]) }
        if (-not $opf) { $opf = $zip.Entries | Where-Object FullName -like '*.opf' | Select-Object -First 1 }
        if (-not $opf) { return }
        [regex]::Matches((& $read $opf), '<(?:dc:)?identifier[^>]*>([^<]+)<') |
            ForEach-Object { ConvertTo-Isbn13 $_.Groups[1].Value } | Select-Object -Unique
    } finally { $zip.Dispose() }
}

# Compares another folder (the Humble or PacktPub library, an old download folder) with this library
# (-CompareWith). Each file there is reported with the file here it matches: 'identical' (same SHA-256),
# 'same-isbn' (an ISBN in common), 'same-title' (exactly the same title, to check by hand: different books
# can share a title), or 'only-there'. Subfolders are included.
function Compare-Library {
    [CmdletBinding()]
    param(
        [object[]]$Manifest,
        [string]$Library,  # this library's folder, to read the ISBNs in its EPUBs
        [string]$Folder
    )
    # Titles and file names compared as letters and digits only, without a leading "The".
    $key = { param($s) ([string]$s).ToLowerInvariant() -replace '^the[\W_]+', '' -replace '[^\p{L}\p{N}]', '' }
    $byHash = @{}
    $byId = @{}     # Manning ID -> its files here (a book's PDF and EPUB share an ID)
    $byIsbn = @{}   # ISBN -> ID, from the manifest (Manning's catalogue) and the book's EPUB
    $byTitle = @{}  # normalised title -> ID
    foreach ($row in $Manifest | Where-Object { $_.status -eq 'present' -and $_.file }) {
        $byHash[$row.sha256.ToLowerInvariant()] = $row
        $byId[$row.id] = @($byId[$row.id]) + $row | Where-Object { $_ }
        $title = & $key $row.title
        if ($title -and -not $byTitle.Contains($title)) { $byTitle[$title] = $row.id }
        if ($row.isbn) { $byIsbn[$row.isbn] = $row.id }
        if ($row.format -eq 'epub') {
            foreach ($isbn in Get-EpubIsbn -Path (Join-Path $Library $row.file)) { $byIsbn[$isbn] = $row.id }
        }
    }
    $root = (Resolve-Path -LiteralPath $Folder).Path.TrimEnd('\') + '\'
    # A folder with its own manifest (the PacktPub library names files by ISBN) gives titles and ISBNs.
    $titles = @{}
    $isbns = @{}
    $otherManifest = Join-Path $Folder 'manifest.csv'
    if (Test-Path -LiteralPath $otherManifest) {
        foreach ($r in Import-Csv -LiteralPath $otherManifest) {
            if ($r.file -and $r.title) { $titles[$r.file] = $r.title }
            if ($r.file -and $r.isbn) { $isbns[$r.file] = $r.isbn }
        }
    }
    $books = @(Get-ChildItem -LiteralPath $Folder -File -Recurse | Where-Object Extension -notin '.csv', '.json', '.txt')
    # An EPUB's ISBNs also count for the files beside it with the same name (its PDF, say).
    $epubIsbns = @{}
    foreach ($f in $books | Where-Object Extension -eq '.epub') {
        $epubIsbns[(Join-Path $f.DirectoryName $f.BaseName)] = @(Get-EpubIsbn -Path $f.FullName)
    }
    foreach ($f in $books) {
        $match = $byHash[(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()]
        $status = 'identical'
        if (-not $match) {
            $found = @($epubIsbns[(Join-Path $f.DirectoryName $f.BaseName)]) + (ConvertTo-Isbn13 $isbns[$f.Name]) + (ConvertTo-Isbn13 $f.BaseName) |
                Where-Object { $_ -and $byIsbn[$_] } | Select-Object -First 1
            $id = $byIsbn["$found"]
            $status = 'same-isbn'
            if (-not $id) {
                $id = $byTitle[(& $key $(if ($titles[$f.Name]) { $titles[$f.Name] } else { $f.BaseName }))]
                $status = if ($id) { 'same-title' } else { 'only-there' }
            }
            if ($id) {
                # Our copy in the same format, if we have one.
                $mine = @($byId[$id])
                $match = $mine | Where-Object { [IO.Path]::GetExtension($_.file) -eq $f.Extension } | Select-Object -First 1
                if (-not $match) { $match = $mine[0] }
            }
        }
        [pscustomobject]@{ Other = $f.FullName.Substring($root.Length); Status = $status; Ours = $match.file }
    }
}

Export-ModuleMember -Function ConvertFrom-Bookshelf, Add-CatalogInfo, Get-DownloadPlan, Get-BookFileType, Test-DownloadedFile,
    Test-Library, ConvertTo-Isbn13, Get-EpubIsbn, Compare-Library
