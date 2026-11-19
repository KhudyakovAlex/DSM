const assert = require('node:assert/strict');
const { test } = require('node:test');

const baseUrl = process.env.TEST_BASE_URL;
if (!baseUrl) throw new Error('Укажите TEST_BASE_URL тестового сервера с отдельной базой данных');

async function model() {
  const response = await fetch(`${baseUrl}/api/model`);
  assert.equal(response.status, 200);
  return response.json();
}

function put(path, body) {
  return fetch(`${baseUrl}${path}`, {
    method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body)
  });
}

function placement(m, row, type = 'unit') {
  let geom;
  if (row.kind === 'link') {
    const lines = new Map();
    for (const p of m.linkPoints.filter(p => p.link_id === row.id)) {
      if (!lines.has(p.line_no)) lines.set(p.line_no, []);
      lines.get(p.line_no).push(p);
    }
    geom = { lines: [...lines].map(([line_no, points]) => ({
      line_no, points: points.sort((a, b) => a.ord - b.ord).map(p => [p.x, p.y])
    })) };
  } else {
    geom = { x: row.x, y: row.y };
    for (const key of row.kind === 'device' ? ['w', 'h'] : row.kind === 'unit' ? ['base_y'] : []) {
      if (row[key] !== null && row[key] !== undefined) geom[key] = row[key];
    }
  }
  return { entity_type: type, entity_id: row.id, geom };
}

function unitOf(m, kind) {
  const row = m.units.find(u => u.kind === kind && (kind === 'link' || u.x !== null));
  assert.ok(row, `В тестовой модели нужен ${kind}`);
  return row;
}

async function save(placements) {
  const response = await put('/api/placements', { placements });
  assert.equal(response.status, 204, await response.text());
}

test('Модель использует единые ID, владельцев портов и состав', async () => {
  const m = await model();
  const units = new Map(m.units.map(u => [u.id, u]));
  assert.equal(units.size, m.units.length);
  for (const key of ['frames', 'devices', 'links']) assert.equal(key in m, false);
  for (const u of m.units) {
    assert.ok(['unit', 'device', 'link'].includes(u.kind));
    for (const key of ['parent_device_id', 'parent_link_id', 'parent_frame_id']) assert.equal(key in u, false);
    if (u.parent_id !== null) {
      const parent = units.get(u.parent_id);
      assert.ok(parent);
      assert.ok(parent.kind === 'device' || parent.kind === u.kind);
    }
  }
  for (const c of m.connectors) {
    assert.ok(['device', 'link'].includes(units.get(c.component_id)?.kind));
    for (const key of ['device_id', 'link_id', 'frame_id']) assert.equal(key in c, false);
  }
  for (const h of m.holders) {
    assert.ok(units.has(h.unit_id));
    for (const key of ['device_id', 'link_id', 'frame_id']) assert.equal(key in h, false);
  }
  for (const p of m.linkPoints) assert.equal(units.get(p.link_id)?.kind, 'link');
});

test('Раскладка всех специализаций и портов сохраняется одним запросом', async () => {
  const m = await model();
  const rows = [unitOf(m, 'unit'), unitOf(m, 'device'), unitOf(m, 'link')];
  const original = rows.map(row => placement(m, row));
  original.push(placement(m, m.connectors[0], 'connector'), placement(m, m.holders[0], 'holder'));
  const changed = structuredClone(original);
  for (const p of changed) {
    if (p.geom.lines) {
      for (const line of p.geom.lines) for (const point of line.points) point[0] += 3;
    } else p.geom.x += 3;
  }
  try {
    await save(changed);
    const after = await model();
    for (const p of changed) {
      const rows = p.entity_type === 'unit' ? after.units : after[p.entity_type + 's'];
      assert.deepEqual(placement(after, rows.find(row => row.id === p.entity_id), p.entity_type), p);
    }
  } finally {
    await save(original);
  }
});

