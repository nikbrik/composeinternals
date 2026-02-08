# Сборка русской книги: EPUB + PDF (ландшафт)
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

$pandocExe = (Get-Command pandoc -ErrorAction SilentlyContinue).Path
if (-not $pandocExe) {
    $alt = Join-Path $env:LOCALAPPDATA "Pandoc\pandoc.exe"
    if (Test-Path $alt) { $pandocExe = $alt } else { Write-Host "Pandoc ne naiden"; exit 1 }
}

$chaps = "chap00_ru.md","chap01_ru.md","chap02_ru.md","chap03_ru.md","chap04_ru.md","chap05_ru.md","chap06_ru.md","chap07_ru.md"

Write-Host "Sborka EPUB..."
& $pandocExe -s $chaps -o composeinternals.ru.epub --resource-path=. --css=epub_styles_ru.css --metadata title="Jetpack Compose Internals" --metadata lang=ru --toc --toc-depth=2 --syntax-highlighting=tango
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "EPUB gotov."

$xl = Get-Command xelatex -ErrorAction SilentlyContinue
if (-not $xl) {
    Write-Host "XeLaTeX ne naiden. Ustanavlivaju MiKTeX (winget install MiKTeX.MiKTeX)..."
    winget install -e --id MiKTeX.MiKTeX --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { Write-Host "Oshibka ustanovki. Ustanovite vruchnuju: winget install MiKTeX.MiKTeX"; exit 1 }
    Write-Host "MiKTeX ustanovlen. Zakrojte terminal, otkrojte snova i zapustite skript povtorno."
    exit 0
}
Write-Host "Sborka PDF..."
& $pandocExe -s $chaps -o composeinternals.ru.pdf --resource-path=. --pdf-engine=xelatex -H pdf_code_break.tex -V geometry=landscape,paperwidth=177mm,paperheight=125mm,margin=4mm -V lang=russian -V mainfont="Times New Roman" -V monofont="Consolas" -V fontsize=9pt --syntax-highlighting=tango
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "PDF gotov. Gotovo."
