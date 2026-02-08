# Подключение проекта к GitHub

Чтобы LLM (или вы) могли пушить изменения автоматически, выполните шаги ниже.

## 1. Установите Git (если ещё не установлен)

- Скачайте: https://git-scm.com/download/win  
- При установке можно оставить опцию **"Git from the command line and also from 3rd-party software"** — тогда `git` будет доступен в терминале и в Cursor.

## 2. Создайте репозиторий на GitHub

1. Зайдите на https://github.com и войдите в аккаунт.
2. Нажмите **New repository** (или **+** → New repository).
3. Укажите имя, например: `composeinternals` (или как вам удобно).
4. Репозиторий можно создать **пустым** (без README, без .gitignore) — мы всё добавим из локальной папки.
5. Не добавляйте лицензию и README, если хотите сразу связать с этой папкой.

## 3. Инициализация Git и привязка к GitHub

В терминале (в Cursor или PowerShell) выполните из папки проекта:

```powershell
cd e:\composeinternals

# Инициализация репозитория (если ещё не сделано)
git init

# Добавить удалённый репозиторий (подставьте ВАШ username и имя репозитория)
git remote add origin https://github.com/USERNAME/REPO_NAME.git

# Либо по SSH (если настроен ключ):
# git remote add origin git@github.com:USERNAME/REPO_NAME.git
```

Замените `USERNAME` на ваш логин GitHub, `REPO_NAME` — на имя репозитория.

## 4. Первый коммит и пуш

```powershell
git add .
git commit -m "Initial commit: Compose Internals book + Russian translation"
git branch -M main
git push -u origin main
```

При первом `git push` по HTTPS браузер или Git запросят авторизацию. Рекомендуется использовать **Personal Access Token** (GitHub больше не принимает пароль при push):

- GitHub → Settings → Developer settings → Personal access tokens → Generate new token.
- Выдайте права **repo**.
- При запросе пароля при `git push` введите этот токен вместо пароля.

## 5. Чтобы LLM могла пушить автоматически

- **Вариант A:** Настроить Git Credential Manager — один раз ввести токен, дальше push будет без запроса.
- **Вариант B:** Использовать SSH-ключ: сгенерировать ключ, добавить его в GitHub (Settings → SSH and GPG keys), в `remote` использовать `git@github.com:USERNAME/REPO_NAME.git` — тогда push не будет запрашивать пароль.

После этого в Cursor можно будет выполнять `git add`, `git commit`, `git push` из терминала или поручить это ассистенту.
