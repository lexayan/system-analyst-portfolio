-- Основные запросы. Параметры — в стиле подготовленных выражений ($1, $2, ...).

-- Q1. Свободные слоты по специальности и филиалу на период
-- $1 specialty_id, $2 branch_id, $3 period_from TIMESTAMPTZ, $4 period_to TIMESTAMPTZ
-- Индекс: ix_slot_specialty_branch_start; проверка занятости — по uq_appointment_active_slot
PREPARE q1_free_slots (BIGINT, BIGINT, TIMESTAMPTZ, TIMESTAMPTZ) AS
SELECT s.public_id AS slot_public_id, s.starts_at, s.ends_at,
       d.doctor_id, d.last_name, d.first_name, d.middle_name
FROM clinic.schedule_slot s
JOIN clinic.doctor d ON d.doctor_id = s.doctor_id AND d.is_active
WHERE s.specialty_id = $1
  AND s.branch_id = $2
  AND s.starts_at >= $3 AND s.starts_at < $4
  AND s.is_blocked = FALSE
  AND s.starts_at > now()
  AND NOT EXISTS (                        -- NOT EXISTS вместо NOT IN: безопасно при NULL
      SELECT 1 FROM clinic.appointment a
      WHERE a.slot_id = s.slot_id AND a.status <> 'cancelled')
ORDER BY s.starts_at, s.slot_id;

-- Q2. Создание записи (идемпотентно и без двойного бронирования)
-- $1 slot public_id, $2 patient_id, $3 idempotency_key
-- Гонки: два пациента на один слот → второй получает конфликт по uq_appointment_active_slot.
-- Повтор той же формы → конфликт по uq_appointment_idempotency, возвращаем существующую запись
-- вместе с её slot_id: если он не совпадает с запрошенным, ключ переиспользован для другого слота → 409.
PREPARE q2_book (UUID, BIGINT, UUID) AS
WITH slot AS (
    SELECT slot_id, starts_at FROM clinic.schedule_slot
    WHERE public_id = $1 AND is_blocked = FALSE AND starts_at > now()
), ins AS (
    INSERT INTO clinic.appointment (slot_id, patient_id, idempotency_key)
    SELECT slot_id, $2, $3 FROM slot
    ON CONFLICT DO NOTHING
    RETURNING appointment_id, public_id, status, slot_id
)
SELECT appointment_id, public_id, status, slot_id, TRUE AS created FROM ins
UNION ALL
SELECT appointment_id, public_id, status, slot_id, FALSE FROM clinic.appointment
WHERE patient_id = $2 AND idempotency_key = $3 AND NOT EXISTS (SELECT 1 FROM ins);
-- Пустой результат = слот занят, заблокирован или уже прошёл → API отвечает 409.
-- В той же транзакции приложение пишет appointment_status_history и appointment_notification (см. README, «Транзакции»).

-- Q3. Записи пациента, keyset-пагинация (без глубокого OFFSET)
-- $1 patient_id, $2 cursor_created_at, $3 cursor_appointment_id, $4 page_size
-- Индекс: ix_appointment_patient_created
PREPARE q3_patient_appointments (BIGINT, TIMESTAMPTZ, BIGINT, INTEGER) AS
SELECT a.public_id, a.status, a.created_at, a.appointment_id,
       s.starts_at, b.name AS branch_name, sp.name AS specialty_name,
       d.last_name AS doctor_last_name
FROM clinic.appointment a
JOIN clinic.schedule_slot s ON s.slot_id = a.slot_id
JOIN clinic.branch b ON b.branch_id = s.branch_id
JOIN clinic.specialty sp ON sp.specialty_id = s.specialty_id
JOIN clinic.doctor d ON d.doctor_id = s.doctor_id
WHERE a.patient_id = $1
  AND (a.created_at, a.appointment_id) < ($2, $3)
ORDER BY a.created_at DESC, a.appointment_id DESC
LIMIT $4;

-- Q4. Смена статуса с оптимистической блокировкой и проверкой допустимого перехода
-- $1 appointment_id, $2 expected_version, $3 new_status, $4 cancel_reason
-- 0 строк = версия устарела (кто-то изменил запись раньше) или переход недопустим → 409.
PREPARE q4_change_status (BIGINT, INTEGER, TEXT, TEXT) AS
UPDATE clinic.appointment
SET status = $3,
    cancel_reason = CASE WHEN $3 = 'cancelled' THEN $4 END,
    version = version + 1,
    updated_at = now()
WHERE appointment_id = $1
  AND version = $2
  AND (status, $3) IN (
      ('created', 'pending_confirmation'), ('pending_confirmation', 'confirmed'),
      ('confirmed', 'in_progress'), ('in_progress', 'completed'),
      ('created', 'cancelled'), ('pending_confirmation', 'cancelled'), ('confirmed', 'cancelled'))
RETURNING appointment_id, status, version;

-- Q5. Выборка напоминаний к отправке несколькими воркерами параллельно
-- $1 batch_size. SKIP LOCKED: воркеры не берут одни и те же строки и не ждут друг друга.
PREPARE q5_due_reminders (INTEGER) AS
SELECT n.notification_id, n.appointment_id, p.phone, s.starts_at
FROM clinic.appointment_notification n
JOIN clinic.appointment a ON a.appointment_id = n.appointment_id AND a.status IN ('created', 'pending_confirmation', 'confirmed')
JOIN clinic.patient p ON p.patient_id = a.patient_id
JOIN clinic.schedule_slot s ON s.slot_id = a.slot_id
WHERE n.status = 'pending' AND n.scheduled_at <= now()
ORDER BY n.scheduled_at
LIMIT $1
FOR UPDATE OF n SKIP LOCKED;

-- Q6. Результаты анализов по записи
-- $1 appointment_public_id
PREPARE q6_lab_results (UUID) AS
SELECT t.code, t.name, t.unit, i.result_value, i.result_text, i.reference_low, i.reference_high, i.result_at,
       CASE WHEN i.result_value IS NULL THEN NULL
            WHEN i.result_value < i.reference_low OR i.result_value > i.reference_high THEN TRUE
            ELSE FALSE END AS is_out_of_range
FROM clinic.appointment a
JOIN clinic.lab_order o ON o.appointment_id = a.appointment_id
JOIN clinic.lab_order_item i ON i.lab_order_id = o.lab_order_id
JOIN clinic.lab_test t ON t.lab_test_id = i.lab_test_id
WHERE a.public_id = $1
ORDER BY t.name;
