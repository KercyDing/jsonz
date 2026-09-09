#include "yyjson_bridge.h"
#include "yyjson.h"
#include <stdlib.h>
#include <string.h>

static yyjson_read_flag jsonz_yyjson_read_flags(bool comments, bool trailing) {
    yyjson_read_flag flags = 0;

    if (comments) {
        flags |= YYJSON_READ_ALLOW_COMMENTS;
    }
    if (trailing) {
        flags |= YYJSON_READ_ALLOW_TRAILING_COMMAS;
    }

    return flags;
}

yyjson_doc *jsonz_yyjson_read(char *input, size_t len, bool comments,
                              bool trailing, int *error_code) {
    yyjson_read_err error;
    yyjson_doc *document = yyjson_read_opts(
        input,
        len,
        jsonz_yyjson_read_flags(comments, trailing),
        NULL,
        &error
    );

    if (error_code) {
        *error_code = (int)error.code;
    }

    return document;
}

yyjson_doc *jsonz_yyjson_read_into(char *input, size_t len, bool comments,
                                   bool trailing, void *buffer,
                                   size_t buffer_len, int *error_code) {
    yyjson_alc allocator;
    yyjson_read_err error;

    if (!yyjson_alc_pool_init(&allocator, buffer, buffer_len)) {
        if (error_code) {
            *error_code = YYJSON_READ_ERROR_MEMORY_ALLOCATION;
        }
        return NULL;
    }

    yyjson_doc *document = yyjson_read_opts(
        input,
        len,
        jsonz_yyjson_read_flags(comments, trailing),
        &allocator,
        &error
    );

    if (error_code) {
        *error_code = (int)error.code;
    }

    return document;
}

size_t jsonz_yyjson_read_buffer_size(size_t len, bool comments,
                                     bool trailing) {
    return yyjson_read_max_memory_usage(
        len,
        jsonz_yyjson_read_flags(comments, trailing)
    );
}

void jsonz_yyjson_free(yyjson_doc *d) {
    yyjson_doc_free(d);
}

yyjson_val *jsonz_yyjson_root(yyjson_doc *d) {
    return yyjson_doc_get_root(d);
}

int jsonz_yyjson_kind(const yyjson_val *v) {
    switch (yyjson_get_type(v)) {
    case YYJSON_TYPE_NULL:
        return 0;
    case YYJSON_TYPE_BOOL:
        return 1;
    case YYJSON_TYPE_NUM:
        return yyjson_is_uint(v) ? 2 : yyjson_is_sint(v) ? 3 : 4;
    case YYJSON_TYPE_STR:
        return 5;
    case YYJSON_TYPE_ARR:
        return 6;
    case YYJSON_TYPE_OBJ:
        return 7;
    default:
        return 0;
    }
}

bool jsonz_yyjson_bool(const yyjson_val *v) {
    return yyjson_get_bool(v);
}

uint64_t jsonz_yyjson_uint(const yyjson_val *v) {
    return yyjson_get_uint(v);
}

int64_t jsonz_yyjson_sint(const yyjson_val *v) {
    return yyjson_get_sint(v);
}

double jsonz_yyjson_real(const yyjson_val *v) {
    return yyjson_get_real(v);
}

const char *jsonz_yyjson_str(const yyjson_val *v) {
    return yyjson_get_str(v);
}

size_t jsonz_yyjson_len(const yyjson_val *v) {
    return yyjson_get_len(v);
}

size_t jsonz_yyjson_size(const yyjson_val *v) {
    return yyjson_is_arr(v) ? yyjson_arr_size(v) : yyjson_obj_size(v);
}

yyjson_val *jsonz_yyjson_index(const yyjson_val *v, size_t i) {
    yyjson_val *x = yyjson_arr_get_first(v);
    while (x && i--)
        x = unsafe_yyjson_get_next(x);
    return x;
}

yyjson_val *jsonz_yyjson_object_get(const yyjson_val *v, const char *key,
                                    size_t key_len) {
    return yyjson_obj_getn(v, key, key_len);
}

yyjson_val *jsonz_yyjson_object_value(const yyjson_val *v, size_t i) {
    yyjson_obj_iter it = yyjson_obj_iter_with(v);
    yyjson_val *k;
    while ((k = yyjson_obj_iter_next(&it)) && i--)
        ;
    return k ? yyjson_obj_iter_get_val(k) : NULL;
}

const char *jsonz_yyjson_object_key(const yyjson_val *v, size_t i) {
    yyjson_obj_iter it = yyjson_obj_iter_with(v);
    yyjson_val *k;
    while ((k = yyjson_obj_iter_next(&it)) && i--)
        ;
    return k ? yyjson_get_str(k) : NULL;
}

char *jsonz_yyjson_write(const yyjson_val *v, bool pretty, size_t *l) {
    return yyjson_val_write(v, pretty ? YYJSON_WRITE_PRETTY : 0, l);
}

size_t jsonz_yyjson_object_key_len(const yyjson_val *v, size_t i) {
    const char *key = jsonz_yyjson_object_key(v, i);
    return key ? strlen(key) : 0;
}
