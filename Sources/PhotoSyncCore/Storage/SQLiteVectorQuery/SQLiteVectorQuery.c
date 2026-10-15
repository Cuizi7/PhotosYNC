#include "SQLiteVectorQuery.h"
#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

// Reject malformed metadata even when its vector cannot enter either output.
// Do not normalize or compare keys here: Swift String supplies the oracle order.
static int valid_utf8(const unsigned char *text, int count) {
    for (int i = 0; i < count;) {
        uint32_t c = text[i++];
        if (c == 0) return 0;
        if (c < 0x80) continue;
        int continuation;
        uint32_t minimum;
        if (c >= 0xc2 && c <= 0xdf) { continuation = 1; minimum = 0x80; c &= 0x1f; }
        else if (c >= 0xe0 && c <= 0xef) { continuation = 2; minimum = 0x800; c &= 0x0f; }
        else if (c >= 0xf0 && c <= 0xf4) { continuation = 3; minimum = 0x10000; c &= 0x07; }
        else return 0;
        if (continuation > count - i) return 0;
        for (int j = 0; j < continuation; j++) {
            unsigned char b = text[i++];
            if ((b & 0xc0) != 0x80) return 0;
            c = (c << 6) | (b & 0x3f);
        }
        if (c < minimum || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff)) return 0;
    }
    return count > 0;
}

static int valid_metadata(sqlite3_stmt *row) {
    if (sqlite3_column_type(row, 0) != SQLITE_TEXT || sqlite3_column_type(row, 1) != SQLITE_TEXT) return 0;
    const unsigned char *key = sqlite3_column_text(row, 0);
    const unsigned char *origin = sqlite3_column_text(row, 1);
    if (!key || !origin || !valid_utf8(key, sqlite3_column_bytes(row, 0)) ||
        !valid_utf8(origin, sqlite3_column_bytes(row, 1))) return 0;
    if (strcmp((const char *)origin, "photosOriginal") && strcmp((const char *)origin, "photosCurrent") &&
        strcmp((const char *)origin, "localPending") && strcmp((const char *)origin, "localImporting") &&
        strcmp((const char *)origin, "successHistory")) return 0;
    int width_type = sqlite3_column_type(row, 2), height_type = sqlite3_column_type(row, 3);
    if (width_type == SQLITE_NULL && height_type == SQLITE_NULL) return 1;
    return width_type == SQLITE_INTEGER && height_type == SQLITE_INTEGER &&
        sqlite3_column_int64(row, 2) > 0 && sqlite3_column_int64(row, 3) > 0;
}

int ps_vector_scan(sqlite3_stmt *statement, const float *query, double threshold,
                   float diagnostic_floor, PSVectorCollect collect,
                   PSVectorCancelled cancelled, void *context) {
    int step;
    while (1) {
        if (cancelled(context)) return PS_VECTOR_CANCELLED;
        step = sqlite3_step(statement);
        if (step != SQLITE_ROW) break;
        if (!valid_metadata(statement)) return PS_VECTOR_INVALID_METADATA;
        if (sqlite3_column_type(statement, 4) != SQLITE_BLOB || sqlite3_column_bytes(statement, 4) != 4096)
            return PS_VECTOR_INVALID_FINGERPRINT;
        const void *bytes = sqlite3_column_blob(statement, 4);
        if (!bytes) return PS_VECTOR_INVALID_FINGERPRINT;
        // SQLite BLOBs need not be aligned. Only this row's 4 KiB is copied.
        _Alignas(16) float vector[1024];
        memcpy(vector, bytes, sizeof(vector));
        double norm = 0;
        for (int i = 0; i < 1024; i++) {
            if (!isfinite(vector[i])) return PS_VECTOR_INVALID_FINGERPRINT;
            double x = vector[i];
            norm += x * x;
        }
        if (!isfinite(norm) || fabs(norm - 1) > 0.00001) return PS_VECTOR_INVALID_FINGERPRINT;
        float score = 0;
        vDSP_dotpr(query, 1, vector, 1, &score, 1024);
        if (!isfinite(score)) return PS_VECTOR_INVALID_FINGERPRINT;
        if ((double)score >= threshold || score >= diagnostic_floor) {
            diagnostic_floor = collect(context, statement, score);
            if (isnan(diagnostic_floor)) return PS_VECTOR_COLLECTION_ERROR;
        }
    }
    if (cancelled(context)) return PS_VECTOR_CANCELLED;
    return step == SQLITE_DONE ? PS_VECTOR_OK : PS_VECTOR_SQLITE_ERROR;
}
