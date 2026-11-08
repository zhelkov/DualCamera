# DualCamera — порядок сборки и выкладки (для ИИ-помощника)

## Среда

- Пользователь работает на **Windows** (у него нет Mac и Xcode).
- Сборка выполняется **в облаке**: GitHub Actions на macOS-раннере (настроен в `.github/workflows/build.yml`).
- Установлен и авторизован GitHub CLI (`gh`). Полный путь в Git Bash: `"/c/Program Files/GitHub CLI/gh.exe"`.
- Репозиторий публичный → сборки бесплатны, лимита минут нет.

## Полный цикл «правка → ссылка пользователю»

1. Внести правки в файлы проекта.

2. Закоммитить и запушить (push в `main` автоматически запускает сборку):

   ```bash
   cd "d:/DualCamera"
   git add <файлы>
   git commit -m "описание"
   git push
   ```

3. Узнать id последней сборки и дождаться её завершения (повторять, пока `status` не `completed`):

   ```bash
   "/c/Program Files/GitHub CLI/gh.exe" run list --repo zhelkov/DualCamera --limit 1 --json databaseId,status,conclusion
   ```

4. Если сборка упала — посмотреть ошибки:

   ```bash
   "/c/Program Files/GitHub CLI/gh.exe" run view <RUN_ID> --repo zhelkov/DualCamera --log-failed
   # ошибки компиляции:
   # ... | grep -aiE "error:"
   ```

5. Скачать готовый IPA (артефакт):

   ```bash
   "/c/Program Files/GitHub CLI/gh.exe" run download <RUN_ID> --repo zhelkov/DualCamera --name DualCamera-ipa --dir ./ipa_xxx
   ```

   После этого в `ipa_xxx/` лежит файл `DualCamera.ipa`.

6. Создать GitHub Release с прямым IPA:

   ```bash
   "/c/Program Files/GitHub CLI/gh.exe" release create v<ВЕРСИЯ> ipa_xxx/DualCamera.ipa \
     --repo zhelkov/DualCamera \
     --title "DualCamera <ВЕРСИЯ>" \
     --notes "описание изменений"
   ```

7. Дать пользователю **прямую ссылку** на IPA:

   ```
   https://github.com/zhelkov/DualCamera/releases/download/v<ВЕРСИЯ>/DualCamera.ipa
   ```

## Важные примечания по выкладке

- Артефакт GitHub Actions — это **zip**, внутри него `DualCamera.ipa`. Пользователю давать ссылку на **release** (чистый `.ipa`), а НЕ на артефакт сборки.
- Имя артефакта в workflow: `DualCamera-ipa`.
- Папки с локальными IPA (`ipa_*`) не коммитить — они в `.gitignore`.

## Как пользователь устанавливает (Windows + AltStore)

1. Пользователь открывает прямую ссылку на `.ipa` в **Safari на iPhone** — файл скачивается.
2. На iPhone: приложение **«Файлы»** → нажать на `DualCamera.ipa`.
3. Нажать **«Поделиться»** (квадрат со стрелкой) → выбрать **AltStore**.
4. AltStore подписывает и устанавливает (бесплатный Apple ID, подпись действует 7 дней, затем продлевать).

Если AltStore пишет «AltServer could not be found»: на компьютере должен быть запущен **AltServer** (трей Windows), iPhone и ПК в одной Wi-Fi сети или по USB, установлен iTunes. Подпись идёт по Wi-Fi, не по кабелю.

## Стиль общения с пользователем

- Пользователь — **владелец продукта, не программист**.
- Сначала вывод, потом подробности. Одна мысль — одно предложение.
- Имена файлов/функций указывать в скобках.
- Давать конкретные шаги и прямые ссылки, без «вопросов-загадок».
- Язык — русский.
