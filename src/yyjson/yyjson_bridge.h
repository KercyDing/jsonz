#ifndef JSONZ_YYJSON_BRIDGE_H
#define JSONZ_YYJSON_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef struct yyjson_doc yyjson_doc;
typedef struct yyjson_val yyjson_val;

yyjson_doc *jsonz_yyjson_read(char *input, size_t len, bool comments, bool trailing,
                              int *error_code);
void jsonz_yyjson_free(yyjson_doc *doc);
yyjson_val *jsonz_yyjson_root(yyjson_doc *doc);
int jsonz_yyjson_kind(const yyjson_val *val);
bool jsonz_yyjson_bool(const yyjson_val *val);
uint64_t jsonz_yyjson_uint(const yyjson_val *val);
int64_t jsonz_yyjson_sint(const yyjson_val *val);
double jsonz_yyjson_real(const yyjson_val *val);
const char *jsonz_yyjson_str(const yyjson_val *val);
size_t jsonz_yyjson_len(const yyjson_val *val);
size_t jsonz_yyjson_size(const yyjson_val *val);
yyjson_val *jsonz_yyjson_index(const yyjson_val *val, size_t index);
yyjson_val *jsonz_yyjson_object_value(const yyjson_val *val, size_t index);
const char *jsonz_yyjson_object_key(const yyjson_val *val, size_t index);
size_t jsonz_yyjson_object_key_len(const yyjson_val *val, size_t index);
char *jsonz_yyjson_write(const yyjson_val *val, bool pretty, size_t *len);

#endif
