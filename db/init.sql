-- Схема ядра DSM (учебная, только текущие сущности).
-- Логика: сущности и связи, без координат.
-- Сущности: Device, Link, Frame, Resource, Connector, Holder.
-- Связи: ресурсное соединение = пара Connector↔Connector;
--        механическая привязка = пара Holder↔Holder;
--        составность через parent-ссылки.
-- Представление: view (реестр представлений) + placement (размещение сущностей
-- в конкретном представлении, геометрия в jsonb). Добавление нового
-- представления (3D и пр.) не меняет логические таблицы.

CREATE TABLE resource (
    id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL UNIQUE
);
COMMENT ON TABLE resource IS 'Профиль ресурса; один экземпляр на профиль во всей модели (вода, электричество 230В, данные DALI…)';

CREATE TABLE device (
    id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name             text NOT NULL,
    parent_device_id integer REFERENCES device(id)
);
COMMENT ON TABLE device IS 'Устройство: преобразует, накапливает, отдаёт или регулирует ресурс. Составное Device содержит внутреннюю схему (Device + Link + Frame). Размещение — в placement';

CREATE TABLE link (
    id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name             text NOT NULL,
    resource_id      integer REFERENCES resource(id),
    parent_device_id integer REFERENCES device(id),
    parent_link_id   integer REFERENCES link(id)
);
COMMENT ON TABLE link IS 'Соединение: пассивно передаёт ресурс без изменения его вида. Составной Link (кабель → жилы); может входить в состав Device. Трасса — в placement';

CREATE TABLE frame (
    id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name             text NOT NULL,
    parent_device_id integer REFERENCES device(id),
    parent_frame_id  integer REFERENCES frame(id)
);
COMMENT ON TABLE frame IS 'Несущая конструкция: ресурс не передаёт, коннекторов нет. Размещение — в placement';

CREATE TABLE connector (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        text NOT NULL,
    device_id   integer REFERENCES device(id),
    link_id     integer REFERENCES link(id),
    resource_id integer REFERENCES resource(id),
    CONSTRAINT connector_one_owner CHECK (
        (device_id IS NOT NULL)::int + (link_id IS NOT NULL)::int = 1
    )
);
COMMENT ON TABLE connector IS 'Разъём: точка входа/выхода/промежуточного подключения ресурса. Принадлежит Device или Link. Позиция — в placement';

CREATE TABLE holder (
    id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name      text NOT NULL,
    device_id integer REFERENCES device(id),
    link_id   integer REFERENCES link(id),
    frame_id  integer REFERENCES frame(id),
    CONSTRAINT holder_one_owner CHECK (
        (device_id IS NOT NULL)::int + (link_id IS NOT NULL)::int + (frame_id IS NOT NULL)::int = 1
    )
);
COMMENT ON TABLE holder IS 'Крепление: деталь или зона механического контакта. Принадлежит Device, Link или Frame. Позиция — в placement';

CREATE TABLE connector_plug (
    id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    connector_a_id integer NOT NULL REFERENCES connector(id),
    connector_b_id integer NOT NULL REFERENCES connector(id),
    CONSTRAINT connector_plug_distinct CHECK (connector_a_id < connector_b_id),
    CONSTRAINT connector_plug_pair_unique UNIQUE (connector_a_id, connector_b_id)
);
COMMENT ON TABLE connector_plug IS 'Ресурсное соединение: пара Connector↔Connector (через Link или прямой контакт Device — рисуется слитно)';

CREATE TABLE holder_plug (
    id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    holder_a_id integer NOT NULL REFERENCES holder(id),
    holder_b_id integer NOT NULL REFERENCES holder(id),
    CONSTRAINT holder_plug_distinct CHECK (holder_a_id < holder_b_id),
    CONSTRAINT holder_plug_pair_unique UNIQUE (holder_a_id, holder_b_id)
);
COMMENT ON TABLE holder_plug IS 'Механическая привязка: пара Holder↔Holder (контакт объекта с Frame)';

-- Слой представления.

CREATE TABLE view (
    id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL UNIQUE
);
COMMENT ON TABLE view IS 'Представление модели: мнемосхема 2D, 3D и пр. Новое представление — новая запись, логическая схема не меняется';

