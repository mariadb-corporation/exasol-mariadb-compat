// MariaDB Connector/C++ (libmariadbcpp, JDBC-style API) JSON Lines runner.
//
// Same driver-mode protocol as the other runners — see
// tests/connectors/README.md. Reads {"name","sql"} objects on stdin, runs each
// via Connector/C++ over MaxScale, writes {"name","ok","rows"|"error"} lines.
//
// The JSON read (request objects carry only two string fields) and write
// (proper escaping) are hand-rolled to avoid a JSON dependency, matching
// tests/connectors/mariadb_c/runner.c.
//
// Connector/C++ runs a mandatory system-variable probe at connect
// (SELECT @@max_allowed_packet, ...); the MaxScale exasolrouter preprocessor
// must answer it (see preprocessor/maria_preprocessor*.sql) or the handshake
// fails with "could not load system variables".
#define _POSIX_C_SOURCE 200809L
#include <conncpp.hpp>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>

/* ---- minimal JSON (identical approach to mariadb_c/runner.c) ---- */

static char *parse_jstr(const char **pp) {
    const char *p = *pp;
    while (*p && *p != '"') p++;
    if (*p != '"') return nullptr;
    p++;
    size_t cap = 64, len = 0;
    char *out = (char *)malloc(cap);
    if (!out) return nullptr;
#define APP(b) do { if (len + 1 >= cap) { cap *= 2; out = (char *)realloc(out, cap); } out[len++] = (char)(b); } while (0)
    while (*p && *p != '"') {
        unsigned char c = (unsigned char)*p++;
        if (c == '\\') {
            char e = *p++;
            switch (e) {
                case '"': APP('"'); break;
                case '\\': APP('\\'); break;
                case '/': APP('/'); break;
                case 'n': APP('\n'); break;
                case 't': APP('\t'); break;
                case 'r': APP('\r'); break;
                case 'b': APP('\b'); break;
                case 'f': APP('\f'); break;
                case 'u': {
                    char hex[5] = {p[0], p[1], p[2], p[3], 0};
                    p += 4;
                    unsigned int cp = (unsigned int)strtol(hex, nullptr, 16);
                    if (cp < 0x80) { APP(cp); }
                    else if (cp < 0x800) { APP(0xC0 | (cp >> 6)); APP(0x80 | (cp & 0x3F)); }
                    else { APP(0xE0 | (cp >> 12)); APP(0x80 | ((cp >> 6) & 0x3F)); APP(0x80 | (cp & 0x3F)); }
                    break;
                }
                default: APP(e); break;
            }
        } else {
            APP(c);
        }
    }
#undef APP
    if (*p != '"') { free(out); return nullptr; }
    p++;
    out[len] = 0;
    *pp = p;
    return out;
}

static int parse_req(const char *line, char **name, char **sql) {
    *name = nullptr;
    *sql = nullptr;
    const char *p = strchr(line, '{');
    if (!p) return -1;
    p++;
    while (*p) {
        while (*p && *p != '"' && *p != '}') p++;
        if (*p != '"') break;
        char *key = parse_jstr(&p);
        if (!key) return -1;
        while (*p && *p != ':') p++;
        if (*p != ':') { free(key); return -1; }
        p++;
        char *val = parse_jstr(&p);
        if (!val) { free(key); return -1; }
        if (strcmp(key, "name") == 0) { free(*name); *name = val; }
        else if (strcmp(key, "sql") == 0) { free(*sql); *sql = val; }
        else free(val);
        free(key);
        while (*p && *p != ',' && *p != '}') p++;
        if (*p == ',') p++;
    }
    return *sql ? 0 : -1;
}

static void put_jstr(const char *s) {
    putchar('"');
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        switch (c) {
            case '"': fputs("\\\"", stdout); break;
            case '\\': fputs("\\\\", stdout); break;
            case '\n': fputs("\\n", stdout); break;
            case '\r': fputs("\\r", stdout); break;
            case '\t': fputs("\\t", stdout); break;
            case '\b': fputs("\\b", stdout); break;
            case '\f': fputs("\\f", stdout); break;
            default:
                if (c < 0x20) printf("\\u%04x", c);
                else putchar(c);  /* raw UTF-8 is valid JSON */
        }
    }
    putchar('"');
}

/* ---- runner ---- */

int main(int argc, char **argv) {
    std::string host = "127.0.0.1", user = "admin_user", pass;
    int port = 3309;
    for (int i = 1; i < argc - 1; i++) {
        if (!strcmp(argv[i], "--host")) host = argv[++i];
        else if (!strcmp(argv[i], "--port")) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--user")) user = argv[++i];
        else if (!strcmp(argv[i], "--password")) pass = argv[++i];
    }

    std::unique_ptr<sql::Connection> conn;
    std::unique_ptr<sql::Statement> stmt;
    try {
        sql::Driver *driver = sql::mariadb::get_driver_instance();
        sql::SQLString url("jdbc:mariadb://" + host + ":" + std::to_string(port));
        sql::Properties props({{"user", sql::SQLString(user)},
                               {"password", sql::SQLString(pass)}});
        conn.reset(driver->connect(url, props));
        conn->setAutoCommit(true);
        stmt.reset(conn->createStatement());
    } catch (std::exception &e) {
        fputs("{\"event\":\"error\",\"error\":", stdout);
        put_jstr(e.what());
        fputs("}\n", stdout);
        return 2;
    }

    fputs("{\"event\":\"ready\",\"driver\":\"mariadb-connector-cpp\"}\n", stdout);
    fflush(stdout);

    char *line = nullptr;
    size_t cap = 0;
    while (getline(&line, &cap, stdin) > 0) {
        char *name = nullptr, *sqltext = nullptr;
        if (parse_req(line, &name, &sqltext) != 0) {
            fputs("{\"name\":", stdout);
            put_jstr(name ? name : "?");
            fputs(",\"ok\":false,\"error\":\"bad json request\"}\n", stdout);
            fflush(stdout);
            free(name); free(sqltext);
            continue;
        }
        try {
            bool has_rs = stmt->execute(sql::SQLString(sqltext));
            fputs("{\"name\":", stdout);
            put_jstr(name ? name : "?");
            fputs(",\"ok\":true,\"rows\":[", stdout);
            if (has_rs) {
                std::unique_ptr<sql::ResultSet> rs(stmt->getResultSet());
                uint32_t cols = rs->getMetaData()->getColumnCount();
                bool first_row = true;
                while (rs->next()) {
                    if (!first_row) putchar(',');
                    first_row = false;
                    putchar('[');
                    for (uint32_t i = 1; i <= cols; i++) {
                        if (i > 1) putchar(',');
                        sql::SQLString v = rs->getString((int32_t)i);
                        /* protocol NULL, or MaxScale ExasolRouter's literal
                         * "NULL" string, both map to JSON null. */
                        if (rs->wasNull() || strcmp(v.c_str(), "NULL") == 0)
                            fputs("null", stdout);
                        else
                            put_jstr(v.c_str());
                    }
                    putchar(']');
                }
            }
            fputs("]}\n", stdout);
            fflush(stdout);
        } catch (std::exception &e) {
            fputs("{\"name\":", stdout);
            put_jstr(name ? name : "?");
            fputs(",\"ok\":false,\"error\":", stdout);
            put_jstr(e.what());
            fputs("}\n", stdout);
            fflush(stdout);
        }
        free(name);
        free(sqltext);
    }
    free(line);
    return 0;
}
