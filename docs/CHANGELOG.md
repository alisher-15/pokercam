# Changelog

## Решения по ТЗ — 28.10.2026

- Первая версия — пилот: все функции MVP на 1 стол × 1 телефон × 1 ПК; ограничения — настройками (`max_tables = 1`, `MAX_VIEWERS_PER_TABLE = 1`).
- Оплата наличными, доступ на месяц, продление кнопкой «+1 месяц», 3 дня отсрочки, затем блокировка.
- Access JWT — 12 ч (`ACCESS_TOKEN_TTL`); срок доступа задаёт лицензия.
- Записано в SPEC (разделы 2, 5.1, 5.2, 7.1, 9.1, критерии 7.4 и 8.6, новый раздел 14) и в `docs/AUDIT.md`.

## Этап 0 «Фундамент» — 28.10.2026

- Монорепозиторий по структуре SPEC 4: `backend/`, `media-server/`, `apps/{shared,camera_android,viewer_windows}`, `contracts/`, `branding/default/`.
- **contracts/**: JSON Schema всех сообщений control-канала (5.3), сигналинга mediasoup, REST-моделей (5.2), claims JWT и `brand.json`; по примеру на каждую схему. `make codegen` генерирует типы для TypeScript и Dart (quicktype) и Python (datamodel-codegen). Контрактные тесты на каждой стороне: Node (ajv), Python (jsonschema + pydantic), Dart (сгенерированные классы).
- **backend**: FastAPI с `GET /health` (503, если БД недоступна), настройки из `.env`, JSON-логи с полями `table_id`/`device_id`/`session_id`, SQLAlchemy 2 + Alembic без таблиц (модели — этап 2).
- **media-server**: Node 24 + TypeScript, `GET /health`, JSON-логи pino в той же форме, проверка WebSocket-сообщений по схемам (ajv). mediasoup подключается на этапе 3.
- **apps**: пакет `shared` (сгенерированные контракты, `decodeMessage`, кодирование без null, локализация ru/en, тема бренда) и пустые приложения камеры и Windows-клиента с заглушкой экрана.
- **branding/default**: `brand.json` и временные логотип и иконка.
- **Инфраструктура**: `docker-compose.yml` (postgres 16, backend, media-server; `restart: unless-stopped`, healthcheck у всех), `.env.example`, `Makefile` (`setup`, `dev`, `test`, `lint`, `codegen`, `l10n`, `check-generated`), GitHub Actions: lint + unit + контракты на каждый push; сборка APK и Windows-приложения и интеграционный прогон compose на PR в `main`.
- Node.js 24 LTS вместо 20 (согласовано; в SPEC раздел 4 исправлен). Схема архитектуры в SPEC 3 восстановлена из текста в Mermaid.
- `docs/AUDIT.md`: кода v1 нет; три расхождения внутри SPEC, по которым нужно решение.

Новые зависимости и зачем:

| Где | Пакет | Зачем |
| --- | --- | --- |
| backend | fastapi, uvicorn, sqlalchemy, alembic, psycopg, pydantic-settings | Стек из SPEC 4 |
| backend (dev) | pytest, httpx2, ruff, jsonschema, datamodel-code-generator | Тесты, линтер, контракты, генерация Python-моделей |
| media-server | ajv, ajv-formats | Проверка входящих WebSocket-сообщений по схемам |
| media-server | pino | Структурированные JSON-логи |
| media-server (dev) | typescript, tsx, vitest, eslint, typescript-eslint | Сборка, запуск в разработке, тесты, линтер |
| contracts (dev) | quicktype, ajv, ajv-formats | Генерация TS/Dart, контрактные тесты |
| apps | flutter_localizations, intl | Локализация ru/en |
