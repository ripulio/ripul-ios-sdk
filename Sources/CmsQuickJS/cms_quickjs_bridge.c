#include "include/cms_quickjs_bridge.h"
#include "quickjs.h"

#include <malloc/malloc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CMS_QJS_MEMORY_LIMIT (4u * 1024 * 1024)
#define CMS_QJS_STACK_LIMIT  (256u * 1024)
#define CMS_QJS_TICK_BUDGET  50
#define CMS_QJS_DEADLINE_NS  (50ull * 1000 * 1000)
#define CMS_QJS_MAX_SOURCE   (64u * 1024)
#define CMS_QJS_MAX_OUTPUT   (8u * 1024)
#define CMS_QJS_MALLOC_OVERHEAD 8

static uint64_t cms_now_ns(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

typedef struct {
    uint64_t start;
    uint64_t deadline;
    int ticks;
    int tripped;
    int memory_hit;
} CmsBudget;

static void *cms_guarded_malloc(JSMallocState *s, size_t size) {
    if (s->malloc_size + size > s->malloc_limit) {
        ((CmsBudget *)s->opaque)->memory_hit = 1;
        return NULL;
    }
    void *ptr = malloc(size);
    if (!ptr) return NULL;
    s->malloc_count++;
    s->malloc_size += malloc_size(ptr) + CMS_QJS_MALLOC_OVERHEAD;
    return ptr;
}

static void cms_guarded_free(JSMallocState *s, void *ptr) {
    if (!ptr) return;
    s->malloc_count--;
    s->malloc_size -= malloc_size(ptr) + CMS_QJS_MALLOC_OVERHEAD;
    free(ptr);
}

static void *cms_guarded_realloc(JSMallocState *s, void *ptr, size_t size) {
    if (!ptr) return size ? cms_guarded_malloc(s, size) : NULL;
    size_t old_size = malloc_size(ptr);
    if (size == 0) {
        s->malloc_count--;
        s->malloc_size -= old_size + CMS_QJS_MALLOC_OVERHEAD;
        free(ptr);
        return NULL;
    }
    if (s->malloc_size + size - old_size > s->malloc_limit) {
        ((CmsBudget *)s->opaque)->memory_hit = 1;
        return NULL;
    }
    ptr = realloc(ptr, size);
    if (!ptr) return NULL;
    s->malloc_size += malloc_size(ptr) - old_size;
    return ptr;
}

static size_t cms_guarded_usable_size(const void *ptr) {
    return malloc_size(ptr);
}

static const JSMallocFunctions cms_guarded_malloc_funcs = {
    cms_guarded_malloc,
    cms_guarded_free,
    cms_guarded_realloc,
    cms_guarded_usable_size,
};

static int cms_interrupt_handler(JSRuntime *rt, void *opaque) {
    (void)rt;
    CmsBudget *b = (CmsBudget *)opaque;
    uint64_t t = cms_now_ns();
    if (b->tripped) return 1;
    if (++b->ticks > CMS_QJS_TICK_BUDGET || t > b->deadline) {
        b->tripped = 1;
    }
    return b->tripped;
}

static JSContext *cms_new_guest_context(JSRuntime *rt) {
    JSContext *ctx = JS_NewContextRaw(rt);
    if (!ctx) return NULL;
    JS_AddIntrinsicBaseObjects(ctx);
    JS_AddIntrinsicEval(ctx);
    JS_AddIntrinsicRegExpCompiler(ctx);
    JS_AddIntrinsicRegExp(ctx);
    JS_AddIntrinsicJSON(ctx);
    JS_AddIntrinsicMapSet(ctx);
    JS_AddIntrinsicPromise(ctx);
    return ctx;
}

static char *cms_strdup(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s);
    char *copy = (char *)malloc(n + 1);
    if (!copy) return NULL;
    memcpy(copy, s, n + 1);
    return copy;
}

static void cms_record_exception(JSContext *ctx, CmsBudget *b, CmsQjsEvalResult *out) {
    JSValue ex = JS_GetException(ctx);
    const char *msg = JS_ToCString(ctx, ex);
    if (b->tripped) {
        out->status = CMS_QJS_TIMEOUT;
        out->error_message = cms_strdup("Function exceeded its execution limit.");
    } else if (b->memory_hit) {
        out->status = CMS_QJS_MEMORY;
        out->error_message = cms_strdup("Function exceeded its memory limit.");
    } else {
        out->status = CMS_QJS_ERROR;
        out->error_message = cms_strdup(msg ? msg : "Function evaluation failed.");
    }
    if (msg) JS_FreeCString(ctx, msg);
    JS_FreeValue(ctx, ex);
}

static const char cms_lock_down_compiler[] =
    "(function(){ 'use strict';"
    " const no = function(){ throw new TypeError('code generation is not allowed'); };"
    " delete globalThis.eval;"
    " delete globalThis.Promise;"
    " delete Object.setPrototypeOf;"
    " if (globalThis.Reflect) delete Reflect.setPrototypeOf;"
    " delete Object.prototype.__proto__;"
    " if (globalThis.Math) delete Math.random;"
    " for (const f of [function(){}, function*(){}, async function(){}, async function*(){}]) {"
    "   const p = Object.getPrototypeOf(f);"
    "   Object.defineProperty(p, 'constructor', { value: no, writable: false, configurable: false });"
    " }"
    " Object.defineProperty(globalThis, 'Function', { value: no, writable: false, configurable: false });"
    "})();";

