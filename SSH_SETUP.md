# Настройка SSH для GitHub

## Ваш публичный ключ (скопируйте целиком)

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFWE2M5dFBxKDjUIpmRMc0hmktOfyZpTAvx2a6kh7Sxh 
```

## Что сделать

1. Откройте: **https://github.com/settings/ssh/new**
2. **Title** — любое (например: `Cursor` или `PC`).
3. **Key** — вставьте строку выше (начиная с `ssh-ed25519`).
4. Нажмите **Add SSH key**.

## (По желанию) Включить ssh-agent в Windows

Чтобы ключ подхватывался автоматически: **Параметры** → **Приложения** → **Дополнительные компоненты** → **Служба агента OpenSSH** → Управление → **Запустить** (или включите тип запуска «Вручную»/«Автоматически»). Либо откройте PowerShell **от имени администратора** и выполните:

```powershell
Set-Service ssh-agent -StartupType Manual
Start-Service ssh-agent
ssh-add $env:USERPROFILE\.ssh\id_ed25519
```

Без агента SSH тоже может работать: Git при подключении к GitHub использует ключ из `~/.ssh/` сам.

**Рекомендация:** при генерации нового ключа указывайте комментарий: `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "nikbrik@github"` — так ключ проще опознать, и в нашем случае с GitHub сработал именно ключ с комментарием.

## Проверка

В терминале выполните:

```powershell
ssh -T git@github.com
```

Должно появиться: `Hi nikbrik! You've successfully authenticated...`

## Переключить репозиторий на SSH (по желанию)

После успешной проверки можно использовать SSH вместо HTTPS:

```powershell
cd e:\composeinternals
git remote set-url origin git@github.com:nikbrik/composeinternals.git
```

Дальше `git push` и `git pull` будут идти по SSH.
