#ifndef CMS_QUICKJS_BRIDGE_H
#define CMS_QUICKJS_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    CMS_QJS_OK = 0,
    CMS_QJS_ERROR = 1,
    CMS_QJS_TIMEOUT = 2,
    CMS_QJS_MEMORY = 3,
} CmsQjsStatus;

typedef struct {
    int status;
    char *output_json;
    char *error_message;
} CmsQjsEvalResult;

/**
 * Evaluate a CMS function (`function compute(input) { ... }` or `function main(input) { ... }`)
 * inside a fresh locked-down QuickJS context with:
 *   - 4 MiB heap limit
 *   - 256 KiB stack limit
 *   - 50 interrupt callbacks / 50 ms wall-clock deadline
 *   - 64 KiB source limit, 8 KiB serialized output limit
 *   - No eval, Function, Promise, Math.random, Object.setPrototypeOf, Reflect.setPrototypeOf, or __proto__
 */
void cms_qjs_eval(
    const char *filename,
    const char *source,
    size_t source_len,
    const char *input_json,
    size_t input_json_len,
    CmsQjsEvalResult *out_result
);

void cms_qjs_free_result(CmsQjsEvalResult *result);

#ifdef __cplusplus
}
#endif

#endif /* CMS_QUICKJS_BRIDGE_H */
