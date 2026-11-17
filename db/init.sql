-- Схема ядра DSM (учебная, только текущие сущности).
-- Сущности: Device, Link, Frame, Resource, Connector, Holder.
-- Связи: ресурсное соединение = пара Connector↔Connector;
--        механическая привязка = пара Holder↔Holder;
--        составность через parent-ссылки.
-- Координаты — для отрисовки мнемосхемы веб-интерфейсом.

CREATE TABLE resource (
    id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL UNIQUE
);
COMMENT ON TABLE resource IS 'Профиль ресурса; один экземпляр на профиль во всей модели (вода, электричество 230В, данные DALI…)';

CREATE TABLE device (
    id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name             text NOT NULL,
    parent_device_id integer REFERENCES device(id),
    x                double precision,
    y                double precision,
    w                double precision,
    h                double precision
);
COMMENT ON TABLE device IS 'Устройство: преобразует, накапливает, отдаёт или регулирует ресурс. Составное Device содержит внутреннюю схему (Device + Link + Frame). Размещение — точка (x, y); w, h — габарит составного Device для отрисовки';

CREATE TABLE link (
    id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name             text NOT NULL,
    resource_id      integer REFERENCES resource(id),
    parent_device_id integer REFERENCES device(id),
    parent_link_id   integer REFERENCES link(id)
);
COMMENT ON TABLE link IS 'Соединение: пассивно передаёт ресурс без изменения его вида. Составной Link (кабель → жилы); может входить в состав Device. Трасса — в link_point';

CREATE TABLE link_point (
    id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    link_id integer NOT NULL REFERENCES link(id),
    line_no integer NOT NULL DEFAULT 1,
    ord     integer NOT NULL,
    x       double precision NOT NULL,
    y       double precision NOT NULL
);
COMMENT ON TABLE link_point IS 'Точка трассы Link; line_no — отдельная ветвь трассы (разветвление без разделения Link), ord — порядок точек';

CREATE TABLE frame (
    id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name             text NOT NULL,
    parent_device_id integer REFERENCES device(id),
    parent_frame_id  integer REFERENCES frame(id),
    x                double precision,
    y                double precision,
    base_y           double precision
);
COMMENT ON TABLE frame IS 'Несущая конструкция: ресурс не передаёт, коннекторов нет. (x, y) — вершина, base_y — уровень основания';

CREATE TABLE connector (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        text NOT NULL,
    device_id   integer REFERENCES device(id),
    link_id     integer REFERENCES link(id),
    resource_id integer REFERENCES resource(id),
    x           double precision,
    y           double precision,
    CONSTRAINT connector_one_owner CHECK (
        (device_id IS NOT NULL)::int + (link_id IS NOT NULL)::int = 1
    )
);
COMMENT ON TABLE connector IS 'Разъём: точка входа/выхода/промежуточного подключения ресурса. Принадлежит Device или Link';

CREATE TABLE holder (
    id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name      text NOT NULL,
    device_id integer REFERENCES device(id),
    link_id   integer REFERENCES link(id),
    frame_id  integer REFERENCES frame(id),
    x         double precision,
    y         double precision,
    CONSTRAINT holder_one_owner CHECK (
        (device_id IS NOT NULL)::int + (link_id IS NOT NULL)::int + (frame_id IS NOT NULL)::int = 1
    )
);
COMMENT ON TABLE holder IS 'Крепление: деталь или зона механического контакта. Принадлежит Device, Link или Frame';

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

-- Начальные данные: пример «ТП — шкаф (автомат, счётчик, контроллер, контактор) — два светильника на опорах».
-- Шкаф — составной Device; его граничные коннекторы (ввод/выход) связаны парами
-- connector_plug с коннекторами автомата и контактора (вывод на границу, §5 ядра).

INSERT INTO resource (name) VALUES
    ('электричество 230В'),
    ('данные DALI'),
    ('вода');

INSERT INTO device (name, parent_device_id, x, y, w, h) VALUES
    ('Шкаф',         NULL, 360, 185, 380, 300),
    ('Светильник 1', NULL, 700, 80,  NULL, NULL),
    ('Светильник 2', NULL, 980, 80,  NULL, NULL),
    ('Автомат',      1,    280, 120, NULL, NULL),
    ('Счётчик',      1,    440, 120, NULL, NULL),
    ('Контроллер',   1,    280, 250, NULL, NULL),
    ('Контактор',    1,    440, 250, NULL, NULL),
    ('ТП',           NULL, 60,  120, NULL, NULL);

INSERT INTO frame (name, parent_device_id, x, y, base_y) VALUES
    ('Фундамент шкафа',   NULL, 360, 335, 400),
    ('Опора 1',           NULL, 700, 115, 400),
    ('Опора 2',           NULL, 980, 115, 400),
    ('Монтажная панель',  1,    360, 290, 310);

INSERT INTO link (name, resource_id, parent_device_id, parent_link_id) VALUES
    ('Кабель от ТП',                    1, NULL, NULL),
    ('Кабель освещения',                1, NULL, NULL),
    ('Секция: шкаф — стык',             1, NULL, 2),
    ('Секция: стык — светильник 1',     1, NULL, 2),
    ('Секция: стык — светильник 2',     1, NULL, 2),
    ('Автомат — счётчик',               1, 1,    NULL),
    ('Счётчик — контактор (силовая)',   1, 1,    NULL),
    ('Счётчик — контроллер (питание)',  1, 1,    NULL),
    ('Цепь управления контактором',     1, 1,    NULL);

