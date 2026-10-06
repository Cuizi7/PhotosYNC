#ifndef PHOTOSYNC_SQLITE_VECTOR_QUERY_H
#define PHOTOSYNC_SQLITE_VECTOR_QUERY_H

#include <sqlite3.h>

// The caller owns the statement and context for this synchronous call only.
// Columns are key TEXT, origin TEXT, width/height INTEGER or both NULL, vector BLOB.
// Return the current diagnostic score floor. Equality is forwarded to Swift,
// whose String comparison owns tie ordering. NaN means collection failed.
typedef float (*PSVectorCollect)(void *context, sqlite3_stmt *row, float score);
typedef int (*PSVectorCancelled)(void *context);
enum PSVectorScanResult {
    PS_VECTOR_OK = 0,
    PS_VECTOR_INVALID_METADATA = 1,
    PS_VECTOR_INVALID_FINGERPRINT = 2,
    PS_VECTOR_SQLITE_ERROR = 3,
    PS_VECTOR_CANCELLED = 4,
    PS_VECTOR_COLLECTION_ERROR = 5
};
int ps_vector_scan(sqlite3_stmt *statement, const float *query, double threshold,
                   float diagnostic_floor, PSVectorCollect collect,
                   PSVectorCancelled cancelled, void *context);
#endif
