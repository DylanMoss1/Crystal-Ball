// Parses a structured search query (JSON) into the flat int32 buffer consumed
// by filters/find_joker.cl. Fixed 3-level grammar:
//
//   { "any": [                         <- OR over groups
//       { "all": [                     <- AND over clauses
//           { "atLeast": N,            <- at least N of the items below appear
//             "minAnte": 1,            <- ante window applies to the whole clause
//             "maxAnte": 4,
//             "of": [ "Blueprint", "Brainstorm", ... ]
//           } ] } ] }
//
// Buffer layout:
//   [numGroups]
//     per group:  [numClauses]
//       per clause: [N] [minAnte] [maxAnte] [numItems]
//         per item:  [itemId]
//
// Self-contained recursive-descent parser (no external deps). Returns a
// malloc'd int array via build_query_buffer; caller frees. NULL on parse error.
#ifndef QUERY_PARSE_H
#define QUERY_PARSE_H

#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include "lib/item_names.h"

typedef struct { int* data; int len; int cap; } qvec;

static int qvec_push(qvec* v, int x) {
    if (v->len == v->cap) {
        int ncap = v->cap ? v->cap * 2 : 32;
        int* nd = (int*)realloc(v->data, ncap * sizeof(int));
        if (!nd) return 0;
        v->data = nd;
        v->cap = ncap;
    }
    v->data[v->len++] = x;
    return 1;
}

typedef struct { const char* s; int ok; } qparser;

static void q_ws(qparser* p) { while (isspace((unsigned char)*p->s)) p->s++; }

static int q_eat(qparser* p, char c) {
    q_ws(p);
    if (*p->s == c) { p->s++; return 1; }
    p->ok = 0;
    return 0;
}

// Reads a JSON string into out (bounded). Assumes no escape sequences (item
// names and keys have none in this schema).
static int q_string(qparser* p, char* out, int outSize) {
    if (!q_eat(p, '"')) return 0;
    int n = 0;
    while (*p->s && *p->s != '"') {
        if (n < outSize - 1) out[n++] = *p->s;
        p->s++;
    }
    out[n] = '\0';
    return q_eat(p, '"');
}

static int q_int(qparser* p) {
    q_ws(p);
    char* end;
    long v = strtol(p->s, &end, 10);
    if (end == p->s) { p->ok = 0; return 0; }
    p->s = end;
    return (int)v;
}

// item := "<name>"   -> pushes its enum id
static void q_item(qparser* p, qvec* v) {
    char name[128];
    if (!q_string(p, name, sizeof name)) return;
    int item = item_from_name(name);
    if (item < 0) { fprintf(stderr, "Unknown item: %s\n", name); p->ok = 0; return; }
    qvec_push(v, item);
}

// clause := { "atLeast": N, "minAnte": X, "maxAnte": Y, "of": [ "<name>", ... ] }
// The ante window applies to the whole clause: at least N of the listed items
// must appear within [minAnte, maxAnte].
static void q_clause(qparser* p, qvec* v) {
    char key[64];
    int N = 0, lo = 0, hi = 0;
    qvec items = {0};
    int numItems = 0;
    if (!q_eat(p, '{')) { free(items.data); return; }
    do {
        if (!q_string(p, key, sizeof key) || !q_eat(p, ':')) { free(items.data); return; }
        if (strcmp(key, "atLeast") == 0) {
            N = q_int(p);
        } else if (strcmp(key, "minAnte") == 0) {
            lo = q_int(p);
        } else if (strcmp(key, "maxAnte") == 0) {
            hi = q_int(p);
        } else if (strcmp(key, "of") == 0) {
            if (!q_eat(p, '[')) { free(items.data); return; }
            q_ws(p);
            if (*p->s != ']') {
                do { q_item(p, &items); numItems++; q_ws(p); } while (p->ok && *p->s == ',' && q_eat(p, ','));
            }
            if (!q_eat(p, ']')) { free(items.data); return; }
        } else {
            p->ok = 0; free(items.data); return;
        }
        q_ws(p);
    } while (*p->s == ',' && q_eat(p, ','));
    if (!q_eat(p, '}')) { free(items.data); return; }
    qvec_push(v, N);
    qvec_push(v, lo);
    qvec_push(v, hi);
    qvec_push(v, numItems);
    for (int i = 0; i < items.len; i++) qvec_push(v, items.data[i]);
    free(items.data);
}

// group := { "all": [ clause, ... ] }
static void q_group(qparser* p, qvec* v) {
    char key[64];
    if (!q_eat(p, '{')) return;
    if (!q_string(p, key, sizeof key) || strcmp(key, "all") != 0 || !q_eat(p, ':')) { p->ok = 0; return; }
    if (!q_eat(p, '[')) return;
    int clauseCountIdx = v->len;
    qvec_push(v, 0);  // numClauses placeholder
    int numClauses = 0;
    q_ws(p);
    if (*p->s != ']') {
        do { q_clause(p, v); numClauses++; q_ws(p); } while (p->ok && *p->s == ',' && q_eat(p, ','));
    }
    if (!q_eat(p, ']') || !q_eat(p, '}')) return;
    v->data[clauseCountIdx] = numClauses;
}

// query := { "any": [ group, ... ] }
// returns: malloc'd int buffer (caller frees), *outLen set; NULL on error.
static int* build_query_buffer(const char* json, int* outLen) {
    qparser p = { json, 1 };
    qvec v = {0};
    char key[64];
    if (!q_eat(&p, '{')) goto fail;
    if (!q_string(&p, key, sizeof key) || strcmp(key, "any") != 0 || !q_eat(&p, ':')) goto fail;
    if (!q_eat(&p, '[')) goto fail;
    int groupCountIdx = v.len;
    qvec_push(&v, 0);  // numGroups placeholder
    int numGroups = 0;
    q_ws(&p);
    if (*p.s != ']') {
        do { q_group(&p, &v); numGroups++; q_ws(&p); } while (p.ok && *p.s == ',' && q_eat(&p, ','));
    }
    if (!q_eat(&p, ']') || !q_eat(&p, '}')) goto fail;
    if (!p.ok) goto fail;
    v.data[groupCountIdx] = numGroups;
    *outLen = v.len;
    return v.data;
fail:
    free(v.data);
    return NULL;
}

#endif
