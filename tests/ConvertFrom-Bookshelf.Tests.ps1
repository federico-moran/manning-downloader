BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\ManningLibrary.psm1') -Force
    $html = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures\bookshelf.html')
    $catalog = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures\catalog.json') | ConvertFrom-Json -DateKind String
}

Describe 'ConvertFrom-Bookshelf' {
    BeforeAll { $items = @(ConvertFrom-Bookshelf -Html $html) }

    It 'reads one item per row, in the bookshelf''s order, with its kind' {
        $items.Count | Should -Be 6
        $items.Kind | Should -Be @('book', 'book', 'book', 'book', 'project', 'video')
    }

    It 'reads a book''s ID, title, authors, page and formats' {
        $b = $items[0]
        $b.Id | Should -Be 1001
        $b.Title | Should -Be 'Tidy Testing in Action, Second Edition'
        $b.Authors | Should -Be 'Ada Example, Bo Sample'
        $b.Slug | Should -Be 'tidy-testing-in-action-second-edition'
        $b.Formats | Should -Be @('EPUB', 'KINDLE', 'PDF')
        $b.IsMeap | Should -BeFalse
    }

    It 'decodes HTML in titles and authors, and leaves out the foreword line' {
        $items[1].Title | Should -Be 'Agents & Tools: A Field Guide'
        $items[1].Authors | Should -Be 'René Muster'
    }

    It 'reads a MEAP''s version and date' {
        $m = $items[1]
        $m.IsMeap | Should -BeTrue
        $m.MeapVersion | Should -Be 12
        $m.MeapUpdated | Should -Be '2026-07-14'
        $m.Cancelled | Should -BeFalse
    }

    It 'marks a cancelled MEAP' {
        $items[2].Cancelled | Should -BeTrue
        $items[2].Formats | Should -Be @('EPUB', 'PDF')
    }

    It 'reads the code link, wherever it is hosted' {
        $items[0].CodeUrl | Should -Be 'https://manning-content.s3.amazonaws.com/download/1/abc/tidy-testing-code.zip'
        $items[1].CodeUrl | Should -Be 'https://github.com/example/agents-code'
        $items[3].CodeUrl | Should -BeNullOrEmpty
    }

    It 'keeps liveProjects and liveVideos with their link, and no formats' {
        $items[4].Title | Should -Be 'Your First Service: Create It'
        $items[4].Link | Should -Be 'https://liveproject.manning.com/project/1468/1087'
        $items[4].Formats | Should -BeNullOrEmpty
        $items[5].Link | Should -Be 'https://livevideo.manning.com/course/20?fromDashboard=true'
    }

    It 'returns nothing for a page without rows (the login page, say)' {
        @(ConvertFrom-Bookshelf -Html '<html><body>Log in</body></html>').Count | Should -Be 0
    }
}

Describe 'Add-CatalogInfo' {
    BeforeAll { $items = @(Add-CatalogInfo -Items @(ConvertFrom-Bookshelf -Html $html) -Catalog $catalog) }

    It 'adds the ISBN, last update, subtitle and tags of a book in the catalogue, matched by ID' {
        $b = $items[0]
        $b.InCatalog | Should -BeTrue
        $b.Isbn | Should -Be '9781633438071'
        $b.LastUpdated | Should -Be '2024-04-22'
        $b.Subtitle | Should -Be 'With fewer mocks'
        $b.Tags | Should -Be @('Testing', 'Intermediate')
    }

    It 'names the newer edition, with its title and whether it is on the bookshelf' {
        $old = $items[3]
        $old.NextEdition | Should -Be 5005
        $old.NextEditionTitle | Should -Be 'Old Calculator Handbook, Second Edition'
        $old.NextEditionOwned | Should -BeFalse
    }

    It 'marks a book the catalogue no longer has (a withdrawn MEAP), without an ISBN' {
        $items[2].InCatalog | Should -BeFalse
        $items[2].Isbn | Should -BeNullOrEmpty
    }

    It 'keeps the items the catalogue has no entry for, unchanged' {
        $items.Count | Should -Be 6
        $items[4].Title | Should -Be 'Your First Service: Create It'
    }
}