INSERT INTO link_point (link_id, line_no, ord, x, y) VALUES
    (1, 1, 1, 120, 120),
    (1, 1, 2, 170, 120),
    (3, 1, 1, 550, 250),
    (3, 1, 2, 840, 250),
    (4, 1, 1, 840, 250),
    (4, 1, 2, 700, 250),
    (4, 1, 3, 700, 105),
    (5, 1, 1, 840, 250),
    (5, 1, 2, 980, 250),
    (5, 1, 3, 980, 105),
    (6, 1, 1, 340, 120),
    (6, 1, 2, 380, 120),
    (7, 1, 1, 440, 145),
    (7, 1, 2, 440, 225),
    (8, 1, 1, 400, 145),
    (8, 1, 2, 400, 185),
    (8, 1, 3, 280, 185),
    (8, 1, 4, 280, 225),
    (9, 1, 1, 340, 250),
    (9, 1, 2, 380, 250);

INSERT INTO connector (name, device_id, link_id, resource_id, x, y) VALUES
    ('Ввод питания шкафа',              1,    NULL, 1, 170, 120),
    ('Выход шкафа на освещение',        1,    NULL, 1, 550, 250),
    ('Выход ТП',                        8,    NULL, 1, 120, 120),
    ('Начало кабеля от ТП',             NULL, 1,    1, 120, 120),
    ('Конец кабеля от ТП',              NULL, 1,    1, 170, 120),
    ('Ввод автомата',                   4,    NULL, 1, 220, 120),
    ('Выход автомата',                  4,    NULL, 1, 340, 120),
    ('Ввод счётчика',                   5,    NULL, 1, 380, 120),
    ('Выход счётчика на контактор',     5,    NULL, 1, 440, 145),
    ('Выход счётчика на контроллер',    5,    NULL, 1, 400, 145),
    ('Ввод питания контроллера',        6,    NULL, 1, 280, 225),
    ('Выход управления контроллера',    6,    NULL, 1, 340, 250),
    ('Силовой ввод контактора',         7,    NULL, 1, 440, 225),
    ('Вход управления контактора',      7,    NULL, 1, 380, 250),
    ('Силовой выход контактора',        7,    NULL, 1, 500, 250),
    ('Начало: автомат — счётчик',       NULL, 6,    1, 340, 120),
    ('Конец: автомат — счётчик',        NULL, 6,    1, 380, 120),
    ('Начало: счётчик — контактор',     NULL, 7,    1, 440, 145),
    ('Конец: счётчик — контактор',      NULL, 7,    1, 440, 225),
    ('Начало: счётчик — контроллер',    NULL, 8,    1, 400, 145),
    ('Конец: счётчик — контроллер',     NULL, 8,    1, 280, 225),
    ('Начало цепи управления',          NULL, 9,    1, 340, 250),
    ('Конец цепи управления',           NULL, 9,    1, 380, 250),
    ('Начало секции от шкафа',          NULL, 3,    1, 550, 250),
    ('Конец секции от шкафа (стык)',    NULL, 3,    1, 840, 250),
    ('Начало отвода к светильнику 1',   NULL, 4,    1, 840, 250),
    ('Конец отвода к светильнику 1',    NULL, 4,    1, 700, 105),
    ('Начало отвода к светильнику 2',   NULL, 5,    1, 840, 250),
    ('Конец отвода к светильнику 2',    NULL, 5,    1, 980, 105),
    ('Ввод светильника 1',              2,    NULL, 1, 700, 105),
    ('Ввод светильника 2',              3,    NULL, 1, 980, 105);

INSERT INTO holder (name, device_id, link_id, frame_id, x, y) VALUES
    ('Крепление шкафа',              1,    NULL, NULL, 360, 335),
    ('Крепление фундамента',         NULL, NULL, 1,    360, 335),
    ('Крепление светильника 1',      2,    NULL, NULL, 700, 108),
    ('Крепление опоры 1 (свет)',     NULL, NULL, 2,    700, 108),
    ('Крепление кабеля',             NULL, 4,    NULL, 700, 180),
    ('Крепление опоры 1 (кабель)',   NULL, NULL, 2,    700, 180),
    ('Крепление светильника 2',      3,    NULL, NULL, 980, 108),
    ('Крепление опоры 2',            NULL, NULL, 3,    980, 108),
    ('Крепление автомата',           4,    NULL, NULL, 280, 145),
    ('Крепление счётчика',           5,    NULL, NULL, 480, 145),
    ('Крепление контроллера',        6,    NULL, NULL, 280, 275),
    ('Крепление контактора',         7,    NULL, NULL, 440, 275),
    ('Панель: крепление автомата',   NULL, NULL, 4,    280, 145),
    ('Панель: крепление счётчика',   NULL, NULL, 4,    480, 145),
    ('Панель: крепление контроллера',NULL, NULL, 4,    280, 275),
    ('Панель: крепление контактора', NULL, NULL, 4,    440, 275);

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
    (2, 15),   -- выход шкафа ↔ силовой выход контактора (вывод на границу)
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