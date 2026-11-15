BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\ManningLibrary.psm1') -Force
    Add-Type -AssemblyName System.IO.Compression
    $helloSha = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'  # SHA-256 of the 5 bytes "hello"

    # An EPUB with the given ISBNs in its package file. $Text makes copies of the same book differ in content.
    function New-TestEpub([string]$Path, [string[]]$Isbn, [string]$Text = '') {
        $zip = [IO.Compression.ZipFile]::Open($Path, 'Create')
        $ids = ($Isbn | ForEach-Object { "<dc:identifier>urn:isbn:$_</dc:identifier>" }) -join ''
        $entries = [ordered]@{
            'mimetype'               = 'application/epub+zip'
            'META-INF/container.xml' = '<container><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>'
            'content.opf'            = "<package><metadata>$ids</metadata></package>"
            'text.html'              = $Text
        }
        foreach ($e in $entries.GetEnumerator()) {
            $w = New-Object IO.StreamWriter($zip.CreateEntry($e.Key).Open())
            $w.Write($e.Value); $w.Dispose()
        }
        $zip.Dispose()
    }
    function New-Row([string]$File, [string]$Title, [string]$Id = '1', [string]$Isbn = '', [string]$Sha = ('a' * 64)) {
        [pscustomobject]@{ id = $Id; isbn = $Isbn; title = $Title; file = $File; sha256 = $Sha; status = 'present'
            format = [IO.Path]::GetExtension($File).TrimStart('.') }
    }
}

Describe 'Compare-Library' {
    BeforeEach {
        # TestDrive is shared by the tests in a Describe
        $ours = Join-Path $TestDrive ([guid]::NewGuid())
        $other = Join-Path $TestDrive ([guid]::NewGuid())
        $null = New-Item -ItemType Directory -Path $ours, $other
    }

    It 'reports a file in the other folder with the same content as identical, whatever its name' {
        $null = New-Item -ItemType Directory -Path (Join-Path $other 'old')
        [IO.File]::WriteAllText((Join-Path $other 'old\copy.pdf'), 'hello')
        $manifest = @(New-Row 'Book.pdf' 'Book' -Sha $helloSha)

        $result = @(Compare-Library -Manifest $manifest -Library $ours -Folder $other)

        $result.Other | Should -Be @('old\copy.pdf')
        $result.Status | Should -Be @('identical')
        $result.Ours | Should -Be @('Book.pdf')
    }

    It 'reports a file that matches nothing here as only there' {
        [IO.File]::WriteAllText((Join-Path $other 'unique.pdf'), 'something else')
        $result = @(Compare-Library -Manifest @(New-Row 'Book.pdf' 'Book') -Library $ours -Folder $other)

        $result.Status | Should -Be @('only-there')
        $result.Ours | Should -Be @($null)
    }

    It 'matches by the ISBN in our manifest (from Manning''s catalog), even for a PDF-only book' {
        New-TestEpub (Join-Path $other 'Some Bundle Copy.epub') '9781617293153'
        $manifest = @(New-Row 'Old Calculator Handbook.pdf' 'Old Calculator Handbook' -Isbn '9781617293153')

        $result = @(Compare-Library -Manifest $manifest -Library $ours -Folder $other)

        $result.Status | Should -Be @('same-isbn')
        $result.Ours | Should -Be @('Old Calculator Handbook.pdf')
    }

    It 'matches by an ISBN inside our EPUB, and prefers our copy in the same format' {
        New-TestEpub (Join-Path $ours 'Book.epub') '9781593271442', '9781593271459'
        [IO.File]::WriteAllText((Join-Path $other '9781593271459.pdf'), 'named by isbn')
        $manifest = @((New-Row 'Book.epub' 'Book' -Id '7'), (New-Row 'Book.pdf' 'Book' -Id '7'))

        $result = @(Compare-Library -Manifest $manifest -Library $ours -Folder $other)

        $result.Status | Should -Be @('same-isbn')
        $result.Ours | Should -Be @('Book.pdf')
    }

    It 'takes ISBNs and titles from the other folder''s own manifest (the PacktPub library), and ignores its data files' {
        [IO.File]::WriteAllText((Join-Path $other '9781789951134.pdf'), 'packt pdf')
        [IO.File]::WriteAllText((Join-Path $other 'packt-library.json'), '{}')
        @([pscustomobject]@{ isbn = '9781789951134'; format = 'pdf'; file = '9781789951134.pdf'; title = 'Linux Security' }) |
            Export-Csv -LiteralPath (Join-Path $other 'manifest.csv') -NoTypeInformation
        $manifest = @(New-Row 'Linux Security.pdf' 'Linux Security' -Isbn '9781789951134')

        $result = @(Compare-Library -Manifest $manifest -Library $ours -Folder $other)

        $result.Other | Should -Be @('9781789951134.pdf')
        $result.Status | Should -Be @('same-isbn')
    }

    It 'reports a different file whose name is exactly one of our titles as the same title, to check by hand' {
        [IO.File]::WriteAllText((Join-Path $other 'the_java_module_system.pdf'), 'another copy')
        $manifest = @(New-Row 'The Java Module System.pdf' 'The Java Module System')

        $result = @(Compare-Library -Manifest $manifest -Library $ours -Folder $other)

        $result.Status | Should -Be @('same-title')
        $result.Ours | Should -Be @('The Java Module System.pdf')
    }

    It 'does not match a short title that is only part of a longer one' {
        [IO.File]::WriteAllText((Join-Path $other 'Learning Penetration Testing with Python.pdf'), 'packt')
        $manifest = @(New-Row 'Penetration Testing.pdf' 'Penetration Testing')

        (Compare-Library -Manifest $manifest -Library $ours -Folder $other).Status | Should -Be 'only-there'
    }
}
