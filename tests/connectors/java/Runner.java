// MariaDB Connector/J -> MaxScale (ExasolRouter) -> Exasol runner.
//
// Driver-mode JSON Lines protocol. See tests/connectors/README.md.
//
//   in : {"name":"<id>","sql":"<MariaDB SQL>"}\n
//   out: first line = {"event":"ready","driver":"<lib>@<version>"}
//                  or {"event":"error","error":"<msg>"} (then exits non-zero)
//        per-request line = {"name":"<id>","ok":true,"rows":[[...],...]}
//                       or = {"name":"<id>","ok":false,"error":"<msg>"}
//
// Note for the MaxScale / ExasolRouter team reading this as a repro:
// Connector/J is JDBC and uses MariaDB's binary-protocol charset
// negotiation (no auto-`SET NAMES` SQL at handshake), so this connector
// connects cleanly even without server-side intervention. Behaviour on
// explicit `SET NAMES` from user code is what's interesting here vs the
// libmariadb-based runners.

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import org.json.JSONArray;
import org.json.JSONObject;

public class Runner {
    public static void main(String[] argv) {
        Map<String, String> args = new HashMap<>();
        args.put("host", "127.0.0.1");
        args.put("port", "3309");
        args.put("user", "admin_user");
        args.put("password", "");
        for (int i = 0; i < argv.length - 1; i += 2) {
            String k = argv[i].startsWith("--") ? argv[i].substring(2) : argv[i];
            args.put(k, argv[i + 1]);
        }

        // permitMysqlScheme=false avoids the connector trying mysql:// fallbacks.
        // useServerPrepStmts=false because we issue plain Statement.execute().
        String url = String.format(
            "jdbc:mariadb://%s:%s?user=%s&password=%s&tinyInt1isBit=false",
            args.get("host"), args.get("port"),
            args.get("user"), args.get("password"));

        Connection conn;
        try {
            conn = DriverManager.getConnection(url);
        } catch (Exception e) {
            emit(new JSONObject().put("event", "error")
                                 .put("error", e.getClass().getSimpleName() + ": " + e.getMessage()));
            System.exit(2);
            return;
        }

        String version;
        try {
            version = conn.getMetaData().getDriverVersion();
        } catch (Exception e) {
            version = "?";
        }
        emit(new JSONObject().put("event", "ready")
                             .put("driver", "mariadb-connector-j@" + version));

        try (BufferedReader in = new BufferedReader(
                new InputStreamReader(System.in, StandardCharsets.UTF_8))) {
            String line;
            while ((line = in.readLine()) != null) {
                if (line.trim().isEmpty()) continue;
                JSONObject req;
                try {
                    req = new JSONObject(line);
                } catch (Exception e) {
                    emit(new JSONObject().put("name", "?")
                                         .put("ok", false)
                                         .put("error", "bad json: " + e.getMessage()));
                    continue;
                }
                String name = req.optString("name", "?");
                String sql  = req.optString("sql", "");
                try (Statement st = conn.createStatement()) {
                    boolean isResultSet = st.execute(sql);
                    JSONArray rows = new JSONArray();
                    if (isResultSet) {
                        try (ResultSet rs = st.getResultSet()) {
                            ResultSetMetaData md = rs.getMetaData();
                            int n = md.getColumnCount();
                            while (rs.next()) {
                                JSONArray row = new JSONArray();
                                for (int i = 1; i <= n; i++) {
                                    Object v = rs.getObject(i);
                                    row.put(normalize(v));
                                }
                                rows.put(row);
                            }
                        }
                    }
                    emit(new JSONObject().put("name", name).put("ok", true).put("rows", rows));
                } catch (Exception e) {
                    emit(new JSONObject().put("name", name).put("ok", false)
                                         .put("error", e.getClass().getSimpleName() + ": "
                                              + e.getMessage()));
                }
            }
        } catch (Exception e) {
            // stdin error - exit cleanly
        } finally {
            try { conn.close(); } catch (Exception ignored) {}
        }
    }

    private static Object normalize(Object v) {
        if (v == null) return JSONObject.NULL;
        // MaxScale's ExasolRouter serializes actual SQL NULL as the literal
        // 4-byte ASCII string "NULL" instead of the MariaDB-protocol NULL
        // marker. Map back to JSON null. None of our fixture columns hold
        // the literal 4-char string "NULL".
        if (v instanceof byte[]) {
            byte[] b = (byte[]) v;
            if (b.length == 4 && b[0] == 'N' && b[1] == 'U' && b[2] == 'L' && b[3] == 'L') {
                return JSONObject.NULL;
            }
            return new String(b, StandardCharsets.UTF_8);
        }
        if (v instanceof String && ((String) v).equals("NULL")) {
            return JSONObject.NULL;
        }
        if (v instanceof Number || v instanceof Boolean || v instanceof String) {
            return v;
        }
        return v.toString();   // BigDecimal, Timestamp, etc.
    }

    private static void emit(JSONObject obj) {
        System.out.println(obj.toString());
        System.out.flush();
    }
}
