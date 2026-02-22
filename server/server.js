const https = require('https');
const fs = require('fs');
const path = require('path');
const WebSocket = require('ws');
const forge = require('node-forge');

const PORT = process.env.PORT || 8080;

// ══════════  GENERATE SELF-SIGNED CERT  ══════════

console.log('Generating self-signed certificate...');

const pki = forge.pki;
const keys = pki.rsa.generateKeyPair(2048);
const cert = pki.createCertificate();

cert.publicKey = keys.publicKey;
cert.serialNumber = '01';
cert.validity.notBefore = new Date();
cert.validity.notAfter = new Date();
cert.validity.notAfter.setFullYear(cert.validity.notBefore.getFullYear() + 1);

const attrs = [
  { name: 'commonName', value: 'BloodyBrawler' },
  { name: 'organizationName', value: 'BloodyBrawler Dev' },
];
cert.setSubject(attrs);
cert.setIssuer(attrs);

// Add extensions that Chrome requires
cert.setExtensions([
  { name: 'basicConstraints', cA: false },
  { name: 'keyUsage', digitalSignature: true, keyEncipherment: true },
  { name: 'extKeyUsage', serverAuth: true },
  {
    name: 'subjectAltName',
    altNames: [
      { type: 2, value: 'localhost' },
      { type: 7, ip: '127.0.0.1' },
      { type: 7, ip: '172.20.196.130' },
    ],
  },
]);

cert.sign(keys.privateKey, forge.md.sha256.create());

const pems = {
  private: pki.privateKeyToPem(keys.privateKey),
  cert: pki.certificateToPem(cert),
};

console.log('Certificate generated successfully!');

// ══════════  STATIC FILE SERVER (HTTPS)  ══════════
// Serves the Godot web export so phones can load the game via browser

const STATIC_DIR = path.join(__dirname, '..', 'web_export');

const MIME_TYPES = {
  '.html': 'text/html',
  '.js': 'application/javascript',
  '.wasm': 'application/wasm',
  '.pck': 'application/octet-stream',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.css': 'text/css',
  '.json': 'application/json',
  '.webp': 'image/webp',
};

const httpsServer = https.createServer(
  { key: pems.private, cert: pems.cert },
  (req, res) => {
    // CORS headers for cross-origin access
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
    res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');

    let filePath = req.url === '/' ? '/index.html' : req.url;
    filePath = path.join(STATIC_DIR, filePath);

    const ext = path.extname(filePath).toLowerCase();
    const contentType = MIME_TYPES[ext] || 'application/octet-stream';

    fs.readFile(filePath, (err, data) => {
      if (err) {
        if (err.code === 'ENOENT') {
          res.writeHead(404);
          res.end('File not found: ' + req.url);
        } else {
          res.writeHead(500);
          res.end('Server error');
        }
        return;
      }
      res.writeHead(200, { 'Content-Type': contentType });
      res.end(data);
    });
  }
);

// ══════════  WEBSOCKET RELAY SERVER  ══════════

const wss = new WebSocket.Server({ server: httpsServer });

// Room storage: { code: { host: ws, client: ws, started: bool } }
const rooms = {};

function generateCode() {
  let code;
  do {
    code = String(Math.floor(100000 + Math.random() * 900000));
  } while (rooms[code]);
  return code;
}

function send(ws, data) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(data));
  }
}

function getOther(room, ws) {
  if (room.host === ws) return room.client;
  if (room.client === ws) return room.host;
  return null;
}

function getPlayerCount(room) {
  let count = 0;
  if (room.host) count++;
  if (room.client) count++;
  return count;
}

function removeFromRoom(ws) {
  for (const [code, room] of Object.entries(rooms)) {
    if (room.host === ws || room.client === ws) {
      const other = getOther(room, ws);
      if (room.host === ws) room.host = null;
      if (room.client === ws) room.client = null;

      const count = getPlayerCount(room);
      if (count === 0) {
        delete rooms[code];
        console.log(`Room ${code} destroyed (empty)`);
      } else if (other) {
        send(other, { type: 'player_disconnected', count });
      }
      ws._roomCode = null;
      return;
    }
  }
}

wss.on('connection', (ws) => {
  console.log('Client connected');

  ws.on('message', (raw) => {
    let data;
    try {
      data = JSON.parse(raw);
    } catch (e) {
      send(ws, { type: 'error', message: 'Invalid JSON' });
      return;
    }

    const { type } = data;

    switch (type) {
      case 'create_room': {
        removeFromRoom(ws);
        const code = generateCode();
        rooms[code] = { host: ws, client: null, started: false };
        ws._roomCode = code;
        send(ws, { type: 'room_created', code });
        console.log(`Room ${code} created`);
        break;
      }

      case 'join_room': {
        const code = data.code;
        const room = rooms[code];
        if (!room) {
          send(ws, { type: 'error', message: 'Room not found' });
          return;
        }
        if (room.client) {
          send(ws, { type: 'error', message: 'Room is full' });
          return;
        }
        removeFromRoom(ws);
        room.client = ws;
        ws._roomCode = code;
        send(ws, { type: 'room_joined', code });
        send(room.host, { type: 'player_connected', count: 2 });
        send(ws, { type: 'player_connected', count: 2 });
        console.log(`Player joined room ${code}`);
        break;
      }

      case 'start_game': {
        const code = ws._roomCode;
        const room = rooms[code];
        if (!room || room.host !== ws) {
          send(ws, { type: 'error', message: 'Only host can start' });
          return;
        }
        if (!room.client) {
          send(ws, { type: 'error', message: 'Need 2 players to start' });
          return;
        }
        room.started = true;
        send(room.host, { type: 'game_start' });
        send(room.client, { type: 'game_start' });
        console.log(`Game started in room ${code}`);
        break;
      }

      case 'leave_room': {
        removeFromRoom(ws);
        break;
      }

      // Relay messages between players
      case 'game_state':
      case 'input':
      case 'snapshot':
      case 'attack':
      case 'damage':
      case 'restart':
      case 'round_reset':
      case 'round_win':
      case 'powerup_spawn':
      case 'power_despawn':
      case 'power_picked':
      case 'round_update':
      case 'match_end':
      case 'sudden_death': {
        const code = ws._roomCode;
        const room = rooms[code];
        if (!room) return;
        const other = getOther(room, ws);
        if (other) {
          send(other, data);
        }
        break;
      }

      default:
        send(ws, { type: 'error', message: `Unknown type: ${type}` });
    }
  });

  ws.on('close', () => {
    console.log('Client disconnected');
    removeFromRoom(ws);
  });

  ws.on('error', (err) => {
    console.error('WebSocket error:', err.message);
  });
});

// ══════════  START  ══════════

httpsServer.listen(PORT, '0.0.0.0', () => {
  console.log(`\n🩸 Bloody Brawler Server`);
  console.log(`   HTTPS + WebSocket on port ${PORT}`);
  console.log(`   Local:   https://localhost:${PORT}`);

  // Show LAN IPs
  const os = require('os');
  const nets = os.networkInterfaces();
  for (const name of Object.keys(nets)) {
    for (const net of nets[name]) {
      if (net.family === 'IPv4' && !net.internal) {
        console.log(`   Network: https://${net.address}:${PORT}`);
      }
    }
  }
  console.log(`\n   Open the Network URL on your phones!`);
  console.log(`   ⚠️  Accept the security warning (self-signed cert)\n`);
});
