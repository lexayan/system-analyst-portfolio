-- Тестовые данные (данные вымышленные)

INSERT INTO clinic.branch (name, address, time_zone) VALUES
    ('Центр', 'Минск, пр-т Независимости, 58', 'Europe/Minsk'),
    ('Восток', 'Минск, ул. Филимонова, 25', 'Europe/Minsk');

INSERT INTO clinic.specialty (code, name) VALUES
    ('therapist', 'Терапевт'),
    ('cardiologist', 'Кардиолог'),
    ('ent', 'Оториноларинголог');

INSERT INTO clinic.lab_test (code, name, unit) VALUES
    ('cbc_hgb', 'Гемоглобин', 'г/л'),
    ('glucose', 'Глюкоза крови', 'ммоль/л'),
    ('covid_pcr', 'ПЦР на SARS-CoV-2', NULL);

INSERT INTO clinic.doctor (last_name, first_name, middle_name) VALUES
    ('Ковалёва', 'Ирина', 'Петровна'),
    ('Савицкий', 'Андрей', 'Николаевич'),
    ('Литвин', 'Ольга', NULL);

INSERT INTO clinic.doctor_specialty (doctor_id, specialty_id)
SELECT d.doctor_id, s.specialty_id
FROM (VALUES ('Ковалёва', 'therapist'), ('Савицкий', 'cardiologist'), ('Савицкий', 'therapist'), ('Литвин', 'ent'))
     AS v (last_name, code)
JOIN clinic.doctor d ON d.last_name = v.last_name
JOIN clinic.specialty s ON s.code = v.code;

INSERT INTO clinic.patient (last_name, first_name, middle_name, birth_date, phone, email) VALUES
    ('Новикова', 'Мария', 'Сергеевна', DATE '1994-03-12', '+375291112233', 'maria@example.com'),
    ('Петров', 'Илья', NULL, DATE '1987-11-02', '+375447778899', NULL),
    ('Ермакова', 'Анна', 'Викторовна', DATE '1960-07-25', '+375339990011', 'anna@example.com');

-- Слоты по 30 минут на ближайшие 3 дня
INSERT INTO clinic.schedule_slot (doctor_id, specialty_id, branch_id, starts_at, ends_at, is_blocked)
SELECT ds.doctor_id, ds.specialty_id,
       CASE WHEN d.last_name = 'Литвин' THEN 2 ELSE 1 END,
       t, t + INTERVAL '30 minutes',
       FALSE
FROM clinic.doctor_specialty ds
JOIN clinic.doctor d ON d.doctor_id = ds.doctor_id
CROSS JOIN LATERAL generate_series(
    date_trunc('day', now()) + INTERVAL '1 day 9 hours',
    date_trunc('day', now()) + INTERVAL '3 days 12 hours',
    INTERVAL '30 minutes') AS t
WHERE extract(hour FROM t) BETWEEN 9 AND 11
  -- у Савицкого две специальности: кардиологом принимает в первой половине часа, терапевтом — во второй
  AND NOT (d.last_name = 'Савицкий' AND ((ds.specialty_id = 2) <> (extract(minute FROM t) = 0)));

-- Заблокированный слот (отпуск)
UPDATE clinic.schedule_slot SET is_blocked = TRUE
WHERE slot_id = (SELECT min(slot_id) FROM clinic.schedule_slot WHERE doctor_id = 3);

-- Записи в разных статусах
INSERT INTO clinic.appointment (slot_id, patient_id, status, idempotency_key, cancel_reason)
VALUES
    ((SELECT slot_id FROM clinic.schedule_slot WHERE doctor_id = 1 ORDER BY starts_at LIMIT 1), 1, 'confirmed', gen_random_uuid(), NULL),
    ((SELECT slot_id FROM clinic.schedule_slot WHERE doctor_id = 2 ORDER BY starts_at LIMIT 1), 2, 'pending_confirmation', gen_random_uuid(), NULL),
    ((SELECT slot_id FROM clinic.schedule_slot WHERE doctor_id = 1 ORDER BY starts_at OFFSET 1 LIMIT 1), 3, 'cancelled', gen_random_uuid(), 'Пациент заболел, перенесёт запись'),
    -- на освободившийся слот можно записаться снова: отменённая запись не блокирует слот
    ((SELECT slot_id FROM clinic.schedule_slot WHERE doctor_id = 1 ORDER BY starts_at OFFSET 1 LIMIT 1), 2, 'created', gen_random_uuid(), NULL);

INSERT INTO clinic.appointment_status_history (appointment_id, from_status, to_status, changed_by, reason) VALUES
    (1, NULL, 'created', 'patient', NULL),
    (1, 'created', 'pending_confirmation', 'system', 'Отправлено напоминание за 24 часа'),
    (1, 'pending_confirmation', 'confirmed', 'patient', NULL),
    (3, NULL, 'created', 'patient', NULL),
    (3, 'created', 'cancelled', 'patient', 'Пациент заболел, перенесёт запись');

INSERT INTO clinic.appointment_notification (appointment_id, kind, scheduled_at, status, attempts, sent_at)
SELECT a.appointment_id, 'reminder_24h', s.starts_at - INTERVAL '24 hours',
       CASE WHEN a.status = 'confirmed' THEN 'sent' ELSE 'pending' END,
       CASE WHEN a.status = 'confirmed' THEN 1 ELSE 0 END,
       CASE WHEN a.status = 'confirmed' THEN s.starts_at - INTERVAL '24 hours' END
FROM clinic.appointment a
JOIN clinic.schedule_slot s ON s.slot_id = a.slot_id
WHERE a.status <> 'cancelled';

-- Назначение анализов по итогам приёма 1 (один результат готов, второй ещё в работе)
INSERT INTO clinic.lab_order (appointment_id, external_order_id, status) VALUES (1, 'LIS-2026-000123', 'partially_ready');
INSERT INTO clinic.lab_order_item (lab_order_id, lab_test_id, result_value, reference_low, reference_high, result_at) VALUES
    (1, 1, 128.0, 120.0, 140.0, now()),
    (1, 2, NULL, 3.3, 5.5, NULL);
