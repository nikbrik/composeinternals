# Remove raw HTML from Pandoc output so MD files are clean Markdown.
# Run from project root after epub_to_md.ps1

$ErrorActionPreference = 'Stop'
$files = Get-ChildItem -Path . -Filter "*.md" -File | Where-Object { $_.Name -notmatch "README|PROMPT_" }

$tagOnlyLines = @(
    '^\s*<div>\s*$',
    '^\s*</div>\s*$',
    '^\s*<div [^>]*>\s*$',   # <div id="..."> or <div class="...">
    '^\s*<div class="[^"]*">\s*$',
    '^\s*<figure[^>]*>\s*$',
    '^\s*</figure>\s*$',
    '^\s*<section[^>]*>\s*$',
    '^\s*</section>\s*$'
)

foreach ($f in $files) {
    $content = Get-Content -Path $f.FullName -Raw -Encoding UTF8
    if (-not $content) { continue }

    # 1. <pre><code>...</code></pre> -> ```kotlin ... ```
    $content = [regex]::Replace($content, '(?s)<pre><code>([\s\S]*?)</code></pre>', "``````kotlin`n`$1`n``````")

    # 2. <figcaption>text</figcaption> -> *text*
    $content = [regex]::Replace($content, '<figcaption>([^<]*)</figcaption>', '*$1*')

    # 3. <img src="path" ... /> or <img ... src="path" ... /> -> ![](path). Keep alt if present.
    $content = [regex]::Replace($content, '<img\s+[^>]*src="([^"]+)"[^>]*alt="([^"]*)"[^>]*/?\s*>', '![$2]($1)')
    $content = [regex]::Replace($content, '<img\s+[^>]*src="([^"]+)"[^>]*/?\s*>', '![]($1)')

    # 4. Remove lines that are only HTML wrapper tags
    $lines = $content -split "`r?`n"
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        $drop = $false
        foreach ($pat in $tagOnlyLines) {
            if ($trimmed -match $pat) { $drop = $true; break }
        }
        if (-not $drop) { $out.Add($line) }
    }
    $content = $out -join "`n"

    # 5. Internal links: .xhtml -> .md (for toc and cross-refs)
    $content = $content -replace '\.xhtml(\#[^\)"]*)?', '.md$1'
    # 5b. <a href="url">text</a> -> [text](url) where still present
    $content = [regex]::Replace($content, '<a\s+href="([^"]+)"[^>]*>([^<]*)</a>', '[$2]($1)')

    # 6. Collapse multiple consecutive blank lines to two max
    $content = [regex]::Replace($content, "(\r?\n){3,}", "`n`n")

    [System.IO.File]::WriteAllText($f.FullName, $content.Trim(), [System.Text.UTF8Encoding]::new($false))
    Write-Host "Cleaned: $($f.Name)"
}

Write-Host "Done."
