-- Онлайн-запись к врачу: физическая модель (PostgreSQL 15+)
-- Порядок: схема → расширения → справочники → бизнес-таблицы → связи → индексы → комментарии

CREATE SCHEMA IF NOT EXISTS clinic;

-- Нужно для EXCLUDE-ограничения «у врача не пересекаются слоты» (равенство по doctor_id + пересечение диапазонов)
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ---------- Справочники ----------

CREATE TABLE clinic.branch (
    branch_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        TEXT        NOT NULL,
    address     TEXT        NOT NULL,
    time_zone   TEXT        NOT NULL,           -- IANA, например 'Europe/Minsk': нужен для показа слотов в местном времени
    is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_branch_name UNIQUE (name)
);

CREATE TABLE clinic.specialty (
    specialty_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code         TEXT NOT NULL,
    name         TEXT NOT NULL,
    CONSTRAINT uq_specialty_code UNIQUE (code)
);

CREATE TABLE clinic.lab_test (
    lab_test_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        TEXT NOT NULL,
    name        TEXT NOT NULL,
    unit        TEXT,
    CONSTRAINT uq_lab_test_code UNIQUE (code)
);

-- ---------- Участники ----------

CREATE TABLE clinic.doctor (
    doctor_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    last_name  TEXT    NOT NULL,
    first_name TEXT    NOT NULL,
    middle_name TEXT,
    is_active  BOOLEAN NOT NULL DEFAULT TRUE
);

-- M:N: врач может вести приём по нескольким специальностям
CREATE TABLE clinic.doctor_specialty (
    doctor_id    BIGINT NOT NULL REFERENCES clinic.doctor (doctor_id) ON DELETE RESTRICT,
    specialty_id BIGINT NOT NULL REFERENCES clinic.specialty (specialty_id) ON DELETE RESTRICT,
    PRIMARY KEY (doctor_id, specialty_id)
);

CREATE TABLE clinic.patient (
    patient_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id   UUID        NOT NULL DEFAULT gen_random_uuid(),   -- отдаётся во внешний API вместо внутреннего ID
    last_name   TEXT        NOT NULL,
    first_name  TEXT        NOT NULL,
    middle_name TEXT,
    birth_date  DATE        NOT NULL,
    phone       TEXT        NOT NULL,                             -- E.164: +375291234567
    email       TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_patient_public_id UNIQUE (public_id),
    CONSTRAINT uq_patient_phone UNIQUE (phone),
    CONSTRAINT ck_patient_phone_e164 CHECK (phone ~ '^\+[1-9][0-9]{7,14}$'),
    CONSTRAINT ck_patient_birth_date CHECK (birth_date > DATE '1900-01-01')
);

-- ---------- Расписание ----------

CREATE TABLE clinic.schedule_slot (
    slot_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id    UUID        NOT NULL DEFAULT gen_random_uuid() CONSTRAINT uq_slot_public_id UNIQUE,
    doctor_id    BIGINT      NOT NULL,
    specialty_id BIGINT      NOT NULL,
    branch_id    BIGINT      NOT NULL REFERENCES clinic.branch (branch_id) ON DELETE RESTRICT,
    starts_at    TIMESTAMPTZ NOT NULL,
    ends_at      TIMESTAMPTZ NOT NULL,
    is_blocked   BOOLEAN     NOT NULL DEFAULT FALSE,   -- слот закрыт клиникой (отпуск, болезнь), запись невозможна
    -- слот только по специальности, которую врач реально ведёт
    CONSTRAINT fk_slot_doctor_specialty FOREIGN KEY (doctor_id, specialty_id)
        REFERENCES clinic.doctor_specialty (doctor_id, specialty_id) ON DELETE RESTRICT,
    CONSTRAINT ck_slot_period CHECK (ends_at > starts_at),
    -- врач не может быть в двух местах одновременно, даже в разных филиалах
    CONSTRAINT ex_slot_doctor_no_overlap EXCLUDE USING gist (
        doctor_id WITH =,
        tstzrange(starts_at, ends_at, '[)') WITH &&
    )
);

-- ---------- Запись ----------

CREATE TABLE clinic.appointment (
    appointment_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    public_id       UUID        NOT NULL DEFAULT gen_random_uuid(),
    slot_id         BIGINT      NOT NULL REFERENCES clinic.schedule_slot (slot_id) ON DELETE RESTRICT,
    patient_id      BIGINT      NOT NULL REFERENCES clinic.patient (patient_id) ON DELETE RESTRICT,
    status          TEXT        NOT NULL DEFAULT 'created',
    idempotency_key UUID        NOT NULL,          -- ключ клиента: повторная отправка формы не создаёт вторую запись
    cancel_reason   TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    version         INTEGER     NOT NULL DEFAULT 1, -- оптимистическая блокировка при смене статуса
    CONSTRAINT uq_appointment_public_id UNIQUE (public_id),
    CONSTRAINT uq_appointment_idempotency UNIQUE (patient_id, idempotency_key),
    CONSTRAINT ck_appointment_status CHECK (status IN
        ('created', 'pending_confirmation', 'confirmed', 'in_progress', 'completed', 'cancelled')),
    CONSTRAINT ck_appointment_cancel_reason CHECK ((status = 'cancelled') = (cancel_reason IS NOT NULL))
);

