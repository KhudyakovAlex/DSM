const path = require('path');
const express = require('express');
const { Pool } = require('pg');

const pool = new Pool({
  host: process.env.PGHOST || 'localhost',
  port: Number(process.env.PGPORT || 5433),
  user: process.env.PGUSER || 'dsm',
  password: process.env.PGPASSWORD || 'dsm',
  database: process.env.PGDATABASE || 'dsm'
});

const app = express();
app.use(express.json({ limit: '1mb' }));

function validId(id) {
  return Number.isInteger(id) && id > 0 && id <= 2147483647;
}

function validGeometry(g, kind) {
  if (!g || typeof g !== 'object' || Array.isArray(g)) return false;
  if (kind === 'link') {
    if (Object.keys(g).some(k => k !== 'lines') || !Array.isArray(g.lines)) return false;
    const lines = new Set();
    return g.lines.every(line => {
      if (!line || !Number.isInteger(line.line_no) || line.line_no <= 0 || lines.has(line.line_no) ||
          !Array.isArray(line.points) || line.points.length < 2) return false;
      lines.add(line.line_no);
      return line.points.every(pt => Array.isArray(pt) && pt.length === 2 && pt.every(Number.isFinite));
    });
  }
  const keys = ['x', 'y'];
  if (kind === 'device') keys.push('w', 'h');
  if (kind === 'unit') keys.push('base_y');
  return Object.keys(g).every(k => keys.includes(k)) &&
    ((Number.isFinite(g.x) && Number.isFinite(g.y)) || (g.x === null && g.y === null)) &&
    ['w', 'h', 'base_y'].every(k => !(k in g) ||
      (Number.isFinite(g[k]) && (k === 'base_y' || g[k] > 0)));
}

app.put('/api/placements', async (req, res) => {
  const placements = req.body && req.body.placements;
  if (!Array.isArray(placements) || !placements.length ||
      !placements.every(p => p && ['unit', 'connector', 'holder'].includes(p.entity_type) && validId(p.entity_id)) ||
      new Set(placements.map(p => p.entity_type + ':' + p.entity_id)).size !== placements.length) {
    return res.status(400).json({ error: 'Некорректные размещения' });
  }
  let client;
  try {
    client = await pool.connect();
    await client.query('BEGIN');
    const view = await client.query("SELECT id FROM view WHERE name = 'Мнемосхема 2D'");
    if (!view.rows.length) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'Представление не найдено' });
    }
    const entities = await client.query(
      `WITH input AS (
         SELECT * FROM jsonb_to_recordset($1::jsonb) AS p(entity_type text, entity_id integer)
       ), entities AS (
         SELECT 'unit' AS entity_type, id, kind FROM unit
         UNION ALL SELECT 'connector', id, 'connector' FROM connector
         UNION ALL SELECT 'holder', id, 'holder' FROM holder
       )
       SELECT e.* FROM entities e JOIN input p ON e.entity_type = p.entity_type AND e.id = p.entity_id`,
      [JSON.stringify(placements)]
    );
    if (entities.rowCount !== placements.length) {
      await client.query('ROLLBACK');
      return res.status(400).json({ error: 'Сущность размещения не найдена' });
    }
    const kinds = new Map(entities.rows.map(e => [e.entity_type + ':' + e.id, e.kind]));
    if (!placements.every(p => validGeometry(p.geom, kinds.get(p.entity_type + ':' + p.entity_id)))) {
      await client.query('ROLLBACK');
      return res.status(400).json({ error: 'Некорректная геометрия размещения' });
    }
    await client.query(
      `INSERT INTO placement (view_id, entity_type, entity_id, geom)
       SELECT $1, p.entity_type, p.entity_id, p.geom
       FROM jsonb_to_recordset($2::jsonb) AS p(entity_type text, entity_id integer, geom jsonb)
       ON CONFLICT (view_id, entity_type, entity_id)
       DO UPDATE SET geom = placement.geom || EXCLUDED.geom`,
      [view.rows[0].id, JSON.stringify(placements)]
    );
    await client.query('COMMIT');
    res.sendStatus(204);
  } catch (err) {
    if (client) await client.query('ROLLBACK');
    res.status(500).json({ error: 'Не удалось сохранить размещения' });
  } finally {
    if (client) client.release();
  }
});

