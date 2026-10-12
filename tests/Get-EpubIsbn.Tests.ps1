BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\ManningLibrary.psm1') -Force
    Add-Type -AssemblyName System.IO.Compression

    # An EPUB whose package file (named in container.xml, as in a real EPUB) has the given identifiers.
    function New-TestEpub([string]$Name, [string[]]$Identifiers, [string]$OpfPath = 'OEBPS/content.opf') {
        $path = Join-Path $TestDrive $Name
        $zip = [IO.Compression.ZipFile]::Open($path, 'Create')
        $ids = ($Identifiers | ForEach-Object { "<dc:identifier opf:scheme=`"ISBN`">$_</dc:identifier>" }) -join "`n"
        $entries = [ordered]@{
            'mimetype'               = 'application/epub+zip'
            'META-INF/container.xml' = "<container><rootfiles><rootfile full-path=`"$OpfPath`" media-type=`"application/oebps-package+xml`"/></rootfiles></container>"
            $OpfPath                 = "<package><metadata xmlns:dc=`"http://purl.org/dc/elements/1.1/`">$ids</metadata></package>"
        }
        foreach ($e in $entries.GetEnumerator()) {
            $w = New-Object IO.StreamWriter($zip.CreateEntry($e.Key).Open())
            $w.Write($e.Value); $w.Dispose()
        }
        $zip.Dispose()
        $path
    }
}

Describe 'Get-EpubIsbn' {
    It 'reads the ISBNs in the package file that container.xml names, with or without hyphens and prefixes' {
        $path = New-TestEpub 'book.epub' @('urn:isbn:978-1-78216-080-9', '9781789951134', 'URN:9781118064146') -OpfPath 'content/package.opf'
        Get-EpubIsbn -Path $path | Should -Be @('9781782160809', '9781789951134', '9781118064146')
    }

    It 'gives an ISBN-10 as its ISBN-13, so both forms of the same ISBN match' {
        $path = New-TestEpub 'old.epub' @('ISBN 1-59327-144-1')
        Get-EpubIsbn -Path $path | Should -Be @('9781593271442')
    }

    It 'ignores identifiers that are not ISBNs, and ISBNs with a wrong check digit' {
        $path = New-TestEpub 'other.epub' @('urn:uuid:5b2e7c1a-0f3d-4e8b-9a6c-1d2e3f4a5b6c', '9781782160800', '1234567890123')
        Get-EpubIsbn -Path $path | Should -BeNullOrEmpty
    }

    It 'returns nothing for a file that is not an EPUB' {
        $path = Join-Path $TestDrive 'not.epub'
        [IO.File]::WriteAllText($path, 'not a zip')
        Get-EpubIsbn -Path $path | Should -BeNullOrEmpty
    }
}