-- На один слот — не больше одной НЕотменённой записи. Гарантия на уровне БД, а не «SELECT, потом INSERT».
CREATE UNIQUE INDEX uq_appointment_active_slot
    ON clinic.appointment (slot_id)
    WHERE status <> 'cancelled';

-- История статусов: кто, когда и почему перевёл запись
CREATE TABLE clinic.appointment_status_history (
    history_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appointment_id BIGINT      NOT NULL REFERENCES clinic.appointment (appointment_id) ON DELETE RESTRICT,
    from_status    TEXT,
    to_status      TEXT        NOT NULL,
    changed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    changed_by     TEXT        NOT NULL,           -- 'patient', 'system', 'doctor:42', 'admin:7'
    reason         TEXT
);

-- Напоминания: одна строка на тип уведомления, повторная отправка исключена уникальностью
CREATE TABLE clinic.appointment_notification (
    notification_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appointment_id  BIGINT      NOT NULL REFERENCES clinic.appointment (appointment_id) ON DELETE RESTRICT,
    kind            TEXT        NOT NULL,
    scheduled_at    TIMESTAMPTZ NOT NULL,
    status          TEXT        NOT NULL DEFAULT 'pending',
    attempts        SMALLINT    NOT NULL DEFAULT 0,
    sent_at         TIMESTAMPTZ,
    last_error      TEXT,
    CONSTRAINT uq_notification_kind UNIQUE (appointment_id, kind),
    CONSTRAINT ck_notification_kind CHECK (kind IN ('reminder_24h')),
    CONSTRAINT ck_notification_status CHECK (status IN ('pending', 'sent', 'failed', 'cancelled')),
    CONSTRAINT ck_notification_sent CHECK ((status = 'sent') = (sent_at IS NOT NULL)),
    CONSTRAINT ck_notification_attempts CHECK (attempts BETWEEN 0 AND 10)
);

-- ---------- Анализы ----------

CREATE TABLE clinic.lab_order (
    lab_order_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appointment_id    BIGINT      NOT NULL REFERENCES clinic.appointment (appointment_id) ON DELETE RESTRICT,
    external_order_id TEXT,                         -- номер заказа в ЛИС лаборатории, приходит после отправки
    status            TEXT        NOT NULL DEFAULT 'ordered',
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_lab_order_external UNIQUE (external_order_id),
    CONSTRAINT ck_lab_order_status CHECK (status IN ('ordered', 'sent_to_lab', 'partially_ready', 'ready', 'cancelled'))
);

CREATE TABLE clinic.lab_order_item (
    lab_order_id  BIGINT        NOT NULL REFERENCES clinic.lab_order (lab_order_id) ON DELETE CASCADE, -- позиция не живёт без назначения
    lab_test_id   BIGINT        NOT NULL REFERENCES clinic.lab_test (lab_test_id) ON DELETE RESTRICT,
    result_value  NUMERIC(12, 4),
    result_text   TEXT,                             -- качественные результаты: «отрицательно»
    reference_low  NUMERIC(12, 4),
    reference_high NUMERIC(12, 4),
    result_at     TIMESTAMPTZ,
    PRIMARY KEY (lab_order_id, lab_test_id),
    CONSTRAINT ck_lab_item_reference CHECK (reference_low IS NULL OR reference_high IS NULL OR reference_low <= reference_high),
    CONSTRAINT ck_lab_item_result_time CHECK ((result_at IS NULL) = (result_value IS NULL AND result_text IS NULL))
);

-- ---------- Индексы под конкретные запросы (см. queries.sql) ----------

-- Q1: свободные слоты по специальности и филиалу в диапазоне дат
CREATE INDEX ix_slot_specialty_branch_start
    ON clinic.schedule_slot (specialty_id, branch_id, starts_at)
    WHERE is_blocked = FALSE;

-- FK-индексы: PostgreSQL не создаёт их сам
CREATE INDEX ix_slot_branch ON clinic.schedule_slot (branch_id);
CREATE INDEX ix_doctor_specialty_specialty ON clinic.doctor_specialty (specialty_id);
CREATE INDEX ix_appointment_patient_created ON clinic.appointment (patient_id, created_at DESC, appointment_id DESC); -- Q3: список записей пациента
CREATE INDEX ix_status_history_appointment ON clinic.appointment_status_history (appointment_id, changed_at);
CREATE INDEX ix_lab_order_appointment ON clinic.lab_order (appointment_id);
CREATE INDEX ix_lab_item_test ON clinic.lab_order_item (lab_test_id);

-- Q5: очередь неотправленных напоминаний
CREATE INDEX ix_notification_due
    ON clinic.appointment_notification (scheduled_at)
    WHERE status = 'pending';

COMMENT ON TABLE clinic.appointment IS 'Запись пациента на слот. Жизненный цикл: created → pending_confirmation → confirmed → in_progress → completed; отмена из created/pending_confirmation/confirmed.';
COMMENT ON INDEX clinic.uq_appointment_active_slot IS 'Защита от двойной записи на один слот при параллельных запросах.';