CREATE TABLE placement (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    view_id     integer NOT NULL REFERENCES view(id),
    entity_type text NOT NULL,
    entity_id   integer NOT NULL,
    geom        jsonb NOT NULL,
    CONSTRAINT placement_unique UNIQUE (view_id, entity_type, entity_id)
);
COMMENT ON TABLE placement IS 'Размещение сущности в представлении. Универсальная ссылка (entity_type + entity_id) без FK на логические таблицы; geom — геометрия конкретного вида: 2D {x, y[, w, h][, base_y]}, трасса Link {lines: [{line_no, points: [[x, y], …]}]}, 3D — свой формат';

-- Начальные данные: пример «ТП — шкаф (автомат, счётчик, контроллер, контактор) — два светильника на опорах».
-- Шкаф — составной Device. Два варианта вывода на границу (§5 ядра):
--   ввод: граничный коннектор шкафа связан прямой парой connector_plug с коннектором автомата;
--   выход: граничный коннектор шкафа принадлежит самому шкафу, к нему идёт внутренний Link от контактора.

INSERT INTO resource (name) VALUES
    ('электричество 230В'),
    ('данные DALI'),
    ('вода');

INSERT INTO device (name, parent_device_id) VALUES
    ('Шкаф',         NULL),
    ('Светильник 1', NULL),
    ('Светильник 2', NULL),
    ('Автомат',      1),
    ('Счётчик',      1),
    ('Контроллер',   1),
    ('Контактор',    1),
    ('ТП',           NULL);

INSERT INTO frame (name, parent_device_id) VALUES
    ('Фундамент шкафа',   NULL),
    ('Опора 1',           NULL),
    ('Опора 2',           NULL),
    ('Монтажная панель',  1);

INSERT INTO link (name, resource_id, parent_device_id, parent_link_id) VALUES
    ('Кабель от ТП',                    1, NULL, NULL),
    ('Кабель освещения',                1, NULL, NULL),
    ('Секция: шкаф — стык',             1, NULL, 2),
    ('Секция: стык — светильник 1',     1, NULL, 2),
    ('Секция: стык — светильник 2',     1, NULL, 2),
    ('Автомат — счётчик',               1, 1,    NULL),
    ('Счётчик — контактор (силовая)',   1, 1,    NULL),
    ('Счётчик — контроллер (питание)',  1, 1,    NULL),
    ('Цепь управления контактором',     1, 1,    NULL),
    ('Контактор — выход шкафа',         1, 1,    NULL);

INSERT INTO connector (name, device_id, link_id, resource_id) VALUES
    ('Ввод питания шкафа',              1,    NULL, 1),
    ('Выход шкафа на освещение',        1,    NULL, 1),
    ('Выход ТП',                        8,    NULL, 1),
    ('Начало кабеля от ТП',             NULL, 1,    1),
    ('Конец кабеля от ТП',              NULL, 1,    1),
    ('Ввод автомата',                   4,    NULL, 1),
    ('Выход автомата',                  4,    NULL, 1),
    ('Ввод счётчика',                   5,    NULL, 1),
    ('Выход счётчика на контактор',     5,    NULL, 1),
    ('Выход счётчика на контроллер',    5,    NULL, 1),
    ('Ввод питания контроллера',        6,    NULL, 1),
    ('Выход управления контроллера',    6,    NULL, 1),
    ('Силовой ввод контактора',         7,    NULL, 1),
    ('Вход управления контактора',      7,    NULL, 1),
    ('Силовой выход контактора',        7,    NULL, 1),
    ('Начало: автомат — счётчик',       NULL, 6,    1),
    ('Конец: автомат — счётчик',        NULL, 6,    1),
    ('Начало: счётчик — контактор',     NULL, 7,    1),
    ('Конец: счётчик — контактор',      NULL, 7,    1),
    ('Начало: счётчик — контроллер',    NULL, 8,    1),
    ('Конец: счётчик — контроллер',     NULL, 8,    1),
    ('Начало цепи управления',          NULL, 9,    1),
    ('Конец цепи управления',           NULL, 9,    1),
    ('Начало секции от шкафа',          NULL, 3,    1),
    ('Конец секции от шкафа (стык)',    NULL, 3,    1),
    ('Начало отвода к светильнику 1',   NULL, 4,    1),
    ('Конец отвода к светильнику 1',    NULL, 4,    1),
    ('Начало отвода к светильнику 2',   NULL, 5,    1),
    ('Конец отвода к светильнику 2',    NULL, 5,    1),
    ('Ввод светильника 1',              2,    NULL, 1),
    ('Ввод светильника 2',              3,    NULL, 1),
    ('Начало: контактор — выход шкафа', NULL, 10,   1),
    ('Конец: контактор — выход шкафа',  NULL, 10,   1);

