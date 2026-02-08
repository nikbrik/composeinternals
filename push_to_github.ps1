# Скрипт: создание репозитория на GitHub и первый push.
# Один раз выполните: gh auth login (войдите в браузер), затем запустите этот скрипт.

$ErrorActionPreference = "Stop"
$repoName = "composeinternals"
$projectRoot = "e:\composeinternals"

# Добавить Git и gh в PATH
$env:Path = "C:\Program Files\Git\cmd;C:\Program Files\GitHub CLI;" + $env:Path

# Проверка авторизации
$auth = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Сначала войдите в GitHub: выполните в терминале:" -ForegroundColor Yellow
    Write-Host "  gh auth login --web --hostname github.com" -ForegroundColor Cyan
    Write-Host "Скопируйте код из вывода, откройте ссылку в браузере и введите код. Затем снова запустите этот скрипт." -ForegroundColor Yellow
    exit 1
}

Set-Location $projectRoot

# Имя репозитория: можно передать аргументом, иначе composeinternals
if ($args.Count -ge 1) { $repoName = $args[0] }

# Ветка main для GitHub
git branch -M main 2>$null

# Создать репозиторий на GitHub (public) и привязать
Write-Host "Создаю репозиторий на GitHub: $repoName ..." -ForegroundColor Green
gh repo create $repoName --public --source=. --remote=origin --push --description "Compose Internals book + Russian translation"

if ($LASTEXITCODE -eq 0) {
    Write-Host "Готово. Репозиторий: https://github.com/$(gh api user -q .login)/$repoName" -ForegroundColor Green
} else {
    # Возможно репозиторий уже существует — просто добавить remote и push
    $login = gh api user -q .login
    $remoteUrl = "https://github.com/$login/$repoName.git"
    if (-not (git remote get-url origin 2>$null)) {
        git remote add origin $remoteUrl
    }
    git branch -M main 2>$null
    git push -u origin main
    Write-Host "Push выполнен. Репозиторий: https://github.com/$login/$repoName" -ForegroundColor Green
}
