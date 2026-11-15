BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\ManningLibrary.psm1') -Force
    Add-Type -AssemblyName System.IO.Compression

    function New-TestFile([string]$Name, [string]$Text) {
        $path = Join-Path $TestDrive $Name
        [IO.File]::WriteAllText($path, $Text)
        $path
    }
    # A zip whose entries are written in the given order (an EPUB's first entry is "mimetype").
    function New-TestZip([string]$Name, [hashtable[]]$Entries) {
        $path = Join-Path $TestDrive $Name
        $zip = [IO.Compression.ZipFile]::Open($path, 'Create')
        foreach ($e in $Entries) {
            $w = New-Object IO.StreamWriter($zip.CreateEntry($e.Name).Open())
            $w.Write($e.Text); $w.Dispose()
        }
        $zip.Dispose()
        $path
    }
    # A gzip of random bytes, which don't compress, so cutting its end loses data.
    function New-TestGzip([string]$Name) {
        $path = Join-Path $TestDrive $Name
        $data = New-Object byte[] 50000
        (New-Object Random 1).NextBytes($data)
        $gz = [IO.Compression.GZipStream]::new([IO.File]::Create($path), [IO.Compression.CompressionMode]::Compress)
        $gz.Write($data, 0, $data.Length); $gz.Dispose()
        $path
    }
    # A Mobipocket file: its type and creator, "BOOKMOBI", are at byte 60 of the header.
    function New-TestMobi([string]$Name) {
        $path = Join-Path $TestDrive $Name
        $bytes = New-Object byte[] 200
        [Text.Encoding]::ASCII.GetBytes('Some Title').CopyTo($bytes, 0)
        [Text.Encoding]::ASCII.GetBytes('BOOKMOBI').CopyTo($bytes, 60)
        [IO.File]::WriteAllBytes($path, $bytes)
        $path
    }
}

Describe 'Get-BookFileType' {
    It 'recognizes a complete PDF' {
        $path = New-TestFile 'whole.pdf' "%PDF-1.7`n1 0 obj`n<<>>`nendobj`ntrailer`n<<>>`n%%EOF`n"
        Get-BookFileType -Path $path | Should -Be 'pdf'
    }

    It 'returns nothing for a PDF that was cut off before its end marker' {
        $path = New-TestFile 'cut.pdf' "%PDF-1.7`n1 0 obj`n<<>>`nendo"
        Get-BookFileType -Path $path | Should -BeNullOrEmpty
    }

    It 'recognizes an EPUB by its first entry' {
        $path = New-TestZip 'book.epub' @(
            @{ Name = 'mimetype'; Text = 'application/epub+zip' }
            @{ Name = 'OEBPS/content.opf'; Text = '<package/>' })
        Get-BookFileType -Path $path | Should -Be 'epub'
    }

    It 'recognizes any other complete zip as a zip' {
        $path = New-TestZip 'code.zip' @(@{ Name = 'chapter1/example.py'; Text = 'print("hi")' })
        Get-BookFileType -Path $path | Should -Be 'zip'
    }

    It 'returns nothing for a zip that was cut off (its index at the end is missing)' {
        $whole = New-TestZip 'whole.zip' @(@{ Name = 'a.txt'; Text = ('x' * 5000) })
        $bytes = [IO.File]::ReadAllBytes($whole)
        $path = Join-Path $TestDrive 'cut.zip'
        [IO.File]::WriteAllBytes($path, $bytes[0..($bytes.Length - 40)])
        Get-BookFileType -Path $path | Should -BeNullOrEmpty
    }

    It 'recognizes a complete gzip (a .tgz of code)' {
        Get-BookFileType -Path (New-TestGzip 'code.tgz') | Should -Be 'gzip'
    }

    It 'returns nothing for a gzip that was cut off (.NET reads one without complaint)' {
        $bytes = [IO.File]::ReadAllBytes((New-TestGzip 'whole.tgz'))
        $path = Join-Path $TestDrive 'cut.tgz'
        [IO.File]::WriteAllBytes($path, $bytes[0..($bytes.Length - 2000)])
        Get-BookFileType -Path $path | Should -BeNullOrEmpty
    }

    It 'recognizes a Kindle (Mobipocket) file' {
        Get-BookFileType -Path (New-TestMobi 'book.mobi') | Should -Be 'mobi'
    }

    It 'returns nothing for an HTML page, such as Manning''s login page' {
        $path = New-TestFile 'login.pdf' '<!DOCTYPE html><html><head><title>Log in</title></head><body></body></html>'
        Get-BookFileType -Path $path | Should -BeNullOrEmpty
    }

    It 'returns nothing for an empty file' {
        Get-BookFileType -Path (New-TestFile 'empty.pdf' '') | Should -BeNullOrEmpty
    }
}

Describe 'Test-DownloadedFile' {
    It 'accepts a file that is complete and of the format asked for' {
        $pdf = New-TestFile 'a.pdf' "%PDF-1.7`n%%EOF`n"
        $zip = New-TestZip 'c.zip' @(@{ Name = 'x.py'; Text = 'x' })
        Test-DownloadedFile -Path $pdf -Format pdf | Should -BeTrue
        Test-DownloadedFile -Path $zip -Format supplement | Should -BeTrue
        Test-DownloadedFile -Path (New-TestGzip 'c.tgz') -Format supplement | Should -BeTrue
        Test-DownloadedFile -Path (New-TestMobi 'k.mobi') -Format kindle | Should -BeTrue
    }

    It 'rejects a complete file of another format than asked for' {
        $pdf = New-TestFile 'b.pdf' "%PDF-1.7`n%%EOF`n"
        Test-DownloadedFile -Path $pdf -Format epub | Should -BeFalse
    }

    It 'rejects a cut-off or HTML file' {
        Test-DownloadedFile -Path (New-TestFile 'c.pdf' '%PDF-1.7 no end') -Format pdf | Should -BeFalse
        Test-DownloadedFile -Path (New-TestFile 'd.pdf' '<html></html>') -Format pdf | Should -BeFalse
    }
}
