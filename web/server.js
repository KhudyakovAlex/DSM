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

app.get('/api/model', async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  try {
    const [resources, devices, links, frames, connectors, holders, connections, bindings, placements] =
      await Promise.all([
        pool.query('SELECT * FROM resource ORDER BY id'),
        pool.query('SELECT * FROM device ORDER BY id'),
        pool.query('SELECT * FROM link ORDER BY id'),
        pool.query('SELECT * FROM frame ORDER BY id'),
        pool.query('SELECT * FROM connector ORDER BY id'),
        pool.query('SELECT * FROM holder ORDER BY id'),
        pool.query('SELECT * FROM connector_plug ORDER BY id'),
        pool.query('SELECT * FROM holder_plug ORDER BY id'),
        pool.query(
          `SELECT entity_type, entity_id, geom FROM placement
           WHERE view_id = (SELECT id FROM view WHERE name = 'Мнемосхема 2D')`
        )
      ]);

    // Геометрия представления сливается с логическими сущностями;
    // формат ответа прежний, клиент не знает о слое размещения.
    const geom = {};
    for (const p of placements.rows) {
      geom[p.entity_type + ':' + p.entity_id] = p.geom;
    }
    const g = (type, id) => geom[type + ':' + id] || {};
    const withXY = (type, row) => Object.assign({}, row, { x: g(type, row.id).x ?? null, y: g(type, row.id).y ?? null });

    const linkPoints = [];
    for (const l of links.rows) {
      const lines = g('link', l.id).lines || [];
      for (const line of lines) {
        line.points.forEach(function (pt, i) {
          linkPoints.push({ link_id: l.id, line_no: line.line_no, ord: i + 1, x: pt[0], y: pt[1] });
        });
      }
    }

    res.json({
      resources: resources.rows,
      devices: devices.rows.map(d => Object.assign(withXY('device', d), { w: g('device', d.id).w ?? null, h: g('device', d.id).h ?? null })),
      links: links.rows,
      linkPoints: linkPoints,
      frames: frames.rows.map(f => Object.assign(withXY('frame', f), { base_y: g('frame', f.id).base_y ?? null })),
      connectors: connectors.rows.map(c => withXY('connector', c)),
      holders: holders.rows.map(h => withXY('holder', h)),
      connections: connections.rows,
      bindings: bindings.rows
    });
  } catch (err) {
    res.status(500).json({ error: String(err.message || err) });
  }
});

app.use(express.static(path.join(__dirname, 'public'), {
  setHeaders: (res) => res.setHeader('Cache-Control', 'no-store')
}));

app.listen(8080, () => console.log('DSM web UI: http://localhost:8080'));