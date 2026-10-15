#ifndef P11_SQLITE_METRICS_H
#define P11_SQLITE_METRICS_H
#include <stdint.h>
int p11_metrics_start(const char *database_path);
void p11_metrics_stop(void);
// Logical requested bytes/calls, including mmap fetch requests, not physical disk bytes.
uint64_t p11_metrics_counter(int index);
#endif
