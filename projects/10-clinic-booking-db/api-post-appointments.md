# [POST /api/v1/appointments] Записаться к врачу на выбранный слот

## Связанные документы

| Документ | Ссылка |
|---|---|
| Модель данных (DDL) | [schema.sql](schema.sql) |
| Запросы, в т.ч. Q2 «Создание записи» | [queries.sql](queries.sql) |
| Жизненный цикл записи и проверки модели | [README.md](README.md) |
| Диаграмма последовательности | [sequence-post-appointments.puml](sequence-post-appointments.puml) |

## Общее описание

Пациент в мобильном приложении или на сайте клиники выбирает свободный слот врача (дата, время, филиал, специальность) и нажимает «Записаться». Метод создаёт запись в статусе `created`, фиксирует её в истории статусов и планирует напоминание за 24 часа до приёма.

Успешный результат: слот закреплён за пациентом, другие пациенты больше не видят его свободным, клиент получает данные записи.

## Доступы

- Метод защищён.
- Аутентификация: `Authorization: Bearer <JWT>`, обязательна.
- Роль: `patient`.
- Владение: запись создаётся только для пациента из токена; `public_id` пациента берётся из claim `sub`. Передать чужого пациента в запросе нельзя — такого поля нет в контракте.

## Нефункциональные требования

- Идемпотентность: повтор запроса с тем же `Idempotency-Key` от того же пациента не создаёт новую запись и возвращает ранее созданную.
- Конкурентность: при одновременных запросах разных пациентов на один слот запись создаётся ровно одна, остальные получают `409 SLOT_ALREADY_BOOKED`. Гарантия обеспечивается уникальным индексом `uq_appointment_active_slot`, а не предварительной проверкой.
- Атомарность: запись, строка истории статусов и напоминание создаются в одной транзакции либо не создаются вовсе.

## Ограничения

- Не разрабатываются: отмена и перенос записи, отправка напоминания (выполняет отдельный воркер, см. Q5), оплата приёма.

## Контракт запроса

```text
Method type: POST
API version: v1
Method name: /api/v1/appointments
Authorization: Bearer JWT, роль patient
```

### Headers

| Header | Обяз. | Формат | Default | Описание | Ошибка при нарушении |
|---|---:|---|---|---|---|
| `Authorization` | да | `Bearer <JWT>` | — | Токен пациента | `401 UNAUTHORIZED` |
| `Content-Type` | да | `application/json` | — | Формат тела | `415 UNSUPPORTED_MEDIA_TYPE` |
| `Idempotency-Key` | да | UUID | — | Ключ клиента для защиты от повторной отправки; генерируется при открытии формы записи | отсутствует или не UUID → `400 VALIDATION_ERROR` |
| `X-Request-Id` | нет | строка до 64 символов | генерируется сервером | Идентификатор запроса для трассировки | — |

## Пример запроса

```http
POST /api/v1/appointments HTTP/1.1
Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.<payload>.<signature>
Content-Type: application/json
Idempotency-Key: 7d3f6c2a-91b4-4e0a-8a55-2f0c1c9b6e11
X-Request-Id: req-2026-11-02-000184
```

## Тело запроса (Body)

```json
{
  "slotId": "f163d599-9213-49fe-8aca-813c8b64fc63"
}
```

| JSON path | Обяз. | Nullable | Тип/формат | Описание | Ограничения/валидация | Ошибка |
|---|---:|---:|---|---|---|---|
| `slotId` | да | нет | string, UUID | Публичный идентификатор слота из списка свободных слотов | валидный UUID | `400 VALIDATION_ERROR`; слот не найден → `404 SLOT_NOT_FOUND` |

Неизвестные поля тела игнорируются.

## Пример ответа — Успех

**Запись создана** — `201 Created`

```http
HTTP/1.1 201 Created
Location: /api/v1/appointments/04f0f0ef-cba0-47b1-9b4c-d2ac2d7f9cd7
Content-Type: application/json
```

```json
{
  "appointmentId": "04f0f0ef-cba0-47b1-9b4c-d2ac2d7f9cd7",
  "status": "created",
  "createdAt": "2026-11-02T18:42:40Z",
  "slot": {
    "slotId": "f163d599-9213-49fe-8aca-813c8b64fc63",
    "startsAt": "2026-11-03T07:00:00Z",
    "endsAt": "2026-11-03T07:30:00Z"
  },
  "doctor": {
    "lastName": "Ковалёва",
    "firstName": "Ирина",
    "middleName": "Петровна"
  },
  "specialty": {
    "code": "therapist",
    "name": "Терапевт"
  },
  "branch": {
    "name": "Центр",
    "address": "Минск, пр-т Независимости, 58",
    "timeZone": "Europe/Minsk"
  }
}
```

