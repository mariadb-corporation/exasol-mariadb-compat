/* MariaDB Connector/C (libmariadb) JSON Lines runner.
 *
 * Same driver-mode protocol as the other runners — see
 * tests/connectors/README.md. Reads {"name","sql"} objects on stdin, runs each
 * via libmariadb over MaxScale, and writes {"name","ok","rows"|"error"} lines.
 *
 * Self-contained: a tiny JSON reader (the request objects only ever carry two
 * string fields) and writer (proper escaping) avoid pulling in a JSON lib.
 */
#define _POSIX_C_SOURCE 200809L
#include <mysql.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- minimal JSON ---- */

/* Parse a JSON string starting at/after **pp (skips up to the opening quote),
 * decoding escapes. Returns a malloc'd NUL-terminated string and advances *pp
 * past the closing quote; NULL on malformed input. */
static char *parse_jstr(const char **pp) {
    const char *p = *pp;
    while (*p && *p != '"') p++;
    if (*p != '"') return NULL;
    p++;
    size_t cap = 64, len = 0;
    char *out = malloc(cap);
    if (!out) return NULL;
#define APP(b) do { if (len + 1 >= cap) { cap *= 2; out = realloc(out, cap); } out[len++] = (char)(b); } while (0)
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
                    unsigned int cp = (unsigned int)strtol(hex, NULL, 16);
                    if (cp < 0x80) {
                        APP(cp);
                    } else if (cp < 0x800) {
                        APP(0xC0 | (cp >> 6));
                        APP(0x80 | (cp & 0x3F));
                    } else {
                        APP(0xE0 | (cp >> 12));
                        APP(0x80 | ((cp >> 6) & 0x3F));
                        APP(0x80 | (cp & 0x3F));
                    }
                    break;
                }
                default: APP(e); break;
            }
        } else {
            APP(c);
        }
    }
#undef APP
    if (*p != '"') { free(out); return NULL; }
    p++;
    out[len] = 0;
    *pp = p;
    return out;
}

/* Pull the "name" and "sql" string fields out of one request object. All values
 * in this protocol are strings, so a flat key:"value" scan suffices. */
static int parse_req(const char *line, char **name, char **sql) {
    *name = NULL;
    *sql = NULL;
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

static void emit_result(const char *name, MYSQL_RES *res, MYSQL *conn) {
    fputs("{\"name\":", stdout);
    put_jstr(name ? name : "?");
    fputs(",\"ok\":true,\"rows\":[", stdout);
    if (res) {
        unsigned int nf = mysql_num_fields(res);
        MYSQL_ROW row;
        int first_row = 1;
        while ((row = mysql_fetch_row(res))) {
            if (!first_row) putchar(',');
            first_row = 0;
            putchar('[');
            for (unsigned int i = 0; i < nf; i++) {
                if (i) putchar(',');
                /* MaxScale's ExasolRouter serializes SQL NULL as the literal
                 * 4-byte string "NULL"; map both that and protocol NULL to
                 * JSON null (no fixture column holds the literal word NULL). */
                if (row[i] == NULL || strcmp(row[i], "NULL") == 0) fputs("null", stdout);
                else put_jstr(row[i]);
            }
            putchar(']');
        }
    }
    fputs("]}\n", stdout);
    fflush(stdout);
}

static void emit_error(const char *name, const char *msg) {
    fputs("{\"name\":", stdout);
    put_jstr(name ? name : "?");
    fputs(",\"ok\":false,\"error\":", stdout);
    put_jstr(msg);
    fputs("}\n", stdout);
    fflush(stdout);
}

int main(int argc, char **argv) {
    const char *host = "127.0.0.1", *user = "admin_user", *pass = "";
    unsigned int port = 3309;
    for (int i = 1; i < argc - 1; i++) {
        if (!strcmp(argv[i], "--host")) host = argv[++i];
        else if (!strcmp(argv[i], "--port")) port = (unsigned int)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--user")) user = argv[++i];
        else if (!strcmp(argv[i], "--password")) pass = argv[++i];
    }

    MYSQL *conn = mysql_init(NULL);
    if (!conn) { printf("{\"event\":\"error\",\"error\":\"mysql_init failed\"}\n"); return 2; }
    mysql_options(conn, MYSQL_SET_CHARSET_NAME, "utf8mb4");
    unsigned int timeout = 5;
    mysql_options(conn, MYSQL_OPT_CONNECT_TIMEOUT, &timeout);
    if (!mysql_real_connect(conn, host, user, pass, NULL, port, NULL, 0)) {
        printf("{\"event\":\"error\",\"error\":\"");
        for (const char *e = mysql_error(conn); *e; e++)
            if (*e == '"' || *e == '\\') { putchar('\\'); putchar(*e); }
            else if ((unsigned char)*e >= 0x20) putchar(*e);
        printf("\"}\n");
        return 2;
    }
    mysql_autocommit(conn, 1);  /* best-effort */

    printf("{\"event\":\"ready\",\"driver\":\"mariadb-connector-c@%s\"}\n",
           mysql_get_client_info());
    fflush(stdout);

    char *line = NULL;
    size_t cap = 0;
    ssize_t n;
    while ((n = getline(&line, &cap, stdin)) > 0) {
        char *name = NULL, *sql = NULL;
        if (parse_req(line, &name, &sql) != 0) {
            emit_error(name, "bad json request");
            free(name); free(sql);
            continue;
        }
        if (mysql_query(conn, sql)) {
            emit_error(name, mysql_error(conn));
        } else {
            MYSQL_RES *res = mysql_store_result(conn);
            if (!res && mysql_field_count(conn) != 0)
                emit_error(name, mysql_error(conn));  /* result expected but store failed */
            else {
                emit_result(name, res, conn);
                if (res) mysql_free_result(res);
            }
        }
        free(name); free(sql);
    }
    free(line);
    mysql_close(conn);
    return 0;
}
