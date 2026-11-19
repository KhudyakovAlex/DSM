-- Схема ядра DSM: логика без координат; размещение — отдельный слой.
\set ON_ERROR_STOP on
BEGIN;

CREATE TABLE resource (
    id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL UNIQUE
);
COMMENT ON TABLE resource IS 'Профиль ресурса; один экземпляр на профиль во всей модели';

CREATE TABLE unit (
    id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name      text NOT NULL,
    kind      text NOT NULL CHECK (kind IN ('unit', 'device', 'link')),
    parent_id integer REFERENCES unit(id),
    CONSTRAINT unit_not_self_parent CHECK (parent_id <> id)
);
CREATE INDEX unit_parent_idx ON unit(parent_id);
COMMENT ON TABLE unit IS 'Материальная сущность. kind — конкретная специализация; базовый Unit не имеет Component. Единый состав через parent_id';

CREATE TABLE component (
    id integer PRIMARY KEY REFERENCES unit(id)
);
COMMENT ON TABLE component IS 'Общий уровень Device и Link с тем же идентификатором Unit; владелец Connector';

CREATE TABLE device (
    id integer PRIMARY KEY REFERENCES component(id)
);
COMMENT ON TABLE device IS 'Устройство: преобразует, накапливает, отдаёт или регулирует ресурс';

CREATE TABLE link (
    id          integer PRIMARY KEY REFERENCES component(id),
    resource_id integer REFERENCES resource(id)
);
COMMENT ON TABLE link IS 'Соединение: пассивно передаёт ресурс. Составной Link содержит только Link; минимальное число коннекторов не ограничено';

-- Общая блокировка сериализует изменения графа. При старом снимке проверка небезопасна.
CREATE FUNCTION lock_unit_graph() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'TRUNCATE' THEN
        RAISE EXCEPTION 'TRUNCATE нарушает проверку специализаций; используйте DELETE'
            USING ERRCODE = '23514';
    END IF;
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'Изменение Unit/Component/Device/Link требует READ COMMITTED'
            USING ERRCODE = '0A000';
    END IF;
    PERFORM pg_advisory_xact_lock(1146309937, 1);
    RETURN NULL;
END;
$$;

CREATE TRIGGER unit_graph_lock BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON unit
    FOR EACH STATEMENT EXECUTE FUNCTION lock_unit_graph();
CREATE TRIGGER component_graph_lock BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON component
    FOR EACH STATEMENT EXECUTE FUNCTION lock_unit_graph();
CREATE TRIGGER device_graph_lock BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON device
    FOR EACH STATEMENT EXECUTE FUNCTION lock_unit_graph();
CREATE TRIGGER link_graph_lock BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON link
    FOR EACH STATEMENT EXECUTE FUNCTION lock_unit_graph();

CREATE FUNCTION check_unit(p_id integer) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    u unit%ROWTYPE;
    has_component boolean;
    has_device boolean;
    has_link boolean;
BEGIN
    SELECT * INTO u FROM unit WHERE id = p_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;
    SELECT EXISTS (SELECT 1 FROM component WHERE id = p_id),
           EXISTS (SELECT 1 FROM device WHERE id = p_id),
           EXISTS (SELECT 1 FROM link WHERE id = p_id)
      INTO has_component, has_device, has_link;
    IF has_component <> (u.kind IN ('device', 'link'))
       OR has_device <> (u.kind = 'device') OR has_link <> (u.kind = 'link') THEN
        RAISE EXCEPTION 'Unit %: kind % не соответствует таблицам специализации', p_id, u.kind
            USING ERRCODE = '23514';
    END IF;
    -- Проверяются обе стороны ребра, в том числе при смене kind родителя.
    IF EXISTS (
        SELECT 1 FROM unit child JOIN unit parent ON parent.id = child.parent_id
        WHERE (child.id = p_id OR parent.id = p_id)
          AND NOT (parent.kind = 'device' OR parent.kind = child.kind)
    ) THEN
        RAISE EXCEPTION 'Unit %: недопустимый состав', p_id USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        WITH RECURSIVE ancestors(id) AS (
            SELECT parent_id FROM unit WHERE id = p_id AND parent_id IS NOT NULL
            UNION
            SELECT parent.parent_id FROM unit parent JOIN ancestors a ON parent.id = a.id
            WHERE parent.parent_id IS NOT NULL
        )
        SELECT 1 FROM ancestors WHERE id = p_id
    ) THEN
        RAISE EXCEPTION 'Unit %: цикл в составе', p_id USING ERRCODE = '23514';
    END IF;
