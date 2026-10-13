// MariaDB Node.js connector → MaxScale (ExasolRouter) → Exasol runner.
//
// Driver-mode JSON Lines protocol. Master spawns this once per test group,
// pipes test cases through stdin, reads results from stdout, then closes
// stdin to signal end-of-run.
//
//   in : {"name":"<id>","sql":"<MariaDB SQL>"}\n
//   out: first line = {"event":"ready","driver":"<lib>@<version>"}
//                  or {"event":"error","error":"<msg>"} (then exits non-zero)
//        per-request line = {"name":"<id>","ok":true,"rows":[[...],...]}
//                       or = {"name":"<id>","ok":false,"error":"<msg>"}
//
// Rows are returned as plain JS arrays-of-arrays so the master can stringify
// them the same way it stringifies pyexasol rows. Buffers (e.g. binary
// columns) are decoded as utf-8 strings, since every test fixture today
// holds text/integer/decimal data.

const mariadb = require("mariadb");
const readline = require("readline");

function arg(name, def) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : def;
}

const cfg = {
  host: arg("host", "127.0.0.1"),
  port: parseInt(arg("port", "3309"), 10),
  user: arg("user", "admin_user"),
  password: arg("password", ""),
  // Skip the connector's own implicit `SET NAMES <charset>` on handshake —
  // we want to test what happens when the user-level test SQL itself runs,
  // not background traffic the connector emits.
  charset: "utf8mb4",
  collation: "UTF8MB4_UNICODE_CI",
  connectTimeout: 5_000,
  // Buffers in -> strings out, integers as JS numbers; tests have no BIGINT
  // ranges that overflow JS number precision.
  bigIntAsNumber: true,
  // Positional rows, like every other runner here. With name-keyed row objects
  // the column order is JS object property order, and ECMAScript enumerates
  // integer-like keys FIRST in numeric order -- so a result column that happens
  // to be *named* e.g. `16777216` (as an unaliased literal projection is) jumps
  // ahead of its siblings and Object.values() reports the values out of order.
  rowsAsArray: true,
};

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function normalize(rows) {
  // mariadb-connector-nodejs returns either an array of row-objects or an
  // OkPacket-shaped object for non-result statements. Test framework
  // expects [] for non-result, and array-of-arrays for result sets.
  if (!Array.isArray(rows)) return [];
  return rows.map((r) => {
    if (Array.isArray(r)) return r.map(decode);
    // Fallback only: with rowsAsArray the driver already yields arrays. Object
    // rows cannot preserve SELECT order when a column name is integer-like.
    return Object.values(r).map(decode);
  });
}

function decode(v) {
  if (!Buffer.isBuffer(v)) return v;
  // MaxScale's ExasolRouter serializes actual SQL NULL as the literal 4-byte
  // ASCII string "NULL" instead of the MariaDB-protocol NULL marker (0xFB).
  // None of our fixture columns hold the literal 4-char string "NULL", so
  // map this back to JS null. Without this, every UDF NULL-return test (e.g.
  // ELT/out_of_range, JSON_EXTRACT/all_missing) fails: expected [[None]],
  // actual [['NULL']]. Bug-on-MaxScale-side; this is a test-time workaround.
  if (v.length === 4 && v[0] === 0x4e && v[1] === 0x55 && v[2] === 0x4c && v[3] === 0x4c) {
    return null;
  }
  return v.toString("utf8");
}

(async () => {
  let conn;
  try {
    conn = await mariadb.createConnection(cfg);
  } catch (e) {
    emit({ event: "error", error: `connect failed: ${e.code || ""} ${e.message}` });
    process.exit(2);
  }
  const pkg = require("mariadb/package.json");
  emit({ event: "ready", driver: `mariadb-connector-nodejs@${pkg.version}` });

  const rl = readline.createInterface({ input: process.stdin, terminal: false });
  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let req;
    try {
      req = JSON.parse(trimmed);
    } catch (e) {
      emit({ name: "?", ok: false, error: `bad json: ${e.message}` });
      continue;
    }
    try {
      const r = await conn.query(req.sql);
      emit({ name: req.name, ok: true, rows: normalize(r) });
    } catch (e) {
      const code = e.errno || e.code || "?";
      emit({ name: req.name, ok: false, error: `[${code}] ${e.text || e.message || ""}` });
    }
  }
  await conn.end();
})();
