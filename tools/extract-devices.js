// ATK HUB'in cihaz tablosundan mouse modellerini cikarir ve cihazlar.csv dosyasini uretir.
// Extracts the mouse list (USB IDs, names, protocol family) from a local ATK HUB install.
//
//   node tools/extract-devices.js "%LOCALAPPDATA%\Programs\ATK HUB\resources\main\app.asar" > cihazlar.csv
//
// Yalnizca olgusal veriler (USB kimlikleri, model adlari) okunur; ATK kodu kopyalanmaz.
const fs = require('fs');

function readAsar(file) {
  const fd = fs.openSync(file, 'r');
  const head = Buffer.alloc(16);
  fs.readSync(fd, head, 0, 16, 0);
  const headerSize = head.readUInt32LE(12);
  const hb = Buffer.alloc(headerSize);
  fs.readSync(fd, hb, 0, headerSize, 16);
  const header = JSON.parse(hb.toString('utf8'));
  const base = 8 + head.readUInt32LE(4);
  const files = [];
  (function walk(node, p) {
    for (const [k, v] of Object.entries(node.files || {})) {
      const q = p ? p + '/' + k : k;
      if (v.files) walk(v, q); else files.push([q, v]);
    }
  })(header, '');
  return {
    files,
    read(entry) {
      const buf = Buffer.alloc(entry.size);
      fs.readSync(fd, buf, 0, entry.size, base + Number(entry.offset));
      return buf.toString('utf8');
    },
  };
}

const asar = readAsar(process.argv[2]);
const bundle = asar.files
  .filter(([p, v]) => /^static\/index-.*\.js$/.test(p) && !v.unpacked)
  .map(([, v]) => asar.read(v))
  .find((src) => src.includes('solutionProvider'));
if (!bundle) throw new Error('ATK HUB cihaz tablosu bulunamadi / device table not found');

// Gruplar: {controller, meta:{deviceType, solutionProvider}, filters:[...]}
const groupRe = /\{controller:[\w$]+,meta:\{deviceType:[\w$]+\.(\w+),solutionProvider:[\w$]+\.(\w+)[^}]*\},filters:\[/g;
const groups = [];
let m;
while ((m = groupRe.exec(bundle))) groups.push({ at: m.index, type: m[1], family: m[2] });

const byId = new Map();
groups.forEach((g, i) => {
  if (g.type !== 'MOUSE') return;
  const seg = bundle.slice(g.at, i + 1 < groups.length ? groups[i + 1].at : g.at + 400000);
  const fRe = /\{vendorId:(\d+),productId:(\d+)(?:,usagePage:\d+)?(?:,usage:\d+)?(,receiver:!0)?(?:,custom:\{name:"([^"]*)")?/g;
  let f;
  while ((f = fRe.exec(seg))) {
    const name = (f[4] || '').trim();
    if (!name) continue;
    const vid = (+f[1]).toString(16).toUpperCase().padStart(4, '0');
    const pid = (+f[2]).toString(16).toUpperCase().padStart(4, '0');
    const key = `${vid}:${pid}`;
    const e = byId.get(key) || { vid, pid, families: new Set(), receiver: new Set(), names: [] };
    e.families.add(g.family);
    e.receiver.add(!!f[3]);
    if (!e.names.includes(name)) e.names.push(name);
    byId.set(key, e);
  }
});

const csv = (s) => (/[",]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s);
const out = ['vid,pid,family,receiver,name'];
for (const e of [...byId.values()].sort((a, b) => (a.vid + a.pid).localeCompare(b.vid + b.pid))) {
  // Ayni kimlik farkli ailelerde ya da hem mouse hem alici olarak geciyorsa belirsizdir: atla
  if (e.families.size > 1 || e.receiver.size > 1) {
    console.error(`atlandi (belirsiz) / skipped (ambiguous): ${e.vid}:${e.pid} ${e.names.join(' / ')}`);
    continue;
  }
  out.push([e.vid, e.pid, [...e.families][0], [...e.receiver][0] ? 1 : 0, csv(e.names.join(' / '))].join(','));
}
process.stdout.write(out.join('\r\n') + '\r\n');
console.error(`${out.length - 1} cihaz / devices`);
