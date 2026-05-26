const express = require('express');

const PORT = parseInt(process.env.PORT || '8080', 10);
const LOG_LEVEL = (process.env.LOG_LEVEL || 'info').toLowerCase();

const levels = { debug: 0, info: 1, warn: 2, error: 3 };

function log(level, msg, extra = {}) {
  if ((levels[level] ?? 1) >= (levels[LOG_LEVEL] ?? 1)) {
    process.stdout.write(
      JSON.stringify({ t: new Date().toISOString(), level, msg, ...extra }) + '\n',
    );
  }
}

const students = [
  { id: 1, nom: 'Adèle Ferrand', promo: 'M2 IW' },
  { id: 2, nom: 'Bachir Saadi', promo: 'M2 IW' },
  { id: 3, nom: 'Claire Dupond', promo: 'M2 IW' },
];

const app = express();

app.get('/healthz', (_, res) => res.json({ ok: true, service: 'annuaire', preview: 'demo-prof' }));
app.get('/students', (_, res) => res.json(students));
app.get('/students/:id', (req, res) => {
  const found = students.find((s) => s.id === parseInt(req.params.id, 10));
  if (!found) return res.status(404).json({ error: 'not found' });
  return res.json(found);
});

const server = app.listen(PORT, () => log('info', `annuaire up on :${PORT}`));
log('debug', `LOG_LEVEL=${LOG_LEVEL}`);

// Graceful shutdown — Kubernetes envoie SIGTERM, on ferme proprement
process.on('SIGTERM', () => {
  log('info', 'SIGTERM received, shutting down');
  server.close(() => process.exit(0));
});
