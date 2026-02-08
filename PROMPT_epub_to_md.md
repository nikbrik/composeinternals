# Промпт: извлечение книги из EPUB в Markdown

Нужно извлечь книгу из EPUB в Markdown для последующего перевода. Файл книги: **composeinternals.en.epub** (лежит в текущем каталоге проекта).

Сделай по шагам:

1. **Установи Pandoc**, если его нет (например: `winget install pandoc`).

2. **Распакуй EPUB как ZIP** (epub — это zip): скопируй `.epub` в `.zip` и распакуй в папку `epub_extracted`. Контент книги будет в `epub_extracted/OEBPS/` (главные файлы — `.xhtml`, картинки — в `OEBPS/resources/`).

3. **Узнай порядок глав** из `epub_extracted/OEBPS/package.opf` (раздел `<spine>`): там перечислены `itemref` в порядке чтения (titlepage, versopage, dedication, toc, chapter00…chapter09).

4. **Конвертируй каждый xhtml в отдельный .md** в корне проекта:
   - скопируй `OEBPS/resources/` в папку `resources/` в корне проекта;
   - для каждого файла из spine (`title_page.xhtml`, `verso_page.xhtml`, `dedication.xhtml`, `toc.xhtml`, `chap00.xhtml` … `chap09.xhtml`) выполни:
     ```bash
     pandoc -f html -t gfm --wrap=none путь/к/файлу.xhtml -o имя_без_расширения.md
     ```
   Результат: `title_page.md`, `verso_page.md`, `dedication.md`, `toc.md`, `chap00.md` … `chap09.md` в текущем каталоге.

5. **Постобработка .md** (Pandoc оставляет сырой HTML — его нужно убрать):
   - заменить блоки `<pre><code>...</code></pre>` на ` ```kotlin ` и ` ``` ` с переносами строк;
   - заменить `<figcaption>текст</figcaption>` на *текст*;
   - заменить теги `<img src="..." alt="...">` на Markdown-картинки `![alt](url)`; если alt нет — `![](url)`;
   - удалить строки, которые целиком состоят только из тегов: `<div>`, `</div>`, `<div class="...">`, `<figure...>`, `</figure>`, `<section...>`, `</section>`;
   - в ссылках заменить `.xhtml` на `.md` (для оглавления и внутренних ссылок);
   - при необходимости заменить оставшиеся `<a href="...">текст</a>` на `[текст](url)`.

**Итог:** в каталоге должны быть только чистые .md без HTML-обёрток, плюс папка `resources/` с изображениями. Файлы должны точно соответствовать содержанию книги (те же главы, заголовки, параграфы, код и картинки).
