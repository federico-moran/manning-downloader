BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\ManningLibrary.psm1') -Force
    $helloSha = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'  # SHA-256 of the 5 bytes "hello"
}

Describe 'Test-Library' {
    It 'reports each manifest file as ok, changed or missing, and lists unfinished .part files' {
        $folder = Join-Path $TestDrive 'library'
        $null = New-Item -ItemType Directory -Path $folder
        [IO.File]::WriteAllText((Join-Path $folder 'good.pdf'), 'hello')
        [IO.File]::WriteAllText((Join-Path $folder 'damaged.pdf'), 'hellp')   # same size, different content
        [IO.File]::WriteAllText((Join-Path $folder 'next.epub.part'), 'hel')
        $manifest = @(
            [pscustomobject]@{ file = 'good.pdf'; sha256 = $helloSha; bytes = '5'; status = 'present' }
            [pscustomobject]@{ file = 'damaged.pdf'; sha256 = $helloSha; bytes = '5'; status = 'present' }
            [pscustomobject]@{ file = 'lost.pdf'; sha256 = $helloSha; bytes = '5'; status = 'present' })

        $result = @(Test-Library -Folder $folder -Manifest $manifest)

        ($result | Where-Object File -eq 'good.pdf').Status | Should -Be 'ok'
        ($result | Where-Object File -eq 'damaged.pdf').Status | Should -Be 'changed'
        ($result | Where-Object File -eq 'lost.pdf').Status | Should -Be 'missing'
        ($result | Where-Object File -eq 'next.epub.part').Status | Should -Be 'unfinished'
        $result.Count | Should -Be 4
    }

    It 'ignores rows that are not files: links, and failed downloads' {
        $folder = Join-Path $TestDrive 'links'
        $null = New-Item -ItemType Directory -Path $folder
        $manifest = @(
            [pscustomobject]@{ file = ''; sha256 = ''; bytes = ''; status = 'link' }
            [pscustomobject]@{ file = 'x.pdf'; sha256 = ''; bytes = ''; status = 'failed' })

        @(Test-Library -Folder $folder -Manifest $manifest).Count | Should -Be 0
    }
}
