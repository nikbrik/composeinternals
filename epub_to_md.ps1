# Конвертация EPUB в Markdown с помощью Pandoc
# Требуется: Pandoc (https://pandoc.org/ | winget install pandoc)

$ErrorActionPreference = 'Stop'
$epub = "composeinternals.en.epub"
$OEBPS = "epub_extracted\OEBPS"
$ResourcesDst = "resources"

# Порядок глав из package.opf (spine)
$spine = @(
    "title_page", "verso_page", "dedication", "toc",
    "chap00", "chap01", "chap02", "chap03", "chap04",
    "chap05", "chap06", "chap07", "chap08", "chap09"
)

# Проверка наличия Pandoc
if (-not (Get-Command pandoc -ErrorAction SilentlyContinue)) {
    Write-Host "Pandoc not found. Install: winget install pandoc" -ForegroundColor Red
    Write-Host "Or download from https://pandoc.org/installing.html" -ForegroundColor Yellow
    exit 1
}

# Распаковка EPUB (если ещё не распакован)
if (-not (Test-Path $OEBPS)) {
    Write-Host "Extracting EPUB..."
    Copy-Item $epub "composeinternals.zip"
    Expand-Archive -Path "composeinternals.zip" -DestinationPath "epub_extracted" -Force
    Remove-Item "composeinternals.zip"
}

# Копирование изображений
if (Test-Path "$OEBPS\resources") {
    if (-not (Test-Path $ResourcesDst)) { New-Item -ItemType Directory -Path $ResourcesDst -Force | Out-Null }
    Copy-Item -Path "$OEBPS\resources\*" -Destination $ResourcesDst -Recurse -Force
    Write-Host "Copied images to $ResourcesDst"
}

# Конвертация каждой главы в отдельный .md
foreach ($base in $spine) {
    $xhtml = "$OEBPS\$base.xhtml"
    if (-not (Test-Path $xhtml)) { Write-Warning "Skip (not found): $xhtml"; continue }
    $outMd = "$base.md"
    pandoc -f html -t gfm --wrap=none "$xhtml" -o $outMd
    if ($LASTEXITCODE -eq 0) { Write-Host "OK: $outMd" } else { Write-Warning "Error: $outMd" }
}

Write-Host "`nDone. MD files and folder $ResourcesDst are in current directory."
