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
// A joker counts as found in ante [lo,hi] if it appears via any shop route:
//   - a shop item slot (incl. reroll slots; see SHOP_SLOTS_PER_VIEW),
//   - a Buffoon pack in the shop (non-legendary jokers),
//   - The Soul in a shop Arcana/Spectral pack (legendary jokers only -- they
//     never appear among shop items or in Buffoon packs).
// Tag-granted packs are intentionally excluded; shop packs only.
//
// Each item is flattened to an (item, lo, hi) criterion carrying its clause's
// window, satisfied by forward ante passes (the rng cache makes the reads
// deterministic regardless of call order), then the structure is re-walked in
// identical order to combine the per-item flags.
#define FILTER_USES_QUERY
#include "lib/immolate.cl"

// Joker slots a single shop view shows (Balatro: shop.joker_max). Every shop
// visit and every reroll redraws this many from the ante's shop stream.
#define SHOP_SLOTS_PER_VIEW 2
#define MAX_CRIT 64 // cap on total items across the whole query

// Shop visits per ante. Ante 1 opens on the Small Blind, so only the post-Small
// and post-Big shops fall inside it (the post-Boss shop rolls into ante 2's
// stream) => 2. Ante >=2 opens on a shop => 3. Each visit shows 2 jokers and 2
// booster packs, so this also drives the pack count (4 in ante 1, 6 after).
inline int shop_visits(int ante) { return ante == 1 ? 2 : 3; }

// A legendary joker only reaches the shop via The Soul (a spectral card) inside
// a shop Arcana/Spectral pack -- so the normal shop-item scan can never match
// one. They sit between the J_L_BEGIN/J_L_END enum sentinels.
inline bool is_legendary(int it) { return it > J_L_BEGIN && it < J_L_END; }

long filter(instance* inst, __global int* q, int qlen) {
    int critItem[MAX_CRIT];
    int critLo[MAX_CRIT];
    int critHi[MAX_CRIT];
    bool critSat[MAX_CRIT];
    int nCrit = 0;
    int maxAnte = 0;
    bool hasLegendary = false;    // any legendary criterion -> scan Arcana/Spectral Souls
    bool hasNonLegendary = false; // any normal criterion   -> scan Buffoon packs

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
                    if (is_legendary(it)) hasLegendary = true;
                    else hasNonLegendary = true;
                    nCrit++;
                }
            }
        }
    }

    // Mark every criterion satisfied by item `it` drawn in `ante`.
    // unroll 1: nCrit is a small runtime count; never duplicate this body.
    #define MARK_ITEM(it, ante)                                              \
        _Pragma("unroll 1")                                                  \
        for (int j = 0; j < nCrit; j++) {                                    \
            if (critItem[j] == (it) && (ante) >= critLo[j] && (ante) <= critHi[j]) \
                critSat[j] = true;                                           \
        }
    // True iff some criterion's window covers `ante`. An uncovered ante can't
    // satisfy anything, so we skip its (expensive) generation -- safe because
    // each ante's shop/pack RNG is an independent per-ante stream.
    #define ANTE_COVERED(ante, out)                                          \
        out = false;                                                         \
        for (int j = 0; j < nCrit; j++)                                      \
            if ((ante) >= critLo[j] && (ante) <= critHi[j]) { out = true; break; }

    // Forward pass A: shop item slots. Ante N draws from shop_visits(N) shop
    // views plus (N-1) rerolls (heuristic; ante 1 has no rerolls). Each view and
    // reroll redraws SHOP_SLOTS_PER_VIEW jokers, all from the ante's continuous
    // shop stream -- so only the total draw count matters. Reading the queue
    // forward this way mirrors the player rerolling through ante N's shops.
    for (int ante = 1; ante <= maxAnte; ante++) {
        bool covered; ANTE_COVERED(ante, covered);
        if (!covered) continue;
        int views = shop_visits(ante) + (ante - 1);
        int shopDraws = SHOP_SLOTS_PER_VIEW * views;
        // unroll 1: the body inlines next_shop_item (every shop generator);
        // duplicating it per slot is what blew the kernel up to 3.3MB / ~10min.
        #pragma unroll 1
        for (int slot = 0; slot < shopDraws; slot++) {
            int it = next_shop_item(inst, ante).value;
            MARK_ITEM(it, ante);
        }
    }

    // Forward pass B: shop booster packs per ante. Each shop view shows 2 packs
    // (=> 4 in ante 1, 6 after). Packs can't be rerolled, so unlike pass A there
    // is no reroll term -- the count is just 2 per shop_visits(ante).
    //   - Buffoon pack  -> its jokers satisfy non-legendary criteria.
    //   - Arcana/Spectral pack -> each Soul draws the next legendary from that
    //     ante's Soul queue (N Souls -> N successive legendaries, as in-game),
    //     the only route by which a legendary reaches the shop.
    if (hasNonLegendary || hasLegendary) {
        for (int ante = 1; ante <= maxAnte; ante++) {
            bool covered; ANTE_COVERED(ante, covered);
            int numPacks = 2 * shop_visits(ante);
            // unroll 1: the body inlines buffoon/arcana/spectral generators;
            // keep a single copy rather than one per pack slot.
            #pragma unroll 1
            for (int pk = 0; pk < numPacks; pk++) {
                // Always advance the pack queue (preserves the one-shot
                // "first pack is a Buffoon" state), but only generate/inspect
                // pack contents for antes a criterion actually covers.
                pack pinfo = pack_info(next_pack(inst, ante));
                if (!covered) continue;
                item cards[5];
                if (hasNonLegendary && pinfo.type == Buffoon_Pack) {
                    buffoon_pack(cards, pinfo.size, inst, ante);
                    #pragma unroll 1
                    for (int c = 0; c < pinfo.size; c++) MARK_ITEM(cards[c], ante);
                } else if (hasLegendary && pinfo.type == Arcana_Pack) {
                    arcana_pack(cards, pinfo.size, inst, ante);
                    #pragma unroll 1
                    for (int c = 0; c < pinfo.size; c++) {
                        if (cards[c] != The_Soul) continue;
                        int leg = next_joker(inst, S_Soul, ante);
                        MARK_ITEM(leg, ante);
                    }
                } else if (hasLegendary && pinfo.type == Spectral_Pack) {
                    spectral_pack(cards, pinfo.size, inst, ante);
                    #pragma unroll 1
                    for (int c = 0; c < pinfo.size; c++) {
                        if (cards[c] != The_Soul) continue;
                        int leg = next_joker(inst, S_Soul, ante);
                        MARK_ITEM(leg, ante);
                    }
                }
            }
        }
    }
    #undef MARK_ITEM
    #undef ANTE_COVERED

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
