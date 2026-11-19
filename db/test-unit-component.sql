\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.expect_rejected(label text, statement text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    rejected boolean := false;
BEGIN
    BEGIN
        EXECUTE statement;
        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION
        WHEN check_violation OR foreign_key_violation OR raise_exception THEN
            rejected := true;
    END;
    SET CONSTRAINTS ALL DEFERRED;
    IF NOT rejected THEN
        RAISE EXCEPTION 'Ограничение не сработало: %', label;
    END IF;
    RAISE NOTICE 'Проверено: %', label;
END;
$$;

DO $$
DECLARE
    base_id integer;
    child_base_id integer;
    device_id integer;
    child_device_id integer;
    link_id integer;
    child_link_id integer;
BEGIN
    INSERT INTO unit (name, kind) VALUES ('Тест: конструкция', 'unit') RETURNING id INTO base_id;
    INSERT INTO unit (name, kind, parent_id) VALUES ('Тест: часть конструкции', 'unit', base_id) RETURNING id INTO child_base_id;
    INSERT INTO unit (name, kind) VALUES ('Тест: устройство', 'device') RETURNING id INTO device_id;
    INSERT INTO component (id) VALUES (device_id);
    INSERT INTO device (id) VALUES (device_id);
    INSERT INTO unit (name, kind, parent_id) VALUES ('Тест: внутреннее устройство', 'device', device_id) RETURNING id INTO child_device_id;
    INSERT INTO component (id) VALUES (child_device_id);
    INSERT INTO device (id) VALUES (child_device_id);
    INSERT INTO unit (name, kind, parent_id) VALUES ('Тест: внутренний линк', 'link', device_id) RETURNING id INTO link_id;
    INSERT INTO component (id) VALUES (link_id);
    INSERT INTO link (id) VALUES (link_id);
    INSERT INTO unit (name, kind, parent_id) VALUES ('Тест: секция', 'link', link_id) RETURNING id INTO child_link_id;
    INSERT INTO component (id) VALUES (child_link_id);
    INSERT INTO link (id) VALUES (child_link_id);
    INSERT INTO holder (name, unit_id) VALUES ('Крепление конструкции', base_id), ('Крепление устройства', device_id), ('Крепление линка', link_id);
    INSERT INTO connector (name, component_id) VALUES ('Разъём устройства', device_id), ('Разъём линка', link_id);
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;

    PERFORM pg_temp.expect_rejected('Device внутри Link', format('UPDATE unit SET parent_id = %s WHERE id = %s', link_id, child_device_id));
    PERFORM pg_temp.expect_rejected('базовый Unit внутри Link', format('UPDATE unit SET parent_id = %s WHERE id = %s', link_id, base_id));
    PERFORM pg_temp.expect_rejected('Device внутри базового Unit', format('UPDATE unit SET parent_id = %s WHERE id = %s', base_id, device_id));
    PERFORM pg_temp.expect_rejected('Link внутри базового Unit', format('UPDATE unit SET parent_id = %s WHERE id = %s', base_id, link_id));
    PERFORM pg_temp.expect_rejected('объект содержит сам себя', format('UPDATE unit SET parent_id = id WHERE id = %s', base_id));
    PERFORM pg_temp.expect_rejected('цикл базовых Unit', format('UPDATE unit SET parent_id = %s WHERE id = %s', child_base_id, base_id));
    PERFORM pg_temp.expect_rejected('цикл Link', format('UPDATE unit SET parent_id = %s WHERE id = %s', child_link_id, link_id));
    PERFORM pg_temp.expect_rejected('цикл Device', format('UPDATE unit SET parent_id = %s WHERE id = %s', child_device_id, device_id));
    PERFORM pg_temp.expect_rejected('две специализации одного Component', format('INSERT INTO link (id) VALUES (%s)', device_id));
    PERFORM pg_temp.expect_rejected('Component у базового Unit', format('INSERT INTO component (id) VALUES (%s)', base_id));
    PERFORM pg_temp.expect_rejected('Device без Component', format('INSERT INTO device (id) VALUES (%s)', base_id));
    PERFORM pg_temp.expect_rejected('Unit вида Device без специализации', 'INSERT INTO unit (name, kind) VALUES (''Неполный Device'', ''device'')');
    PERFORM pg_temp.expect_rejected('удаление обязательной специализации', format('DELETE FROM device WHERE id = %s', child_device_id));
    PERFORM pg_temp.expect_rejected('вид Unit не совпадает со специализацией', format('UPDATE unit SET kind = ''link'' WHERE id = %s', child_device_id));
    PERFORM pg_temp.expect_rejected('Connector у базового Unit', format('INSERT INTO connector (name, component_id) VALUES (''Неверный разъём'', %s)', base_id));
    PERFORM pg_temp.expect_rejected('Holder без владельца', 'INSERT INTO holder (name, unit_id) VALUES (''Неверное крепление'', 2147483647)');

    UPDATE unit SET parent_id = device_id WHERE id = base_id;
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    PERFORM pg_temp.expect_rejected('смена вида родителя нарушает состав', format(
        'DELETE FROM device WHERE id = %s; UPDATE unit SET kind = ''link'' WHERE id = %s; INSERT INTO link (id) VALUES (%s)',
        device_id, device_id, device_id));
    RAISE NOTICE 'Разрешённый состав и общие владельцы портов проверены';
END;
$$;

ROLLBACK;
