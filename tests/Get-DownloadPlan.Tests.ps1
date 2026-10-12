BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\ManningLibrary.psm1') -Force

    function New-Book([int]$Id, [string]$Title, [string[]]$Formats = @('PDF', 'EPUB'), [string]$CodeUrl, [switch]$Meap, [switch]$Cancelled) {
        [pscustomobject]@{
            Kind = 'book'; Id = $Id; Title = $Title; Authors = 'A. Writer'; Slug = 'slug'; Link = $null
            IsMeap = [bool]$Meap; MeapVersion = $(if ($Meap) { 3 }); MeapUpdated = $(if ($Meap) { '2026-01-02' }); Cancelled = [bool]$Cancelled
            Formats = $Formats; CodeUrl = $CodeUrl
            InCatalog = $true; Isbn = '9781633438071'; LastUpdated = '2024-04-22'
        }
    }
    function New-Row([int]$Id, [string]$Format, [string]$File, [string]$Status = 'present') {
        [pscustomobject]@{ id = "$Id"; format = $Format; file = $File; status = $Status }
    }
}

Describe 'Get-DownloadPlan' {
    It 'plans the PDF and EPUB of a book by default, from the dashboard''s download links' {
        $plan = @(Get-DownloadPlan -Items @(New-Book 7 'Grokking Things'))

        $plan.Format | Should -Be @('pdf', 'epub')
        $plan.Action | Should -Be @('download', 'download')
        $plan.File | Should -Be @('Grokking Things.pdf', 'Grokking Things.epub')
        $plan[0].Url | Should -Be 'https://www.manning.com/dashboard/download?productId=7&downloadFormat=PDF'
        $plan[1].SourceFormat | Should -Be 'EPUB'
    }

    It 'plans only the formats a book has (a PDF-only book gets no EPUB)' {
        $plan = @(Get-DownloadPlan -Items @(New-Book 7 'Old Book' -Formats 'PDF'))
        $plan.Format | Should -Be @('pdf')
    }

    It 'takes the EPUB3 instead of the EPUB when both are offered, unless -PlainEpub' {
        $book = New-Book 7 'Book' -Formats 'EPUB', 'EPUB3', 'PDF'
        (Get-DownloadPlan -Items @($book) -Format epub).SourceFormat | Should -Be 'EPUB3'
        (Get-DownloadPlan -Items @($book) -Format epub -PlainEpub).SourceFormat | Should -Be 'EPUB'
    }

    It 'plans the Kindle file only when asked for, as .mobi' {
        $book = New-Book 7 'Book' -Formats 'PDF', 'EPUB', 'KINDLE'
        @(Get-DownloadPlan -Items @($book)).Format | Should -Not -Contain 'kindle'
        $k = Get-DownloadPlan -Items @($book) -Format kindle
        $k.File | Should -Be 'Book.mobi'
        $k.SourceFormat | Should -Be 'KINDLE'
    }

    It 'plans a code zip as a supplement, downloaded from where the dashboard links' {
        $book = New-Book 7 'Book' -CodeUrl 'https://manning-content.s3.amazonaws.com/download/x/code.zip'
        $s = Get-DownloadPlan -Items @($book) -Format supplement
        $s.Action | Should -Be 'download'
        $s.File | Should -Be 'Book - code.zip'
        $s.Url | Should -Be 'https://manning-content.s3.amazonaws.com/download/x/code.zip'
    }

    It 'names code that is not a zip with its own extension (one book''s code is a .tgz)' {
        $book = New-Book 7 'AI as a Service' -CodeUrl 'https://manning-content.s3.amazonaws.com/download/1/e5d/ai-as-a-service.tgz'
        (Get-DownloadPlan -Items @($book) -Format supplement).File | Should -Be 'AI as a Service - code.tgz'
    }

    It 'records code on GitHub as a link, with nothing to download' {
        $s = Get-DownloadPlan -Items @(New-Book 7 'Book' -CodeUrl 'https://github.com/example/code') -Format supplement
        $s.Action | Should -Be 'link'
        $s.File | Should -BeNullOrEmpty
        $s.Url | Should -Be 'https://github.com/example/code'
    }

    It 'leaves out liveProjects and liveVideos' {
        $project = [pscustomobject]@{ Kind = 'project'; Id = $null; Title = 'P'; Formats = @(); CodeUrl = $null }
        $video = [pscustomobject]@{ Kind = 'video'; Id = $null; Title = 'V'; Formats = @(); CodeUrl = 'https://manning-content.s3.amazonaws.com/v.zip' }
        @(Get-DownloadPlan -Items @($project, $video)).Count | Should -Be 0
    }

    It 'skips a file already in the manifest, matched by ID and format, under its recorded name' {
        $manifest = @(New-Row 7 'pdf' 'Renamed by hand.pdf')
        $plan = @(Get-DownloadPlan -Items @(New-Book 7 'Book') -Manifest $manifest)

        $plan[0].Action | Should -Be 'skip'
        $plan[0].File | Should -Be 'Renamed by hand.pdf'
        $plan[1].Action | Should -Be 'download'
    }

    It 'skips a GitHub link already recorded' {
        $manifest = @(New-Row 7 'supplement' '' 'link')
        (Get-DownloadPlan -Items @(New-Book 7 'Book' -CodeUrl 'https://github.com/x/y') -Format supplement -Manifest $manifest).Action | Should -Be 'skip'
    }

    It 'downloads again a file whose last download failed or that has gone missing' {
        $manifest = @((New-Row 7 'pdf' 'Book.pdf' 'failed'), (New-Row 7 'epub' 'Book.epub' 'missing'))
        @(Get-DownloadPlan -Items @(New-Book 7 'Book') -Manifest $manifest).Action | Should -Be @('download', 'download')
    }

    It 'makes names safe for Windows' {
        $plan = Get-DownloadPlan -Items @(New-Book 7 'C#/.NET: "Why?" <and> how*|' -Formats 'PDF')
        $plan.File | Should -Be 'C#-.NET - ''Why'' and how.pdf'
    }

    It 'tells apart two books with the same title by their ID' {
        $plan = @(Get-DownloadPlan -Items @((New-Book 7 'Same' -Formats 'PDF'), (New-Book 8 'Same' -Formats 'PDF')))
        $plan.File | Should -Be @('Same.pdf', 'Same (8).pdf')
    }

    It 'does not give a new file a name already used in the manifest by another book' {
        $manifest = @(New-Row 9 'pdf' 'Same.pdf')
        (Get-DownloadPlan -Items @(New-Book 7 'Same' -Formats 'PDF') -Manifest $manifest).File | Should -Be 'Same (7).pdf'
    }

    It 'carries what the manifest records: ISBN, authors, version, MEAP state' {
        $meap = Get-DownloadPlan -Items @(New-Book 7 'Book' -Formats 'PDF' -Meap -Cancelled)
        $meap.Isbn | Should -Be '9781633438071'
        $meap.Authors | Should -Be 'A. Writer'
        $meap.Version | Should -Be 'MEAP v3 (2026-01-02)'
        $meap.Meap | Should -Be 'cancelled'

        $final = Get-DownloadPlan -Items @(New-Book 8 'Final' -Formats 'PDF')
        $final.Version | Should -Be '2024-04-22'
        $final.Meap | Should -BeNullOrEmpty
    }
}
