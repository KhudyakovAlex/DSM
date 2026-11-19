-- Перенос существующей схемы Device/Link/Frame; запускать psql -f, не вместе с init.sql.
\set ON_ERROR_STOP on
BEGIN;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

LOCK TABLE device, link, frame, resource, connector, holder,
    connector_plug, holder_plug, view, placement IN ACCESS EXCLUSIVE MODE;

CREATE TEMP TABLE old_connector ON COMMIT DROP AS TABLE connector;
CREATE TEMP TABLE old_holder ON COMMIT DROP AS TABLE holder;
CREATE TEMP TABLE old_connector_plug ON COMMIT DROP AS TABLE connector_plug;
CREATE TEMP TABLE old_holder_plug ON COMMIT DROP AS TABLE holder_plug;
CREATE TEMP TABLE old_placement ON COMMIT DROP AS TABLE placement;
CREATE TEMP TABLE old_view ON COMMIT DROP AS TABLE view;
CREATE TEMP TABLE old_resource ON COMMIT DROP AS TABLE resource;

CREATE TEMP TABLE unit_id_map (
    old_kind text NOT NULL CHECK (old_kind IN ('device', 'link', 'frame')),
    old_id integer NOT NULL,
    new_id integer NOT NULL UNIQUE,
    PRIMARY KEY (old_kind, old_id)
) ON COMMIT DROP;
INSERT INTO unit_id_map SELECT 'device', id, id FROM device;
INSERT INTO unit_id_map (old_kind, old_id, new_id)
SELECT old_kind, old_id,
       (GREATEST(COALESCE((SELECT max(id)::bigint FROM device), 0), 0)
        + row_number() OVER (ORDER BY old_kind, old_id))::integer
FROM (SELECT 'link' AS old_kind, id AS old_id FROM link
      UNION ALL SELECT 'frame', id FROM frame) src;

CREATE TEMP TABLE source_unit ON COMMIT DROP AS
SELECT 'device'::text AS old_kind, id AS old_id, name, 'device'::text AS kind,
       'device'::text AS parent_kind, parent_device_id AS parent_old_id,
       NULL::integer AS explicit_device_id
FROM device
UNION ALL
SELECT 'link', id, name, 'link',
       CASE WHEN parent_link_id IS NOT NULL THEN 'link' ELSE 'device' END,
       COALESCE(parent_link_id, parent_device_id),
       CASE WHEN parent_link_id IS NOT NULL THEN parent_device_id END
FROM link
UNION ALL
SELECT 'frame', id, name, 'unit',
       CASE WHEN parent_frame_id IS NOT NULL THEN 'frame' ELSE 'device' END,
       COALESCE(parent_frame_id, parent_device_id),
       CASE WHEN parent_frame_id IS NOT NULL THEN parent_device_id END
FROM frame;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM source_unit s LEFT JOIN unit_id_map p
          ON p.old_kind = s.parent_kind AND p.old_id = s.parent_old_id
        WHERE s.parent_old_id IS NOT NULL AND p.new_id IS NULL
    ) THEN
        RAISE EXCEPTION 'Не найден родитель исходной сущности';
    END IF;
    IF EXISTS (
        SELECT 1 FROM connector
        WHERE (device_id IS NOT NULL)::int + (link_id IS NOT NULL)::int <> 1
    ) OR EXISTS (
        SELECT 1 FROM holder
        WHERE (device_id IS NOT NULL)::int + (link_id IS NOT NULL)::int
            + (frame_id IS NOT NULL)::int <> 1
    ) THEN
        RAISE EXCEPTION 'Некорректный владелец исходного порта';
    END IF;
    IF EXISTS (
        SELECT 1 FROM placement p LEFT JOIN unit_id_map m
          ON m.old_kind = p.entity_type AND m.old_id = p.entity_id
        WHERE CASE
            WHEN p.entity_type IN ('device', 'link', 'frame') THEN m.new_id IS NULL
            WHEN p.entity_type = 'connector' THEN NOT EXISTS (SELECT 1 FROM connector c WHERE c.id = p.entity_id)
            WHEN p.entity_type = 'holder' THEN NOT EXISTS (SELECT 1 FROM holder h WHERE h.id = p.entity_id)
            ELSE true END
    ) THEN
        RAISE EXCEPTION 'Неизвестный тип или отсутствующая сущность в placement';
    END IF;
END;
$$;

ALTER TABLE device RENAME TO legacy_device;
ALTER TABLE legacy_device RENAME CONSTRAINT device_pkey TO legacy_device_pkey;
ALTER TABLE link RENAME TO legacy_link;
ALTER TABLE legacy_link RENAME CONSTRAINT link_pkey TO legacy_link_pkey;
ALTER TABLE frame RENAME TO legacy_frame;

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