**Повтор с тем же `Idempotency-Key` и тем же `slotId`** — `200 OK`, то же тело и `Location`, что при создании. Новая запись не создаётся.

## Ошибочные ответы

Формат всех ошибок — `application/problem+json` (RFC 9457) с полем `code`.

| Условие | Этап проверки | HTTP | code | message |
|---|---|---:|---|---|
| Нет токена, токен истёк или недействителен | Аутентификация | 401 | `UNAUTHORIZED` | Требуется авторизация |
| Роль не `patient` | Авторизация | 403 | `FORBIDDEN` | Недостаточно прав |
| Пациент из токена не найден в клинике | Авторизация | 403 | `PATIENT_NOT_REGISTERED` | Пациент не зарегистрирован |
| `Content-Type` не `application/json` | Протокольные проверки | 415 | `UNSUPPORTED_MEDIA_TYPE` | Ожидается application/json |
| Невалидный JSON, нет `slotId`, `slotId` или `Idempotency-Key` не UUID | Форматная валидация | 400 | `VALIDATION_ERROR` | Некорректные параметры запроса |
| Слота с таким `slotId` нет | Поиск слота | 404 | `SLOT_NOT_FOUND` | Слот не найден |
| Слот заблокирован клиникой или уже начался | Бизнес-проверки | 422 | `SLOT_NOT_AVAILABLE` | Запись на этот слот невозможна |
| Слот занят другой активной записью | Вставка | 409 | `SLOT_ALREADY_BOOKED` | Слот уже занят, выберите другое время |
| Тот же `Idempotency-Key` уже использован для другого слота | Вставка | 409 | `IDEMPOTENCY_KEY_REUSED` | Ключ уже использован для другой записи |
| Ошибка БД, кроме конфликтов уникальности | Транзакция | 500 | `INTERNAL_ERROR` | Внутренняя ошибка, повторите позже |

### Пример ответа — Ошибка авторизации

```json
{
  "type": "https://errors.example/unauthorized",
  "title": "Требуется авторизация",
  "status": 401,
  "code": "UNAUTHORIZED",
  "instance": "/api/v1/appointments"
}
```

### Пример ответа — Запись не найдена

```json
{
  "type": "https://errors.example/slot-not-found",
  "title": "Слот не найден",
  "status": 404,
  "code": "SLOT_NOT_FOUND",
  "instance": "/api/v1/appointments"
}
```

### Пример ответа — Слот уже занят

```json
{
  "type": "https://errors.example/slot-already-booked",
  "title": "Слот уже занят, выберите другое время",
  "status": 409,
  "code": "SLOT_ALREADY_BOOKED",
  "instance": "/api/v1/appointments"
}
```

### Пример ответа — Ошибка валидации

```json
{
  "type": "https://errors.example/validation-error",
  "title": "Некорректные параметры запроса",
  "status": 400,
  "code": "VALIDATION_ERROR",
  "errors": [
    { "field": "slotId", "message": "Должен быть UUID" }
  ]
}
```

## Требования к реализации

1. Принять запрос. Если `Content-Type` не `application/json` — вернуть `415`.
2. Проверить JWT: подпись, срок действия. Ошибка — `401`.
3. Проверить роль `patient` — иначе `403 FORBIDDEN`. Найти пациента: `clinic.patient` по `public_id = sub`. Не найден — `403 PATIENT_NOT_REGISTERED`.
4. Проверить формат: JSON разбирается, `slotId` — UUID, `Idempotency-Key` — UUID. Ошибка — `400 VALIDATION_ERROR` со списком полей.
5. Найти слот: `clinic.schedule_slot` по `public_id = slotId`. Не найден — `404 SLOT_NOT_FOUND`.
6. Если `is_blocked = true` или `starts_at <= now()` — `422 SLOT_NOT_AVAILABLE`.
7. Открыть транзакцию (`READ COMMITTED`).
8. Выполнить Q2 (`queries.sql`): вставка в `clinic.appointment` с `ON CONFLICT DO NOTHING`.
   - Строка с `created = true` — перейти к шагу 9.
   - Строка с `created = false`: это повтор. Если `slot_id` записи совпадает со слотом из запроса — откатить транзакцию и вернуть `200 OK` с данными существующей записи (шаг 11). Иначе — откатить, `409 IDEMPOTENCY_KEY_REUSED`.
   - 0 строк: слот занят активной записью другого пациента (`uq_appointment_active_slot`) или стал недоступен между шагами 6 и 8 — откатить, `409 SLOT_ALREADY_BOOKED`.
