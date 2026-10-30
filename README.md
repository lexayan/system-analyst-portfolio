# Портфолио системного аналитика — Алексей Янушковский

Junior системный аналитик. Прохожу курс «Системный аналитик» в Яндекс Практикуме и учусь в БГУИР по специальности «Системы управления информацией». Здесь 9 учебных проектов: требования и SRS, проектирование API и интеграций, модели данных, BPMN и UML, приёмка и тестирование.

**Контакты:** Минск · +375 33 398-98-66 · lexayanush@gmail.com

## С чего начать за 5 минут

1. [Otium: доработка API](projects/01-otium-api/README.md) — требования из интервью, постановка задачи на 7 методов REST API, XSD для SOAP.
2. [Агрегатор авиабилетов](projects/02-airline-booking-integration/README.md) — sequence-диаграмма интеграции с авиакомпаниями, платёжным сервисом и банками.
3. [Capsule: приёмка сайта](projects/03-capsule-acceptance/README.md) — ПМИ, 12 тест-кейсов, руководство пользователя.

## Проекты

| # | Проект | Домен | Что показывает |
|---|---|---|---|
| 01 | [Otium: доработка API](projects/01-otium-api/README.md) | Медиа | Интервью с заказчиком, REST API, JSON, Swagger, Postman, SOAP/XSD, командная работа |
| 02 | [Агрегатор авиабилетов](projects/02-airline-booking-integration/README.md) | Travel / финтех | UML Sequence: параллельные запросы, бронь с таймаутом, оплата через эквайринг |
| 03 | [Capsule: приёмка сайта](projects/03-capsule-acceptance/README.md) | Бронирование | ПМИ, тест-кейсы, протокол тестирования, руководство пользователя |
| 04 | [Chatty 2.0: SRS](projects/04-chatty-srs/README.md) | EdTech | SRS по Вигерсу, 11 Use Case, словарь данных, измеримые НФТ, внешние интерфейсы |
| 05 | [«Накарабине»: SRS](projects/05-nakarabine-srs/README.md) | E-commerce | SRS интернет-магазина, 12 Use Case, ограничения и зависимости |
| 06 | [ER-модель и нормализация](projects/06-data-modeling-er/README.md) | E-commerce | Нотации Чена и Crow's Foot, 1НФ → 3НФ |
| 07 | [Клиника: онлайн-запись](projects/07-clinic-appointment/README.md) | Медицина | BPMN as-is / to-be, UML State Machine, DFD |
| 08 | [Информационная система банка](projects/08-bank-information-system/README.md) | Банк | BPMN, Use Case с внешними системами, полный набор UML, компоненты и развёртывание |
| 09 | [Управление музыкальными треками](projects/09-music-track-management/README.md) | Медиа | Глоссарий, НФТ, Use Case с альтернативными потоками, UML |

Проекты 01–07 выполнены на курсе Яндекс Практикума (01 — в команде), 08–09 — курсовое проектирование в БГУИР. Все проекты учебные, внедрения не было.

## Навыки

Подробно, со ссылками на артефакты, — в [матрице навыков](docs/skills-matrix.md).

- **Требования:** интервью с заказчиком, SRS (К. Вигерс), Use Case (А. Коберн), функциональные и нефункциональные требования, бизнес-правила, словарь данных, постановка задач разработчикам
- **Моделирование:** BPMN 2.0, UML (Use Case, Sequence, Activity, State Machine, Class, Component, Deployment, Communication), DFD, ER (Чен, Crow's Foot), нормализация до 3НФ
- **Интеграции и API:** REST, HTTP, JSON, SOAP, XML, XSD, Swagger, Postman
- **Данные:** SQL (PostgreSQL, MySQL), проектирование реляционных БД
- **Приёмка:** ПМИ, тест-кейсы, руководство пользователя
- **Инструменты:** draw.io, Figma, Postman, Swagger, MS Visio, ERwin

## Структура репозитория

```
projects/
  01-otium-api/                    постановка задачи на доработку API
  02-airline-booking-integration/  sequence-диаграмма интеграции
  03-capsule-acceptance/           ПМИ, протокол тестирования, руководство
  04-chatty-srs/                   SRS и Use Case
  05-nakarabine-srs/               SRS интернет-магазина
  06-data-modeling-er/             ER-модели и нормализация
  07-clinic-appointment/           BPMN, State Machine, DFD
  08-bank-information-system/      требования и UML (курсовой проект)
  09-music-track-management/       требования и UML (курсовой проект)
docs/                              матрица навыков
```