END;
$$;

CREATE FUNCTION check_unit_specialization() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        PERFORM check_unit(OLD.id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        PERFORM check_unit(NEW.id);
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER unit_specialization_check AFTER INSERT OR UPDATE OR DELETE ON unit
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_unit_specialization();
CREATE CONSTRAINT TRIGGER component_specialization_check AFTER INSERT OR UPDATE OR DELETE ON component
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_unit_specialization();
CREATE CONSTRAINT TRIGGER device_specialization_check AFTER INSERT OR UPDATE OR DELETE ON device
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_unit_specialization();
CREATE CONSTRAINT TRIGGER link_specialization_check AFTER INSERT OR UPDATE OR DELETE ON link
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_unit_specialization();

CREATE TABLE connector (
    id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         text NOT NULL,
    component_id integer NOT NULL REFERENCES component(id),
    resource_id  integer REFERENCES resource(id)
);
COMMENT ON TABLE connector IS 'Разъём: точка подключения ресурса. Ровно один владелец Component. Позиция — в placement';

CREATE TABLE holder (
    id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name    text NOT NULL,
    unit_id integer NOT NULL REFERENCES unit(id)
);
COMMENT ON TABLE holder IS 'Крепление: деталь или зона механического контакта. Ровно один владелец Unit. Позиция — в placement';

CREATE TABLE connector_plug (
    id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    connector_a_id integer NOT NULL REFERENCES connector(id),
    connector_b_id integer NOT NULL REFERENCES connector(id),
    CONSTRAINT connector_plug_distinct CHECK (connector_a_id < connector_b_id),
    CONSTRAINT connector_plug_pair_unique UNIQUE (connector_a_id, connector_b_id)
);
COMMENT ON TABLE connector_plug IS 'Ресурсное соединение: пара Connector↔Connector';

CREATE TABLE holder_plug (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    holder_a_id integer NOT NULL REFERENCES holder(id),
    holder_b_id integer NOT NULL REFERENCES holder(id),
    CONSTRAINT holder_plug_distinct CHECK (holder_a_id < holder_b_id),
    CONSTRAINT holder_plug_pair_unique UNIQUE (holder_a_id, holder_b_id)
);
COMMENT ON TABLE holder_plug IS 'Механическая привязка: пара Holder↔Holder любых Unit';

CREATE TABLE view (
    id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL UNIQUE
);
COMMENT ON TABLE view IS 'Представление модели: мнемосхема 2D, 3D и пр.';

CREATE TABLE placement (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    view_id     integer NOT NULL REFERENCES view(id),
    entity_type text NOT NULL CHECK (entity_type IN ('unit', 'connector', 'holder')),
    entity_id   integer NOT NULL,
    geom        jsonb NOT NULL,
    CONSTRAINT placement_unique UNIQUE (view_id, entity_type, entity_id)
);
COMMENT ON TABLE placement IS 'Универсальная ссылка без FK: unit для всех Unit/Device/Link, connector, holder. geom: Device {x,y,w,h}, базовый Unit {x,y,base_y}, Link {lines:[{line_no,points}]}. Device — относительно родительского Device, базовый Unit — непосредственного родителя, Link — ближайшего Device-предка (Link не задаёт начало координат); порты Link — в координатах трассы, остальные порты — относительно владельца';

-- Пример «ТП — шкаф (автомат, счётчик, контроллер, контактор) — два светильника на опорах».
INSERT INTO resource (name) VALUES ('электричество 230В'), ('данные DALI'), ('вода');

INSERT INTO unit (name, kind, parent_id) VALUES
    ('Шкаф', 'device', NULL),
    ('Светильник 1', 'device', NULL),
    ('Светильник 2', 'device', NULL),
    ('Автомат', 'device', 1),
    ('Счётчик', 'device', 1),
    ('Контроллер', 'device', 1),
    ('Контактор', 'device', 1),
    ('ТП', 'device', NULL),
    ('Фундамент шкафа', 'unit', NULL),
    ('Опора 1', 'unit', NULL),
    ('Опора 2', 'unit', NULL),
    ('Монтажная панель', 'unit', 1),
    ('Кабель от ТП', 'link', NULL),
    ('Кабель освещения', 'link', NULL),
    ('Секция: шкаф — стык', 'link', 14),
    ('Секция: стык — светильник 1', 'link', 14),
    ('Секция: стык — светильник 2', 'link', 14),
    ('Автомат — счётчик', 'link', 1),
    ('Счётчик — контактор (силовая)', 'link', 1),
    ('Счётчик — контроллер (питание)', 'link', 1),
    ('Цепь управления контактором', 'link', 1),
    ('Контактор — выход шкафа', 'link', 1);
INSERT INTO component (id) SELECT id FROM unit WHERE kind IN ('device', 'link');
INSERT INTO device (id) SELECT id FROM unit WHERE kind = 'device';
INSERT INTO link (id, resource_id) SELECT id, 1 FROM unit WHERE kind = 'link';

INSERT INTO connector (name, component_id, resource_id) VALUES
    ('Ввод питания шкафа', 1, 1),
    ('Выход шкафа на освещение', 1, 1),
    ('Выход ТП', 8, 1),
    ('Начало кабеля от ТП', 13, 1),
    ('Конец кабеля от ТП', 13, 1),
    ('Ввод автомата', 4, 1),
    ('Выход автомата', 4, 1),
    ('Ввод счётчика', 5, 1),
    ('Выход счётчика на контактор', 5, 1),
    ('Выход счётчика на контроллер', 5, 1),
    ('Ввод питания контроллера', 6, 1),
    ('Выход управления контроллера', 6, 1),
    ('Силовой ввод контактора', 7, 1),
    ('Вход управления контактора', 7, 1),
    ('Силовой выход контактора', 7, 1),
    ('Начало: автомат — счётчик', 18, 1),
    ('Конец: автомат — счётчик', 18, 1),
    ('Начало: счётчик — контактор', 19, 1),
    ('Конец: счётчик — контактор', 19, 1),
    ('Начало: счётчик — контроллер', 20, 1),
    ('Конец: счётчик — контроллер', 20, 1),
    ('Начало цепи управления', 21, 1),
    ('Конец цепи управления', 21, 1),
    ('Начало секции от шкафа', 15, 1),
    ('Конец секции от шкафа (стык)', 15, 1),
    ('Начало отвода к светильнику 1', 16, 1),
    ('Конец отвода к светильнику 1', 16, 1),
    ('Начало отвода к светильнику 2', 17, 1),
    ('Конец отвода к светильнику 2', 17, 1),
    ('Ввод светильника 1', 2, 1),
    ('Ввод светильника 2', 3, 1),
    ('Начало: контактор — выход шкафа', 22, 1),
    ('Конец: контактор — выход шкафа', 22, 1);

INSERT INTO holder (name, unit_id) VALUES
    ('Крепление шкафа', 1),
    ('Крепление фундамента', 9),
    ('Крепление светильника 1', 2),
    ('Крепление опоры 1 (свет)', 10),
    ('Крепление кабеля', 16),
    ('Крепление опоры 1 (кабель)', 10),
    ('Крепление светильника 2', 3),
    ('Крепление опоры 2', 11),
    ('Крепление автомата', 4),
    ('Крепление счётчика', 5),
    ('Крепление контроллера', 6),
    ('Крепление контактора', 7),
    ('Панель: крепление автомата', 12),
    ('Панель: крепление счётчика', 12),
    ('Панель: крепление контроллера', 12),
    ('Панель: крепление контактора', 12);

INSERT INTO connector_plug (connector_a_id, connector_b_id) VALUES
    (3, 4), (1, 5), (1, 6), (7, 16), (8, 17), (9, 18), (13, 19), (10, 20),
    (11, 21), (12, 22), (14, 23), (15, 32), (2, 33), (2, 24), (25, 26),
    (25, 28), (27, 30), (29, 31);
INSERT INTO holder_plug (holder_a_id, holder_b_id) VALUES
    (1, 2), (3, 4), (5, 6), (7, 8), (9, 13), (10, 14), (11, 15), (12, 16);

INSERT INTO view (name) VALUES ('Мнемосхема 2D');
INSERT INTO placement (view_id, entity_type, entity_id, geom) VALUES
    -- Device.
    (1, 'unit', 1, '{"x": 360, "y": 185, "w": 380, "h": 300}'),
    (1, 'unit', 2, '{"x": 700, "y": 80}'),
    (1, 'unit', 3, '{"x": 980, "y": 80}'),
    (1, 'unit', 4, '{"x": 280, "y": 120}'),
    (1, 'unit', 5, '{"x": 440, "y": 120}'),
    (1, 'unit', 6, '{"x": 280, "y": 250}'),
    (1, 'unit', 7, '{"x": 440, "y": 250}'),
    (1, 'unit', 8, '{"x": 60, "y": 120}'),
    -- Базовый Unit.
    (1, 'unit', 9, '{"x": 360, "y": 335, "base_y": 400}'),
    (1, 'unit', 10, '{"x": 700, "y": 108, "base_y": 400}'),
    (1, 'unit', 11, '{"x": 980, "y": 108, "base_y": 400}'),
    (1, 'unit', 12, '{"x": 360, "y": 290, "base_y": 310}'),
    -- Link: трасса; составной кабель не имеет собственных портов и трассы.
    (1, 'unit', 13, '{"lines": [{"line_no": 1, "points": [[120, 120], [170, 120]]}]}'),
    (1, 'unit', 15, '{"lines": [{"line_no": 1, "points": [[550, 250], [840, 250]]}]}'),
    (1, 'unit', 16, '{"lines": [{"line_no": 1, "points": [[840, 250], [700, 250], [700, 105]]}]}'),
    (1, 'unit', 17, '{"lines": [{"line_no": 1, "points": [[840, 250], [980, 250], [980, 105]]}]}'),
    (1, 'unit', 18, '{"lines": [{"line_no": 1, "points": [[340, 120], [380, 120]]}]}'),
    (1, 'unit', 19, '{"lines": [{"line_no": 1, "points": [[440, 145], [440, 225]]}]}'),
    (1, 'unit', 20, '{"lines": [{"line_no": 1, "points": [[400, 145], [400, 185], [280, 185], [280, 225]]}]}'),
    (1, 'unit', 21, '{"lines": [{"line_no": 1, "points": [[340, 250], [380, 250]]}]}'),
    (1, 'unit', 22, '{"lines": [{"line_no": 1, "points": [[500, 250], [550, 250]]}]}'),
    -- Connector.
    (1, 'connector', 1, '{"x": 170, "y": 120}'),
    (1, 'connector', 2, '{"x": 550, "y": 250}'),
    (1, 'connector', 3, '{"x": 120, "y": 120}'),
    (1, 'connector', 4, '{"x": 120, "y": 120}'),
    (1, 'connector', 5, '{"x": 170, "y": 120}'),
    (1, 'connector', 6, '{"x": 220, "y": 120}'),
    (1, 'connector', 7, '{"x": 340, "y": 120}'),
    (1, 'connector', 8, '{"x": 380, "y": 120}'),
    (1, 'connector', 9, '{"x": 440, "y": 145}'),
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
    (1, 'holder', 1, '{"x": 360, "y": 335}'),
    (1, 'holder', 2, '{"x": 360, "y": 335}'),
    (1, 'holder', 3, '{"x": 740, "y": 105}'),
    (1, 'holder', 4, '{"x": 740, "y": 105}'),
    (1, 'holder', 5, '{"x": 700, "y": 180}'),
    (1, 'holder', 6, '{"x": 700, "y": 180}'),
    (1, 'holder', 7, '{"x": 1020, "y": 105}'),
    (1, 'holder', 8, '{"x": 1020, "y": 105}'),
    (1, 'holder', 9, '{"x": 280, "y": 145}'),
    (1, 'holder', 10, '{"x": 480, "y": 145}'),
    (1, 'holder', 11, '{"x": 280, "y": 275}'),
    (1, 'holder', 12, '{"x": 440, "y": 275}'),
    (1, 'holder', 13, '{"x": 280, "y": 145}'),
    (1, 'holder', 14, '{"x": 480, "y": 145}'),
    (1, 'holder', 15, '{"x": 280, "y": 275}'),
    (1, 'holder', 16, '{"x": 440, "y": 275}');

-- Только seed: перевод исходного абсолютного размещения в прежние локальные координаты.
WITH RECURSIVE link_owner AS (
    SELECT u.id, u.parent_id AS device_id FROM unit u
    LEFT JOIN unit p ON p.id = u.parent_id
    WHERE u.kind = 'link' AND (p.id IS NULL OR p.kind = 'device')
    UNION ALL
    SELECT u.id, p.device_id FROM unit u JOIN link_owner p ON p.id = u.parent_id
    WHERE u.kind = 'link'
), owners AS (
    SELECT 'unit' AS entity_type, u.id AS entity_id,
           CASE WHEN u.kind = 'link' THEN l.device_id ELSE u.parent_id END AS origin_id
    FROM unit u LEFT JOIN link_owner l ON l.id = u.id
    UNION ALL
    SELECT 'connector', c.id, CASE WHEN u.kind = 'link' THEN l.device_id ELSE u.id END
    FROM connector c JOIN unit u ON u.id = c.component_id LEFT JOIN link_owner l ON l.id = u.id
    UNION ALL
    SELECT 'holder', h.id, CASE WHEN u.kind = 'link' THEN l.device_id ELSE u.id END
    FROM holder h JOIN unit u ON u.id = h.unit_id LEFT JOIN link_owner l ON l.id = u.id
), offsets AS (
    SELECT p.id, (origin.geom->>'x')::numeric AS x, (origin.geom->>'y')::numeric AS y
    FROM placement p JOIN owners o ON o.entity_type = p.entity_type AND o.entity_id = p.entity_id
    JOIN placement origin ON origin.view_id = p.view_id
        AND origin.entity_type = 'unit' AND origin.entity_id = o.origin_id
    JOIN view v ON v.id = p.view_id AND v.name = 'Мнемосхема 2D'
)
UPDATE placement p SET geom = CASE WHEN p.geom ? 'lines' THEN
    jsonb_set(p.geom, '{lines}', (
        SELECT jsonb_agg(jsonb_set(line, '{points}', (
            SELECT jsonb_agg(jsonb_build_array((point->>0)::numeric - o.x, (point->>1)::numeric - o.y) ORDER BY point_ord)
            FROM jsonb_array_elements(line->'points') WITH ORDINALITY AS pts(point, point_ord)
        )) ORDER BY line_ord)
        FROM jsonb_array_elements(p.geom->'lines') WITH ORDINALITY AS lines(line, line_ord)
    ))
    ELSE p.geom || jsonb_build_object('x', (p.geom->>'x')::numeric - o.x, 'y', (p.geom->>'y')::numeric - o.y)
        || CASE WHEN p.geom ? 'base_y' THEN jsonb_build_object('base_y', (p.geom->>'base_y')::numeric - o.y) ELSE '{}'::jsonb END
    END
FROM offsets o WHERE p.id = o.id;

COMMIT;
