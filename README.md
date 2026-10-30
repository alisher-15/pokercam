# PokerCam

Система видеонаблюдения за раздачей карт на покерных столах: Android-телефон над столом → медиа-сервер (mediasoup) → до 5 Windows-клиентов на стол, перемотка на 10 минут, удалённое управление камерой и ежемесячная лицензия.

- Требования: [docs/SPEC.md](docs/SPEC.md)
- Правила работы для Claude Code: [CLAUDE.md](CLAUDE.md)
- История изменений: [docs/CHANGELOG.md](docs/CHANGELOG.md)
- Протокол: [contracts/README.md](contracts/README.md)

## Статус

Цель первой версии — пилот: все функции MVP на 1 стол × 1 телефон-камера × 1 ПК (SPEC 2 и 14).

| Этап | Состояние |
| --- | --- |
| 0. Фундамент | готов, ждёт приёмки |
| 1. Спайк Camera2 | на эмуляторе работает, ждёт проверки на телефоне (ветка `stage-1/camera2-spike`) |
| 2. Backend | готов, ждёт приёмки (ветка `stage-2/backend`) |
| 3. Media-server | готов, ждёт приёмки (ветка `stage-3/media-server`) |
| 4. DVR | готов, ждёт приёмки (ветка `stage-4/dvr`); 12-часовой прогон пилота — на сервере |
| 5. Android | готов на эмуляторе (ветка `stage-5/android`): сквозной прогон в CI зелёный; ждёт проверки на устройстве — привязка по QR, 1080p30 4 часа, реальные параметры Camera2 |
| 6. Windows: live | не начат |
| 7. Windows: DVR | не начат |
| 8. White-label | не начат |
| 9. Приёмка | не начат |

## Запуск для разработки

Нужны Docker с compose, Python 3.12, Node 24 и Flutter 3.47.

```bash
cp .env.example .env
make setup     # зависимости всех компонентов
make dev       # postgres + backend (:8000) + media-server (:3000) в docker compose
make test      # все тесты (поднимает postgres из compose)
make lint      # ruff, eslint + tsc, dart format + analyze
make seed      # демо-клиент с оплаченным месяцем и 1 столом, админ из .env; печатает ключ клуба
make acceptance  # после make dev: фейковая камера + MAX_VIEWERS_PER_TABLE ботов-зрителей (этап 3)
make acceptance-dvr  # после make dev: DVR 11 минут, kill FFmpeg, доступ, лицензия (этап 4)
make load-test LOAD_MINUTES=60  # после make dev: нагрузка, память и CPU media-server
```

Установка на сервер (VPS или мини-ПК с Ubuntu): [deploy/README.md](deploy/README.md).

Админка: http://localhost:8000/admin (вход — `ADMIN_EMAIL` / `ADMIN_PASSWORD` из `.env`), API: http://localhost:8000/docs. Для production: `make keys >> .env` и `ENVIRONMENT=production`.

Без телефона и Windows-клиента поток проверяется ботами из `tools/` (headless Chromium с тестовой камерой 1080p30 и mediasoup-client): `make acceptance` создаёт клиента, привязывает фейковую камеру к его столу и подключает зрителей; один сверх лимита должен получить `room_full`. Вручную: `cd tools && node fake_camera/index.ts --key <ключ клуба>` и `node fake_viewer/index.ts --key <ключ клуба> --count 5`. Ботам нужен Chromium Playwright: `cd tools && npx playwright install chromium`. Фейковая камера перепривязывает стол, поэтому запускайте её на тестовом клиенте.

DVR (перемотка на 10 минут) пишет media-server: FFmpeg складывает сегменты в tmpfs `/dvr` контейнера (`DVR_TMPFS_SIZE`, ≈300 МБ на стол), плейлист отдаётся по `GET /dvr/{table_id}/index.m3u8` на порту media-server с заголовком `Authorization: Bearer <токен зрителя этого стола>`. Нагрузочный тест: `make load-test LOAD_TABLES=1 LOAD_VIEWERS=1 LOAD_MINUTES=720` — пилотный 12-часовой прогон (SPEC 7.4); результаты (CSV, график памяти и CPU, итог) — в `tools/load_test/results/`.

После изменения схем в `contracts/` — `make codegen`, после изменения строк в `apps/shared/lib/l10n/*.arb` — `make l10n`. `make check-generated` проверяет, что сгенерированные файлы совпадают с закоммиченными (то же проверяет CI).

## Структура

```
contracts/        JSON Schema сообщений и REST-моделей, примеры, генерация кода
backend/          FastAPI: лицензии, привязка, токены, админка (этап 2)
media-server/     mediasoup: комнаты, сигналинг, control-канал, лицензия (этап 3), DVR (этап 4)
apps/shared/      Flutter-пакет: контракты, локализация, тема бренда
apps/camera_android/   приложение камеры (этап 5)
apps/viewer_windows/   Windows-клиент (этапы 6–7)
branding/         бренды: brand.json, логотип, иконка
tools/            боты: фейковая камера и зрители, приёмка этапов, нагрузочный тест
docs/             SPEC, CHANGELOG, AUDIT
```