test('Неверная геометрия и прежние типы размещений отклоняются', async () => {
  const m = await model();
  const device = unitOf(m, 'device');
  const link = unitOf(m, 'link');
  const unit = unitOf(m, 'unit');
  const invalid = [
    [],
    [{ entity_type: 'frame', entity_id: unit.id, geom: { x: 0, y: 0 } }],
    [{ entity_type: 'device', entity_id: device.id, geom: { x: 0, y: 0 } }],
    [{ entity_type: 'unit', entity_id: device.id, geom: { lines: [] } }],
    [{ entity_type: 'unit', entity_id: link.id, geom: { x: 0, y: 0 } }],
    [{ entity_type: 'unit', entity_id: unit.id, geom: { x: 0, y: 0, w: 100 } }],
    [{ entity_type: 'unit', entity_id: device.id, geom: { x: 0, y: 0, w: -1 } }],
    [{ entity_type: 'unit', entity_id: device.id, geom: { x: null, y: 0 } }],
    [{ entity_type: 'unit', entity_id: link.id, geom: { lines: [{ line_no: 1, points: [[0, 0]] }] } }],
    [{ entity_type: 'unit', entity_id: link.id, geom: { lines: [
      { line_no: 1, points: [[0, 0], [1, 1]] }, { line_no: 1, points: [[2, 2], [3, 3]] }
    ] } }],
    [placement(m, device), placement(m, device)]
  ];
  for (const placements of invalid) {
    const response = await put('/api/placements', { placements });
    assert.equal(response.status, 400, JSON.stringify(placements));
  }
});

test('Ошибка одного размещения не сохраняет остальные', async () => {
  const before = await model();
  const device = unitOf(before, 'device');
  const original = placement(before, device);
  const changed = structuredClone(original);
  changed.geom.x += 100;
  const missing = { entity_type: 'unit', entity_id: 2147483647, geom: { x: 1, y: 1 } };
  assert.equal(before.units.some(u => u.id === missing.entity_id), false);
  try {
    const response = await put('/api/placements', { placements: [changed, missing] });
    assert.equal(response.status, 400);
    const after = await model();
    assert.deepEqual(placement(after, after.units.find(u => u.id === device.id)), original);
  } finally {
    await save([original]);
  }
});

test('Имена всех видов объектов и ресурс Link редактируются', async () => {
  const m = await model();
  const targets = ['unit', 'device', 'link'].map(type => ({ type, row: unitOf(m, type) }));
  targets.push({ type: 'connector', row: m.connectors[0] }, { type: 'holder', row: m.holders[0] });
  for (const { type, row } of targets) {
    const original = { name: row.name };
    const changed = { name: `${row.name} — проверка` };
    if (type === 'link') {
      original.resource_id = row.resource_id;
      changed.resource_id = m.resources.find(r => r.id !== row.resource_id)?.id ?? null;
    }
    try {
      const response = await put(`/api/entities/${type}/${row.id}`, changed);
      assert.equal(response.status, 200);
      const result = await response.json();
      assert.equal(result.name, changed.name);
      if (type === 'link') assert.equal(result.resource_id, changed.resource_id);
      const after = await model();
      const rows = ['unit', 'device', 'link'].includes(type) ? after.units : after[type + 's'];
      assert.equal(rows.find(r => r.id === row.id).name, changed.name);
    } finally {
      const response = await put(`/api/entities/${type}/${row.id}`, original);
      assert.equal(response.status, 200);
    }
  }
});

test('Несуществующий ресурс откатывает также имя Link', async () => {
  const before = await model();
  const link = unitOf(before, 'link');
  assert.equal(before.resources.some(r => r.id === 2147483647), false);
  const response = await put(`/api/entities/link/${link.id}`, { name: 'Не сохранять', resource_id: 2147483647 });
  assert.equal(response.status, 400);
  const after = await model();
  assert.deepEqual(after.units.find(u => u.id === link.id), link);
});

test('Неверный вид объекта, пустое имя и лишние поля отклоняются', async () => {
  const m = await model();
  const device = unitOf(m, 'device');
  assert.equal((await put(`/api/entities/unit/${device.id}`, { name: 'Не сохранять' })).status, 404);
  assert.equal((await put(`/api/entities/frame/${device.id}`, { name: 'Не сохранять' })).status, 400);
  assert.equal((await put(`/api/entities/device/${device.id}`, { name: '   ' })).status, 400);
  assert.equal((await put(`/api/entities/device/${device.id}`, { name: device.name, parent_id: null })).status, 400);
  assert.equal((await put('/api/entities/device/not-a-number', { name: 'Не сохранять' })).status, 400);
});
