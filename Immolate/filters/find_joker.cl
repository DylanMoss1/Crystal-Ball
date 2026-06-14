// Structured query evaluator (3 fixed levels):
//   match = OR over groups ( AND over clauses ( atLeast N of items ) )
//   clause = "at least N of {items} appear in a shop within antes [min, max]"
//
// The ante window scopes the whole clause, not each item: every item in a
// clause shares the same [minAnte, maxAnte].
//
// Query buffer layout (flat int32, built by the host from JSON):
//   [numGroups]
//     per group:  [numClauses]
//       per clause: [N] [minAnte] [maxAnte] [numItems]
//         per item:  [itemId]
//
// Predicate is shop-only for now (packs/consumables to follow). Each item is
// flattened to an (item, lo, hi) criterion carrying its clause's window,
// satisfied by a single forward ante pass (the rng cache makes shop reads
// deterministic), then the structure is re-walked in identical order to
// combine the per-item flags.
#define FILTER_USES_QUERY
#include "lib/immolate.cl"

#define SHOP_SCAN 4 // shop slots inspected per ante
#define MAX_CRIT 64 // cap on total items across the whole query

long filter(instance* inst, __global int* q, int qlen) {
    int critItem[MAX_CRIT];
    int critLo[MAX_CRIT];
    int critHi[MAX_CRIT];
    bool critSat[MAX_CRIT];
    int nCrit = 0;
    int maxAnte = 0;

    // Pass 1: flatten each clause's items (encounter order = flat index),
    // tagging them with the clause's shared ante window, and find max ante.
    int p = 0;
    int numGroups = q[p++];
    for (int g = 0; g < numGroups; g++) {
        int numClauses = q[p++];
        for (int c = 0; c < numClauses; c++) {
            p++; // skip N
            int lo = q[p++];
            int hi = q[p++];
            int numItems = q[p++];
            for (int k = 0; k < numItems; k++) {
                int it = q[p++];
                if (nCrit < MAX_CRIT) {
                    critItem[nCrit] = it;
                    critLo[nCrit] = lo;
                    critHi[nCrit] = hi;
                    critSat[nCrit] = false;
                    if (hi > maxAnte) maxAnte = hi;
                    nCrit++;
                }
            }
        }
    }

    // Forward pass: scan each ante's first SHOP_SCAN shop items once, marking
    // every criterion the item satisfies.
    for (int ante = 1; ante <= maxAnte; ante++) {
        for (int slot = 0; slot < SHOP_SCAN; slot++) {
            int it = next_shop_item(inst, ante).value;
            for (int j = 0; j < nCrit; j++) {
                if (critItem[j] == it && ante >= critLo[j] && ante <= critHi[j]) {
                    critSat[j] = true;
                }
            }
        }
    }

    // Pass 2: re-walk the structure in identical order, combining flags.
    int p2 = 0;
    int j2 = 0;
    int ng = q[p2++];
    bool match = false;
    for (int g = 0; g < ng; g++) {
        int numClauses = q[p2++];
        bool groupOk = true;
        for (int c = 0; c < numClauses; c++) {
            int N = q[p2++];
            p2 += 2; // skip minAnte, maxAnte
            int numItems = q[p2++];
            int cnt = 0;
            for (int k = 0; k < numItems; k++) {
                p2++; // skip itemId
                if (j2 < MAX_CRIT && critSat[j2]) cnt++;
                j2++;
            }
            if (cnt < N) groupOk = false;
        }
        if (numClauses > 0 && groupOk) match = true;
    }

    return match ? 1 : 0;
}
