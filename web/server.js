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
  try {
    const [resources, devices, links, linkPoints, frames, connectors, holders, connections, bindings] =
      await Promise.all([
        pool.query('SELECT * FROM resource ORDER BY id'),
        pool.query('SELECT * FROM device ORDER BY id'),
        pool.query('SELECT * FROM link ORDER BY id'),
        pool.query('SELECT * FROM link_point ORDER BY link_id, line_no, ord'),
        pool.query('SELECT * FROM frame ORDER BY id'),
        pool.query('SELECT * FROM connector ORDER BY id'),
        pool.query('SELECT * FROM holder ORDER BY id'),
        pool.query('SELECT * FROM resource_connection ORDER BY id'),
        pool.query('SELECT * FROM mechanical_binding ORDER BY id')
      ]);
    res.json({
      resources: resources.rows,
      devices: devices.rows,
      links: links.rows,
      linkPoints: linkPoints.rows,
      frames: frames.rows,
      connectors: connectors.rows,
      holders: holders.rows,
      connections: connections.rows,
      bindings: bindings.rows
    });
  } catch (err) {
    res.status(500).json({ error: String(err.message || err) });
  }
});

app.use(express.static(path.join(__dirname, 'public')));

app.listen(8080, () => console.log('DSM web UI: http://localhost:8080'));