void cms_qjs_eval(
    const char *filename,
    const char *source,
    size_t source_len,
    const char *input_json,
    size_t input_json_len,
    CmsQjsEvalResult *out_result
) {
    memset(out_result, 0, sizeof(*out_result));
    if (!source || source_len > CMS_QJS_MAX_SOURCE) {
        out_result->status = CMS_QJS_ERROR;
        out_result->error_message = cms_strdup("Function source exceeds the 64 KiB limit.");
        return;
    }
    if (!input_json || input_json_len > CMS_QJS_MAX_SOURCE) {
        out_result->status = CMS_QJS_ERROR;
        out_result->error_message = cms_strdup("Function inputs exceed the 64 KiB limit.");
        return;
    }

    CmsBudget b;
    memset(&b, 0, sizeof(b));
    uint64_t t0 = cms_now_ns();
    b.start = t0;
    b.deadline = t0 + CMS_QJS_DEADLINE_NS;

    JSRuntime *rt = JS_NewRuntime2(&cms_guarded_malloc_funcs, &b);
    if (!rt) {
        out_result->status = CMS_QJS_MEMORY;
        out_result->error_message = cms_strdup("Could not allocate QuickJS runtime.");
        return;
    }
    JS_SetMemoryLimit(rt, CMS_QJS_MEMORY_LIMIT);
    JS_SetMaxStackSize(rt, CMS_QJS_STACK_LIMIT);
    JS_SetInterruptHandler(rt, cms_interrupt_handler, &b);

    JSContext *ctx = cms_new_guest_context(rt);
    if (!ctx) {
        JS_FreeRuntime(rt);
        out_result->status = CMS_QJS_MEMORY;
        out_result->error_message = cms_strdup("Could not allocate QuickJS context.");
        return;
    }

    JSValue v = JS_Eval(ctx, cms_lock_down_compiler, sizeof(cms_lock_down_compiler) - 1, "<lockdown>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(v)) {
        cms_record_exception(ctx, &b, out_result);
        goto done;
    }
    JS_FreeValue(ctx, v);

    v = JS_Eval(ctx, source, source_len, filename ? filename : "function.js", JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_STRICT);
    if (JS_IsException(v)) {
        cms_record_exception(ctx, &b, out_result);
        goto done;
    }
    JS_FreeValue(ctx, v);

    JSValue global = JS_GetGlobalObject(ctx);
    JSValue fn = JS_GetPropertyStr(ctx, global, "compute");
    if (!JS_IsFunction(ctx, fn)) {
        JS_FreeValue(ctx, fn);
        fn = JS_GetPropertyStr(ctx, global, "main");
    }
    JS_FreeValue(ctx, global);

    if (!JS_IsFunction(ctx, fn)) {
        JS_FreeValue(ctx, fn);
        out_result->status = CMS_QJS_ERROR;
        out_result->error_message = cms_strdup("Function must define function compute(input) { ... }.");
        goto done;
    }

    JSValue arg = JS_ParseJSON(ctx, input_json, input_json_len, "<input>");
    if (JS_IsException(arg)) {
        JS_FreeValue(ctx, fn);
        cms_record_exception(ctx, &b, out_result);
        goto done;
    }

    JSValue out = JS_Call(ctx, fn, JS_UNDEFINED, 1, &arg);
    JS_FreeValue(ctx, arg);
    JS_FreeValue(ctx, fn);

    if (JS_IsException(out)) {
        cms_record_exception(ctx, &b, out_result);
        goto done;
    }

    if ((int)JS_PromiseState(ctx, out) >= 0) {
        JS_FreeValue(ctx, out);
        out_result->status = CMS_QJS_ERROR;
        out_result->error_message = cms_strdup("Function returned a Promise; CMS functions must be synchronous.");
        goto done;
    }

    if (JS_IsUndefined(out)) {
        JS_FreeValue(ctx, out);
        out_result->status = CMS_QJS_OK;
        out_result->output_json = cms_strdup("null");
        goto done;
    }

    JSValue json = JS_JSONStringify(ctx, out, JS_UNDEFINED, JS_UNDEFINED);
    JS_FreeValue(ctx, out);
    if (JS_IsException(json)) {
        cms_record_exception(ctx, &b, out_result);
        goto done;
    }

    size_t olen = 0;
    const char *s = JS_IsUndefined(json) ? NULL : JS_ToCStringLen(ctx, &olen, json);
    if (!s) {
        out_result->status = CMS_QJS_ERROR;
        out_result->error_message = cms_strdup("Function returned a non-serializable value.");
    } else if (olen > CMS_QJS_MAX_OUTPUT) {
        out_result->status = CMS_QJS_ERROR;
        out_result->error_message = cms_strdup("Function output exceeds the 8 KiB limit.");
    } else {
        out_result->status = CMS_QJS_OK;
        out_result->output_json = (char *)malloc(olen + 1);
        if (out_result->output_json) {
            memcpy(out_result->output_json, s, olen);
            out_result->output_json[olen] = '\0';
        } else {
            out_result->status = CMS_QJS_MEMORY;
            out_result->error_message = cms_strdup("Out of memory copying result.");
        }
    }
    if (s) JS_FreeCString(ctx, s);
    JS_FreeValue(ctx, json);

done:
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
}

void cms_qjs_free_result(CmsQjsEvalResult *result) {
    if (!result) return;
    if (result->output_json) {
        free(result->output_json);
        result->output_json = NULL;
    }
    if (result->error_message) {
        free(result->error_message);
        result->error_message = NULL;
    }
}