INSERT INTO unit (id, name, kind) OVERRIDING SYSTEM VALUE
SELECT m.new_id, s.name, s.kind FROM source_unit s
JOIN unit_id_map m ON m.old_kind = s.old_kind AND m.old_id = s.old_id;
UPDATE unit u SET parent_id = p.new_id
FROM source_unit s JOIN unit_id_map m ON m.old_kind = s.old_kind AND m.old_id = s.old_id
JOIN unit_id_map p ON p.old_kind = s.parent_kind AND p.old_id = s.parent_old_id
WHERE u.id = m.new_id;
INSERT INTO component (id) SELECT id FROM unit WHERE kind IN ('device', 'link');
INSERT INTO device (id) SELECT id FROM unit WHERE kind = 'device';
INSERT INTO link (id, resource_id)
SELECT m.new_id, l.resource_id FROM legacy_link l
JOIN unit_id_map m ON m.old_kind = 'link' AND m.old_id = l.id;
SET CONSTRAINTS ALL IMMEDIATE;

-- Прямой Link/Unit-родитель важнее избыточного Device, но контейнеры должны совпадать.
DO $$
DECLARE
    s record;
    actual_device integer;
    expected_device integer;
BEGIN
    FOR s IN SELECT src.*, m.new_id FROM source_unit src
             JOIN unit_id_map m ON m.old_kind = src.old_kind AND m.old_id = src.old_id
             WHERE src.explicit_device_id IS NOT NULL
    LOOP
        WITH RECURSIVE ancestors AS (
            SELECT p.id, p.kind, p.parent_id FROM unit u JOIN unit p ON p.id = u.parent_id
            WHERE u.id = s.new_id
            UNION
            SELECT p.id, p.kind, p.parent_id FROM ancestors a JOIN unit p ON p.id = a.parent_id
            WHERE a.kind <> 'device'
        )
        SELECT id INTO actual_device FROM ancestors WHERE kind = 'device';
        SELECT new_id INTO expected_device FROM unit_id_map
        WHERE old_kind = 'device' AND old_id = s.explicit_device_id;
        IF expected_device IS NULL OR actual_device IS DISTINCT FROM expected_device THEN
            RAISE EXCEPTION '% %: parent_device_id % не совпадает с контейнером ancestry %',
                s.old_kind, s.old_id, s.explicit_device_id, actual_device;
        END IF;
    END LOOP;
END;
$$;

ALTER TABLE connector ADD COLUMN component_id integer REFERENCES component(id);
UPDATE connector c SET component_id = m.new_id FROM unit_id_map m
WHERE (m.old_kind = 'device' AND m.old_id = c.device_id)
   OR (m.old_kind = 'link' AND m.old_id = c.link_id);
ALTER TABLE connector ALTER COLUMN component_id SET NOT NULL;
ALTER TABLE holder ADD COLUMN unit_id integer REFERENCES unit(id);
UPDATE holder h SET unit_id = m.new_id FROM unit_id_map m
WHERE (m.old_kind = 'device' AND m.old_id = h.device_id)
   OR (m.old_kind = 'link' AND m.old_id = h.link_id)
   OR (m.old_kind = 'frame' AND m.old_id = h.frame_id);
ALTER TABLE holder ALTER COLUMN unit_id SET NOT NULL;

UPDATE placement p SET entity_type = 'unit', entity_id = m.new_id
FROM unit_id_map m WHERE m.old_kind = p.entity_type AND m.old_id = p.entity_id;
ALTER TABLE placement ADD CONSTRAINT placement_entity_type_check
    CHECK (entity_type IN ('unit', 'connector', 'holder'));