INSERT INTO holder (name, device_id, link_id, frame_id) VALUES
    ('Крепление шкафа',              1,    NULL, NULL),
    ('Крепление фундамента',         NULL, NULL, 1),
    ('Крепление светильника 1',      2,    NULL, NULL),
    ('Крепление опоры 1 (свет)',     NULL, NULL, 2),
    ('Крепление кабеля',             NULL, 4,    NULL),
    ('Крепление опоры 1 (кабель)',   NULL, NULL, 2),
    ('Крепление светильника 2',      3,    NULL, NULL),
    ('Крепление опоры 2',            NULL, NULL, 3),
    ('Крепление автомата',           4,    NULL, NULL),
    ('Крепление счётчика',           5,    NULL, NULL),
    ('Крепление контроллера',        6,    NULL, NULL),
    ('Крепление контактора',         7,    NULL, NULL),
    ('Панель: крепление автомата',   NULL, NULL, 4),
    ('Панель: крепление счётчика',   NULL, NULL, 4),
    ('Панель: крепление контроллера',NULL, NULL, 4),
    ('Панель: крепление контактора', NULL, NULL, 4);

INSERT INTO connector_plug (connector_a_id, connector_b_id) VALUES
    (3, 4),    -- ТП ↔ начало кабеля от ТП
    (1, 5),    -- ввод шкафа ↔ конец кабеля от ТП
    (1, 6),    -- ввод шкафа ↔ ввод автомата (вывод на границу)
    (7, 16),
    (8, 17),
    (9, 18),
    (13, 19),
    (10, 20),
    (11, 21),
    (12, 22),
    (14, 23),
    (15, 32),  -- силовой выход контактора ↔ начало внутреннего линка к границе
    (2, 33),   -- выход шкафа ↔ конец внутреннего линка (разъём на самом шкафу)
    (2, 24),   -- выход шкафа ↔ начало секции от шкафа
    (25, 26),  -- стык секций
    (25, 28),  -- стык секций
    (27, 30),
    (29, 31);

INSERT INTO holder_plug (holder_a_id, holder_b_id) VALUES
    (1, 2),
    (3, 4),
    (5, 6),
    (7, 8),
    (9, 13),
    (10, 14),
    (11, 15),
    (12, 16);

-- Размещение для представления «Мнемосхема 2D».

INSERT INTO view (name) VALUES ('Мнемосхема 2D');