app.put('/api/entities/:type/:id', async (req, res) => {
  const { type } = req.params;
  const id = Number(req.params.id);
  const body = req.body;
  if (!['device', 'link', 'unit', 'connector', 'holder'].includes(type) || !validId(id) ||
      !body || typeof body.name !== 'string' || !body.name.trim() ||
      Object.keys(body).some(key => key !== 'name' && !(type === 'link' && key === 'resource_id')) ||
      (type === 'link' && body.resource_id !== null && !validId(body.resource_id))) {
    return res.status(400).json({ error: 'Некорректные параметры объекта' });
  }
  let client;
  try {
    client = await pool.connect();
    await client.query('BEGIN');
    let result;
    if (type === 'connector' || type === 'holder') {
      result = await client.query(`UPDATE ${type} SET name = $1 WHERE id = $2 RETURNING *`, [body.name.trim(), id]);
    } else {
      result = await client.query('UPDATE unit SET name = $1 WHERE id = $2 AND kind = $3 RETURNING *',
        [body.name.trim(), id, type]);
      if (result.rowCount && type === 'link') {
        await client.query('UPDATE link SET resource_id = $1 WHERE id = $2', [body.resource_id, id]);
        result.rows[0].resource_id = body.resource_id;
      }
    }
    if (!result.rowCount) {
      await client.query('ROLLBACK');
      return res.status(404).json({ error: 'Объект не найден' });
    }
    await client.query('COMMIT');
    res.json(result.rows[0]);
  } catch (err) {
    if (client) await client.query('ROLLBACK');
    if (err.code === '23503') return res.status(400).json({ error: 'Ресурс не найден' });
    res.status(500).json({ error: 'Не удалось сохранить параметры объекта' });
  } finally {
    if (client) client.release();
  }
});

app.get('/api/model', async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  try {
    const [resources, units, connectors, holders, connections, bindings, placements] = await Promise.all([
      pool.query('SELECT * FROM resource ORDER BY id'),
      pool.query('SELECT u.*, l.resource_id FROM unit u LEFT JOIN link l ON l.id = u.id ORDER BY u.id'),
      pool.query('SELECT * FROM connector ORDER BY id'),
      pool.query('SELECT * FROM holder ORDER BY id'),
      pool.query('SELECT * FROM connector_plug ORDER BY id'),
      pool.query('SELECT * FROM holder_plug ORDER BY id'),
      pool.query(
        `SELECT entity_type, entity_id, geom FROM placement
         WHERE view_id = (SELECT id FROM view WHERE name = 'Мнемосхема 2D')`
      )
    ]);
    const geom = new Map(placements.rows.map(p => [p.entity_type + ':' + p.entity_id, p.geom]));
    const geometry = (type, id) => geom.get(type + ':' + id) || {};
    const withXY = (type, row) => {
      const g = geometry(type, row.id);
      return { ...row, x: g.x ?? null, y: g.y ?? null };
    };
    const linkPoints = [];
    for (const u of units.rows) {
      if (u.kind !== 'link') continue;
      for (const line of geometry('unit', u.id).lines || []) {
        line.points.forEach((pt, ord) => linkPoints.push({
          link_id: u.id, line_no: line.line_no, ord: ord + 1, x: pt[0], y: pt[1]
        }));
      }
    }
    res.json({
      resources: resources.rows,
      units: units.rows.map(u => {
        const g = geometry('unit', u.id);
        return { ...withXY('unit', u), w: g.w ?? null, h: g.h ?? null, base_y: g.base_y ?? null };
      }),
      linkPoints,
      connectors: connectors.rows.map(c => withXY('connector', c)),
      holders: holders.rows.map(h => withXY('holder', h)),
      connections: connections.rows,
      bindings: bindings.rows
    });
  } catch (err) {
    res.status(500).json({ error: 'Не удалось загрузить модель' });
  }
});

app.use(express.static(path.join(__dirname, 'public'), {
  setHeaders: (res) => res.setHeader('Cache-Control', 'no-store')
}));

app.listen(8080, () => console.log('DSM web UI: http://localhost:8080'));
