BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\ManningLibrary.psm1') -Force

    function New-Row([string]$File, [string]$Sha, [string]$Meap = '', [string]$Format = 'epub', [string]$Status = 'present') {
        [pscustomobject]@{ file = $File; title = $File; format = $Format; sha256 = $Sha; meap = $Meap; status = $Status }
    }
}

Describe 'Get-CalibrePlan' {
    It 'adds EPUBs not in Calibre, tagged Manning' {
        $plan = @(Get-CalibrePlan -Manifest @(New-Row 'a.epub' 'AAA'))

        $plan.Action | Should -Be 'add'
        $plan[0].Tags | Should -Be @('Manning')
    }

    It 'tags a MEAP, and a cancelled MEAP' {
        $plan = @(Get-CalibrePlan -Manifest @((New-Row 'a.epub' 'AAA' 'meap'), (New-Row 'b.epub' 'BBB' 'cancelled')))

        $plan[0].Tags | Should -Be @('Manning', 'MEAP')
        $plan[1].Tags | Should -Be @('Manning', 'MEAP', 'MEAP cancelled')
    }

    It 'leaves out PDFs (the free samplers among them), code and files that are not present' {
        $manifest = @(
            New-Row 'a.pdf' 'AAA' -Format 'pdf'
            New-Row 'a - code.zip' 'BBB' -Format 'supplement'
            New-Row 'gone.epub' 'CCC' -Status 'failed')

        @(Get-CalibrePlan -Manifest $manifest).Count | Should -Be 0
    }

    It 'skips a book already in Calibre with its tags, matched by SHA-256 in any case' {
        $in = @{ 'aaa' = @{ id = 7; tags = @('Manning', 'My own tag') } }

        $plan = Get-CalibrePlan -Manifest @(New-Row 'a.epub' 'AAA') -InCalibre $in

        $plan.Action | Should -Be 'skip'
        $plan.Id | Should -Be 7
    }

    It 'adds missing tags to a book already in Calibre, keeping its other tags' {
        $in = @{ 'aaa' = @{ id = 7; tags = @('My own tag') } }

        $plan = Get-CalibrePlan -Manifest @(New-Row 'a.epub' 'AAA' 'meap') -InCalibre $in

        $plan.Action | Should -Be 'tag'
        $plan.Tags | Should -Be @('My own tag', 'Manning', 'MEAP')
    }

    It 'tags a copy from another store with the same title instead of adding the book again' {
        $byTitle = @{ 'a.epub' = @(@{ id = 9; tags = @('Humble Bundle') }) }

        $plan = Get-CalibrePlan -Manifest @(New-Row 'a.epub' 'AAA') -ByTitle $byTitle

        $plan.Action | Should -Be 'tag'
        $plan.Match | Should -Be 'title'
        $plan.Id | Should -Be 9
        $plan.Tags | Should -Be @('Humble Bundle', 'Manning')
    }

    It 'prefers the same file to the same title' {
        $in = @{ 'aaa' = @{ id = 7; tags = @('Manning') } }
        $byTitle = @{ 'a.epub' = @(@{ id = 9; tags = @() }) }

        $plan = Get-CalibrePlan -Manifest @(New-Row 'a.epub' 'AAA') -InCalibre $in -ByTitle $byTitle

        $plan.Action | Should -Be 'skip'
        $plan.Id | Should -Be 7
    }

    It 'leaves a title that matches several books in Calibre to be checked by hand' {
        $byTitle = @{ 'a.epub' = @(@{ id = 9; tags = @() }, @{ id = 10; tags = @() }) }

        (Get-CalibrePlan -Manifest @(New-Row 'a.epub' 'AAA') -ByTitle $byTitle).Action | Should -Be 'check'
    }
}

Describe 'Get-CalibreTitleKey' {
    It 'gives a title, and the title without its subtitle, in lower case' {
        Get-CalibreTitleKey 'AI as a Service: Serverless machine learning with AWS' | Should -Be @('ai as a service: serverless machine learning with aws', 'ai as a service')
        Get-CalibreTitleKey 'Machine Learning in Action - Advertorial' | Should -Be @('machine learning in action - advertorial', 'machine learning in action')
        Get-CalibreTitleKey 'Practical Recommender Systems' | Should -Be @('practical recommender systems')
    }
}
