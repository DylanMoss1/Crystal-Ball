#pragma OPENCL EXTENSION cl_khr_global_int32_base_atomics : enable

__kernel void search(char8 starting_seed, long num_seeds, __global long* filter_cutoff, __global int* query, int queryLen, volatile __global int* stop, int stopOnFirst, int quiet) {
    seed _seed = s_new_c8(starting_seed);
    s_skip(&_seed, get_global_id(0));
    for (long i = get_global_id(0); i < num_seeds; i+=get_global_size(0)) {
        // Early-exit: once any work-item has claimed the first match, every
        // other work-item bails here instead of scanning the rest of the pool.
        // Runtime-gated (not a macro) so toggling it needs no kernel rebuild.
        if (stopOnFirst && *stop) return;
        instance inst = i_new(_seed);
        // Query-aware filters opt in via FILTER_USES_QUERY (defined before this
        // file is included) to receive the query buffer. All other filters keep
        // the original single-argument signature untouched.
        #ifdef FILTER_USES_QUERY
            long score = filter(&inst, query, queryLen);
        #else
            long score = filter(&inst);
        #endif
        if (score >= filter_cutoff[0]) {
            if (stopOnFirst) {
                // Claim the single match: only the first work-item to flip the
                // flag prints, so exactly one seed is reported before we stop.
                // Single writer (the cmpxchg winner), so the per-character print in
                // s_print_line can't interleave -- safe to use the portable printer
                // that avoids printf("%s") (broken on some drivers; see s_print_line).
                if (atomic_cmpxchg(stop, 0, 1) == 0) {
                    s_print_line(&_seed, score, quiet);
                }
                return;
            }
            // Bulk mode: many work-items may print concurrently, so keep the single
            // printf per match (per-char would interleave). NB %s is unsupported on
            // some drivers -- prefer --first (above) there, or print host-side.
            text s_str = s_to_string(&_seed);
            if (quiet) printf("%s\n", s_str.str);
            else printf("%s (%li)\n", s_str.str, score);
            if (score > filter_cutoff[0]) {
                #ifndef FIXED_FILTER_CUTOFF
                    filter_cutoff[0] = score;
                    barrier(CLK_GLOBAL_MEM_FENCE);
                #endif
            }
        }
        s_skip(&_seed,get_global_size(0));
    }
}