INSERT INTO placement (view_id, entity_type, entity_id, geom) VALUES
    -- Device: точка; w, h — габарит составного Device.
    (1, 'device', 1, '{"x": 360, "y": 185, "w": 380, "h": 300}'),
    (1, 'device', 2, '{"x": 700, "y": 80}'),
    (1, 'device', 3, '{"x": 980, "y": 80}'),
    (1, 'device', 4, '{"x": 280, "y": 120}'),
    (1, 'device', 5, '{"x": 440, "y": 120}'),
    (1, 'device', 6, '{"x": 280, "y": 250}'),
    (1, 'device', 7, '{"x": 440, "y": 250}'),
    (1, 'device', 8, '{"x": 60, "y": 120}'),
    -- Frame: (x, y) — вершина, base_y — уровень основания.
    (1, 'frame', 1, '{"x": 360, "y": 335, "base_y": 400}'),
    (1, 'frame', 2, '{"x": 700, "y": 108, "base_y": 400}'),
    (1, 'frame', 3, '{"x": 980, "y": 108, "base_y": 400}'),
    (1, 'frame', 4, '{"x": 360, "y": 290, "base_y": 310}'),
    -- Link: трасса; line_no — ветвь, points — точки по порядку.
    (1, 'link', 1,  '{"lines": [{"line_no": 1, "points": [[120, 120], [170, 120]]}]}'),
    (1, 'link', 3,  '{"lines": [{"line_no": 1, "points": [[550, 250], [840, 250]]}]}'),
    (1, 'link', 4,  '{"lines": [{"line_no": 1, "points": [[840, 250], [700, 250], [700, 105]]}]}'),
    (1, 'link', 5,  '{"lines": [{"line_no": 1, "points": [[840, 250], [980, 250], [980, 105]]}]}'),
    (1, 'link', 6,  '{"lines": [{"line_no": 1, "points": [[340, 120], [380, 120]]}]}'),
    (1, 'link', 7,  '{"lines": [{"line_no": 1, "points": [[440, 145], [440, 225]]}]}'),
    (1, 'link', 8,  '{"lines": [{"line_no": 1, "points": [[400, 145], [400, 185], [280, 185], [280, 225]]}]}'),
    (1, 'link', 9,  '{"lines": [{"line_no": 1, "points": [[340, 250], [380, 250]]}]}'),
    (1, 'link', 10, '{"lines": [{"line_no": 1, "points": [[500, 250], [550, 250]]}]}'),
    -- Connector.
    (1, 'connector', 1,  '{"x": 170, "y": 120}'),
    (1, 'connector', 2,  '{"x": 550, "y": 250}'),
    (1, 'connector', 3,  '{"x": 120, "y": 120}'),
    (1, 'connector', 4,  '{"x": 120, "y": 120}'),
    (1, 'connector', 5,  '{"x": 170, "y": 120}'),
    (1, 'connector', 6,  '{"x": 220, "y": 120}'),
    (1, 'connector', 7,  '{"x": 340, "y": 120}'),
    (1, 'connector', 8,  '{"x": 380, "y": 120}'),
    (1, 'connector', 9,  '{"x": 440, "y": 145}'),
    (1, 'connector', 10, '{"x": 400, "y": 145}'),
    (1, 'connector', 11, '{"x": 280, "y": 225}'),
    (1, 'connector', 12, '{"x": 340, "y": 250}'),
    (1, 'connector', 13, '{"x": 440, "y": 225}'),
    (1, 'connector', 14, '{"x": 380, "y": 250}'),
    (1, 'connector', 15, '{"x": 500, "y": 250}'),
    (1, 'connector', 16, '{"x": 340, "y": 120}'),
    (1, 'connector', 17, '{"x": 380, "y": 120}'),
    (1, 'connector', 18, '{"x": 440, "y": 145}'),
    (1, 'connector', 19, '{"x": 440, "y": 225}'),
    (1, 'connector', 20, '{"x": 400, "y": 145}'),
    (1, 'connector', 21, '{"x": 280, "y": 225}'),
    (1, 'connector', 22, '{"x": 340, "y": 250}'),
    (1, 'connector', 23, '{"x": 380, "y": 250}'),
    (1, 'connector', 24, '{"x": 550, "y": 250}'),
    (1, 'connector', 25, '{"x": 840, "y": 250}'),
    (1, 'connector', 26, '{"x": 840, "y": 250}'),
    (1, 'connector', 27, '{"x": 700, "y": 105}'),
    (1, 'connector', 28, '{"x": 840, "y": 250}'),
    (1, 'connector', 29, '{"x": 980, "y": 105}'),
    (1, 'connector', 30, '{"x": 700, "y": 105}'),
    (1, 'connector', 31, '{"x": 980, "y": 105}'),
    (1, 'connector', 32, '{"x": 500, "y": 250}'),
    (1, 'connector', 33, '{"x": 550, "y": 250}'),
    -- Holder.
    (1, 'holder', 1,  '{"x": 360, "y": 335}'),
    (1, 'holder', 2,  '{"x": 360, "y": 335}'),
    (1, 'holder', 3,  '{"x": 740, "y": 105}'),
    (1, 'holder', 4,  '{"x": 740, "y": 105}'),
    (1, 'holder', 5,  '{"x": 700, "y": 180}'),
    (1, 'holder', 6,  '{"x": 700, "y": 180}'),
    (1, 'holder', 7,  '{"x": 1020, "y": 105}'),
    (1, 'holder', 8,  '{"x": 1020, "y": 105}'),
    (1, 'holder', 9,  '{"x": 280, "y": 145}'),
    (1, 'holder', 10, '{"x": 480, "y": 145}'),
    (1, 'holder', 11, '{"x": 280, "y": 275}'),
    (1, 'holder', 12, '{"x": 440, "y": 275}'),
    (1, 'holder', 13, '{"x": 280, "y": 145}'),
    (1, 'holder', 14, '{"x": 480, "y": 145}'),
    (1, 'holder', 15, '{"x": 280, "y": 275}'),
    (1, 'holder', 16, '{"x": 440, "y": 275}');