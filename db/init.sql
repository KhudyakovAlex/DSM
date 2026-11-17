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
    y                double precision
);
COMMENT ON TABLE device IS 'Устройство: преобразует, накапливает, отдаёт или регулирует ресурс. Составное Device содержит внутреннюю схему (Device + Link). Размещение — точка (x, y)';

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

CREATE TABLE resource_connection (
    id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    connector_a_id integer NOT NULL REFERENCES connector(id),
    connector_b_id integer NOT NULL REFERENCES connector(id),
    CONSTRAINT resource_connection_distinct CHECK (connector_a_id < connector_b_id),
    CONSTRAINT resource_connection_pair_unique UNIQUE (connector_a_id, connector_b_id)
);
COMMENT ON TABLE resource_connection IS 'Ресурсное соединение: пара Connector↔Connector (через Link или прямой контакт Device — рисуется слитно)';

CREATE TABLE mechanical_binding (
    id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    holder_a_id integer NOT NULL REFERENCES holder(id),
    holder_b_id integer NOT NULL REFERENCES holder(id),
    CONSTRAINT mechanical_binding_distinct CHECK (holder_a_id < holder_b_id),
    CONSTRAINT mechanical_binding_pair_unique UNIQUE (holder_a_id, holder_b_id)
);
COMMENT ON TABLE mechanical_binding IS 'Механическая привязка: пара Holder↔Holder (контакт объекта с Frame)';

-- Начальные данные: пример «контроллер — кабель — два светильника на опорах».

INSERT INTO resource (name) VALUES
    ('электричество 230В'),
    ('данные DALI'),
    ('вода');

INSERT INTO device (name, x, y) VALUES
    ('Контроллер',   105, 180),
    ('Светильник 1', 480, 80),
    ('Светильник 2', 760, 80);

INSERT INTO frame (name, x, y, base_y) VALUES
    ('Монтажная панель', 105, 215, 330),
    ('Опора 1',          510, 115, 330),
    ('Опора 2',          790, 115, 330);

INSERT INTO link (name, resource_id, parent_link_id) VALUES
    ('Кабель питания',                          1, NULL),
    ('Секция: ввод — стык',                     1, 1),
    ('Секция: стык — светильник 1',             1, 1),
    ('Секция: стык — светильник 2',             1, 1);

INSERT INTO link_point (link_id, line_no, ord, x, y) VALUES
    (2, 1, 1, 170, 180),
    (2, 1, 2, 450, 180),
    (3, 1, 1, 450, 180),
    (3, 1, 2, 450, 105),
    (4, 1, 1, 450, 180),
    (4, 1, 2, 730, 180),
    (4, 1, 3, 730, 105);

INSERT INTO connector (name, device_id, link_id, resource_id, x, y) VALUES
    ('Выход контроллера',                  1, NULL, 1, 170, 180),
    ('Начало секции ввода',                NULL, 2, 1, 170, 180),
    ('Конец секции ввода',                 NULL, 2, 1, 450, 180),
    ('Начало отвода к светильнику 1',      NULL, 3, 1, 450, 180),
    ('Конец отвода к светильнику 1',       NULL, 3, 1, 450, 105),
    ('Ввод светильника 1',                 2, NULL, 1, 450, 105),
    ('Начало секции к светильнику 2',      NULL, 4, 1, 450, 180),
    ('Конец секции к светильнику 2',       NULL, 4, 1, 730, 105),
    ('Ввод светильника 2',                 3, NULL, 1, 730, 105);

INSERT INTO holder (name, device_id, link_id, frame_id, x, y) VALUES
    ('Крепление контроллера',      1, NULL, NULL, 105, 212),
    ('Крепление панели',           NULL, NULL, 1, 105, 212),
    ('Крепление светильника 1',    2, NULL, NULL, 510, 108),
    ('Крепление опоры 1 (свет)',   NULL, NULL, 2, 510, 108),
    ('Крепление кабеля',           NULL, 4, NULL, 510, 180),
    ('Крепление опоры 1 (кабель)', NULL, NULL, 2, 510, 180),
    ('Крепление светильника 2',    3, NULL, NULL, 790, 108),
    ('Крепление опоры 2',          NULL, NULL, 3, 790, 108);

INSERT INTO resource_connection (connector_a_id, connector_b_id) VALUES
    (1, 2),
    (3, 4),
    (3, 7),
    (5, 6),
    (8, 9);

INSERT INTO mechanical_binding (holder_a_id, holder_b_id) VALUES
    (1, 2),
    (3, 4),
    (5, 6),
    (7, 8);