DO $$
BEGIN
    IF (SELECT count(*) FROM unit) <> (SELECT count(*) FROM source_unit)
       OR (SELECT count(*) FROM unit_id_map) <> (SELECT count(*) FROM source_unit)
       OR (SELECT count(*) FROM device) <> (SELECT count(*) FROM legacy_device)
       OR (SELECT count(*) FROM link) <> (SELECT count(*) FROM legacy_link)
       OR (SELECT count(*) FROM unit WHERE kind = 'unit') <> (SELECT count(*) FROM legacy_frame)
       OR (SELECT count(*) FROM component) <>
          (SELECT count(*) FROM legacy_device) + (SELECT count(*) FROM legacy_link) THEN
        RAISE EXCEPTION 'Число сущностей после переноса не совпадает';
    END IF;
    IF EXISTS (
        SELECT m.new_id, s.name, s.kind, p.new_id FROM source_unit s
        JOIN unit_id_map m ON m.old_kind = s.old_kind AND m.old_id = s.old_id
        LEFT JOIN unit_id_map p ON p.old_kind = s.parent_kind AND p.old_id = s.parent_old_id
        EXCEPT ALL SELECT id, name, kind, parent_id FROM unit
    ) OR EXISTS (
        SELECT m.new_id, l.resource_id FROM legacy_link l
        JOIN unit_id_map m ON m.old_kind = 'link' AND m.old_id = l.id
        EXCEPT ALL SELECT id, resource_id FROM link
    ) THEN
        RAISE EXCEPTION 'Имена, состав или ресурсы перенесены не полностью';
    END IF;
    IF (SELECT count(*) FROM connector) <> (SELECT count(*) FROM old_connector)
       OR EXISTS (
        SELECT c.id, c.name, c.resource_id, m.new_id FROM old_connector c
        LEFT JOIN unit_id_map m ON
            (m.old_kind = 'device' AND m.old_id = c.device_id)
            OR (m.old_kind = 'link' AND m.old_id = c.link_id)
        EXCEPT ALL SELECT id, name, resource_id, component_id FROM connector
    ) OR (SELECT count(*) FROM holder) <> (SELECT count(*) FROM old_holder)
       OR EXISTS (
        SELECT h.id, h.name, m.new_id FROM old_holder h
        LEFT JOIN unit_id_map m ON
            (m.old_kind = 'device' AND m.old_id = h.device_id)
            OR (m.old_kind = 'link' AND m.old_id = h.link_id)
            OR (m.old_kind = 'frame' AND m.old_id = h.frame_id)
        EXCEPT ALL SELECT id, name, unit_id FROM holder
    ) THEN
        RAISE EXCEPTION 'Порты или владельцы перенесены не полностью';
    END IF;
    IF (SELECT count(*) FROM placement) <> (SELECT count(*) FROM old_placement)
       OR EXISTS (
        SELECT p.id, p.view_id,
               CASE WHEN m.new_id IS NOT NULL THEN 'unit' ELSE p.entity_type END,
               COALESCE(m.new_id, p.entity_id), p.geom
        FROM old_placement p LEFT JOIN unit_id_map m
          ON m.old_kind = p.entity_type AND m.old_id = p.entity_id
        EXCEPT ALL SELECT id, view_id, entity_type, entity_id, geom FROM placement
    ) THEN
        RAISE EXCEPTION 'Размещения или геометрия изменились при переносе';
    END IF;
    IF EXISTS ((TABLE old_connector_plug EXCEPT ALL TABLE connector_plug)
               UNION ALL (TABLE connector_plug EXCEPT ALL TABLE old_connector_plug))
       OR EXISTS ((TABLE old_holder_plug EXCEPT ALL TABLE holder_plug)
                  UNION ALL (TABLE holder_plug EXCEPT ALL TABLE old_holder_plug))
       OR EXISTS ((TABLE old_view EXCEPT ALL TABLE view)
                  UNION ALL (TABLE view EXCEPT ALL TABLE old_view))
       OR EXISTS ((TABLE old_resource EXCEPT ALL TABLE resource)
                  UNION ALL (TABLE resource EXCEPT ALL TABLE old_resource)) THEN
        RAISE EXCEPTION 'Пары портов, представления или ресурсы изменились при переносе';
    END IF;
END;
$$;

-- Устаревшие столбцы и таблицы удаляются только после проверки переноса, без CASCADE.
ALTER TABLE connector DROP CONSTRAINT connector_one_owner,
    DROP COLUMN device_id, DROP COLUMN link_id;
ALTER TABLE holder DROP CONSTRAINT holder_one_owner,
    DROP COLUMN device_id, DROP COLUMN link_id, DROP COLUMN frame_id;
DROP TABLE legacy_link;
DROP TABLE legacy_frame;
DROP TABLE legacy_device;

COMMENT ON TABLE resource IS 'Профиль ресурса; один экземпляр на профиль во всей модели';
COMMENT ON TABLE connector IS 'Разъём: точка подключения ресурса. Ровно один владелец Component. Позиция — в placement';
COMMENT ON TABLE holder IS 'Крепление: деталь или зона механического контакта. Ровно один владелец Unit. Позиция — в placement';
COMMENT ON TABLE connector_plug IS 'Ресурсное соединение: пара Connector↔Connector';
COMMENT ON TABLE holder_plug IS 'Механическая привязка: пара Holder↔Holder любых Unit';
COMMENT ON TABLE view IS 'Представление модели: мнемосхема 2D, 3D и пр.';
COMMENT ON TABLE placement IS 'Универсальная ссылка без FK: unit для всех Unit/Device/Link, connector, holder. geom: Device {x,y,w,h}, базовый Unit {x,y,base_y}, Link {lines:[{line_no,points}]}. Device — относительно родительского Device, базовый Unit — непосредственного родителя, Link — ближайшего Device-предка (Link не задаёт начало координат); порты Link — в координатах трассы, остальные порты — относительно владельца';

SELECT setval(pg_get_serial_sequence('unit', 'id'),
              GREATEST(COALESCE(max(id), 0), 1), COALESCE(max(id) >= 1, false)) FROM unit;
COMMIT;
