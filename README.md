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
| 2. Backend | не начат |
| 3. Media-server | не начат |
| 4. DVR | не начат |
| 5. Android | не начат |
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
```

После изменения схем в `contracts/` — `make codegen`, после изменения строк в `apps/shared/lib/l10n/*.arb` — `make l10n`. `make check-generated` проверяет, что сгенерированные файлы совпадают с закоммиченными (то же проверяет CI).

## Структура

```
contracts/        JSON Schema сообщений и REST-моделей, примеры, генерация кода
backend/          FastAPI: лицензии, привязка, токены, админка (этап 2)
media-server/     mediasoup, control-канал, DVR (этапы 3–4)
apps/shared/      Flutter-пакет: контракты, локализация, тема бренда
apps/camera_android/   приложение камеры (этап 5)
apps/viewer_windows/   Windows-клиент (этапы 6–7)
branding/         бренды: brand.json, логотип, иконка
docs/             SPEC, CHANGELOG, AUDIT
```
