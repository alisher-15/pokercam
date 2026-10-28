# contracts/

JSON Schema (draft-07) всех сообщений между компонентами. Схема всегда первична: изменение протокола начинается здесь, затем `make codegen`, затем код всех компонентов.

| Путь | Что |
| --- | --- |
| `common.json` | Общие определения: id, время, параметры камеры, статус лицензии, цвета бренда |
| `ws/envelope.json` | Конверт любого WebSocket-сообщения: `{type, id, ts, table_id, payload}` |
| `ws/control/*.json` | Control-канал (SPEC 5.3): камера, телеметрия, предупреждения, поток, лицензия, DVR, AI |
| `ws/signaling/*.json` | Сигналинг mediasoup: запросы, ответы `.result` и `signaling.error` |
| `rest/*.json` | Тела запросов и ответов backend `/api/v1` (SPEC 5.2) |
| `auth/access_token_claims.json` | Claims access JWT, которые проверяет media-server |
| `branding/brand_config.json` | Формат `branding/<brand>/brand.json` |
| `examples/` | По одному валидному примеру на каждую схему, по тому же пути |

## Соглашения

- Файл WebSocket-сообщения называется по его `type`; ответ ссылается на запрос через `payload.request_id`.
- Время: в WebSocket — Unix-миллисекунды (`ts`, `since`, `grace_until`, …), в REST — строки RFC 3339.
- null никогда не отправляется: отсутствующее необязательное поле просто не пишется (`withoutNulls` в Dart, `exclude_none` в Python).
- Массивы отправляются всегда, хотя бы пустыми: сгенерированный Dart превращает отсутствующий массив в `[]`.
- У каждого объекта со свойствами есть `title` (это имя сгенерированного класса) и `additionalProperties: false`; у каждого enum есть `title`. Это проверяют контрактные тесты.
- Объекты mediasoup (RTP capabilities и parameters, ICE, DTLS) непрозрачны: они передаются в Device API mediasoup как есть. SDP вручную не собирается никогда.
- `device.alert.message_key` — ключ ARB из `apps/shared/lib/l10n`.

## Генерация кода

`make codegen` (скрипт `scripts/codegen.sh`) пишет:

| Компонент | Инструмент | Куда |
| --- | --- | --- |
| media-server | quicktype + `scripts/typescript-extras.mjs` | `media-server/src/contracts/{types,schemas,messages}.ts` |
| apps | quicktype + `scripts/dart-extras.mjs` | `apps/shared/lib/src/contracts/{contracts,messages}.dart`, `apps/shared/test/contract_models.dart` |
| backend | datamodel-codegen | `backend/app/contracts/` |

Сгенерированные файлы коммитятся и не правятся руками; CI генерирует их заново (`make check-generated`) и падает при любом расхождении.

## Тесты

- Здесь (`npm test`): каждая схема компилируется, у неё ровно один валидный пример, соблюдены соглашения выше; невалидные сообщения отклоняются; каждый бренд в `branding/` валиден.
- backend: каждый пример проходит `jsonschema` и без потерь проходит через сгенерированную pydantic-модель.
- media-server: каждый WebSocket-пример проходит проверку во время работы (`src/contracts/validate.ts`, ajv).
- apps/shared: каждый пример без потерь проходит через сгенерированный Dart-класс; `decodeMessage` выбирает класс по `type`.