9. В той же транзакции:
   - `INSERT` в `clinic.appointment_status_history`: `from_status = NULL`, `to_status = 'created'`, `changed_by = 'patient'`;
   - `INSERT` в `clinic.appointment_notification`: `kind = 'reminder_24h'`, `scheduled_at = starts_at − 24 часа`, `status = 'pending'`. Если слот начинается раньше чем через 24 часа, `scheduled_at = now()`.
10. `COMMIT`. Ошибка БД — откат, `500 INTERNAL_ERROR`.
11. Сформировать ответ по разделу «Маппинг данных»: `201 Created` + `Location` для новой записи, `200 OK` для повтора.

Кэширование ответа не применяется. После commit кэши списка свободных слотов, если они есть у клиента или BFF, должны быть сброшены по слоту.

## Маппинг данных

### Request → БД

| Источник | Поле | Преобразование/правило | Назначение | Комментарий |
|---|---|---|---|---|
| JWT | `sub` | поиск по `clinic.patient.public_id` | `clinic.appointment.patient_id` | внутренний ID пациента |
| Body | `slotId` | поиск по `clinic.schedule_slot.public_id` | `clinic.appointment.slot_id` | внутренний ID слота |
| Header | `Idempotency-Key` | без изменений | `clinic.appointment.idempotency_key` | уникален в паре с `patient_id` |
| — | — | `'created'` | `clinic.appointment.status` | значение по умолчанию |

### БД → Response

| JSON path | Тип | Обяз. | Nullable | Источник | Преобразование/правило |
|---|---|---:|---:|---|---|
| `appointmentId` | string UUID | да | нет | `appointment.public_id` | — |
| `status` | string | да | нет | `appointment.status` | — |
| `createdAt` | string date-time | да | нет | `appointment.created_at` | ISO 8601, UTC |
| `slot.slotId` | string UUID | да | нет | `schedule_slot.public_id` | — |
| `slot.startsAt` | string date-time | да | нет | `schedule_slot.starts_at` | ISO 8601, UTC |
| `slot.endsAt` | string date-time | да | нет | `schedule_slot.ends_at` | ISO 8601, UTC |
| `doctor.lastName` | string | да | нет | `doctor.last_name` | через `schedule_slot.doctor_id` |
| `doctor.firstName` | string | да | нет | `doctor.first_name` | — |
| `doctor.middleName` | string | да | да | `doctor.middle_name` | `null`, если отчества нет |
| `specialty.code` | string | да | нет | `specialty.code` | через `schedule_slot.specialty_id` |
| `specialty.name` | string | да | нет | `specialty.name` | — |
| `branch.name` | string | да | нет | `branch.name` | через `schedule_slot.branch_id` |
| `branch.address` | string | да | нет | `branch.address` | — |
| `branch.timeZone` | string | да | нет | `branch.time_zone` | IANA; клиент показывает время слота в этом поясе |

## Логирование и мониторинг

### Логи

- Каждый запрос: `requestId`, `traceId`, `patientPublicId`, `slotId`, `idempotencyKeyHash` (SHA-256, не сам ключ), HTTP-код, `code` ошибки, длительность.
- Не логировать JWT, ФИО, телефон и email пациента.
- Ошибки БД — уровень `ERROR` с именем нарушенного ограничения, без значений параметров.

### Метрики

- `appointments_create_total{result}` — `created`, `replayed`, `slot_already_booked`, `slot_not_available`, `slot_not_found`, `idempotency_key_reused`, `error`.
- `appointments_create_duration_seconds` — p50, p95, p99.
- Доля `409 SLOT_ALREADY_BOOKED` от всех попыток — показатель конкуренции за слоты.

### Алерты

- Рост доли `500 INTERNAL_ERROR`.
- Рост p95 длительности метода.
- Всплеск `IDEMPOTENCY_KEY_REUSED`: признак ошибки генерации ключа на клиенте.

### Аудит

Для созданной записи: actor = пациент (`public_id`), action = `appointment.create`, resource = `appointmentId`, timestamp, `traceId`. История статусов хранится в `clinic.appointment_status_history`.
