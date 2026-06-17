#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#ifdef _WIN32
    #include <windows.h>
    #define PATH_SEPARATOR "\\"
#else
    // Define undefined MAX_PATH in Linux
    #define MAX_PATH (1024)
    #define PATH_SEPARATOR "/"

    #include <unistd.h>
    #include <libgen.h>
    #include <dirent.h>

    /* Use unsafe not _s functions
     * An alternative is using safeclib implementation with the following:
     *
     * #define __STDC_WANT_LIB_EXT1__ 1
     * #include <safeclib/safe_str_lib.h>
     * 
     * Unfortunately, the strcat_s and strcpy_s do not work for malloced strings
     */
    #define strcat_s(a,b,c) strcat(a,c)
    #define strcpy_s(a,b,c) strcpy(a,c)
    #define printf_s(...) printf(__VA_ARGS__)
    #define fprintf_s(...) fprintf(__VA_ARGS__)
#endif
#include <limits.h>
#include <string.h>
#include <CL/cl.h>
#define MAX_CODE_SIZE (1000000)

void clErrCheck(cl_int err, char* msg) {
    if (err != CL_SUCCESS) {
        printf_s("Fatal CL Error %d when trying to execute %s\n", err, msg);
        exit(EXIT_FAILURE);
    }
}

// Case-insensitive substring test (ASCII). Avoids a <ctype.h> dependency.
int str_contains_ci(const char* hay, const char* needle) {
    if (!hay || !needle) return 0;
    size_t nl = strlen(needle);
    if (nl == 0) return 1;
    for (const char* h = hay; *h; h++) {
        size_t k = 0;
        while (k < nl) {
            char a = h[k], b = needle[k];
            if (a >= 'A' && a <= 'Z') a += 32;
            if (b >= 'A' && b <= 'Z') b += 32;
            if (a != b) break;
            k++;
        }
        if (k == nl) return 1;
    }
    return 0;
}

// Heuristic preference score for auto device selection (higher = better):
//   - real GPUs beat CPUs and accelerators (+GPU_BONUS),
//   - discrete GPUs beat integrated ones (+DISCRETE_BONUS): on laptops the
//     Intel iGPU otherwise wins the cu*mhz tie-break despite the NVIDIA/AMD
//     dGPU being far faster. "Integrated" = shares host memory
//     (CL_DEVICE_HOST_UNIFIED_MEMORY) or carries a known iGPU name marker.
//   - known software/emulation layers (OpenCLOn12, Microsoft Basic Render,
//     llvmpipe, Oclgrind) are demoted below real hardware (-SOFT_PENALTY),
//   - ties broken by compute_units * clock as a rough throughput proxy.
// DISCRETE_BONUS exceeds any plausible iGPU cu*mhz, so a dGPU always wins when
// both are present. Demotion exceeds the GPU/discrete bonuses, so e.g. Windows'
// OpenCLOn12 (a GPU-typed software layer) loses to any real device while still
// winning if it is the only device present.
// Deprecated in OpenCL 2.0, so omitted from headers at higher CL targets, but
// every driver still answers the query. Stable value; define it if absent.
#ifndef CL_DEVICE_HOST_UNIFIED_MEMORY
#define CL_DEVICE_HOST_UNIFIED_MEMORY 0x1035
#endif
cl_long scoreDevice(cl_device_id dev) {
    cl_device_type type = 0;
    char name[1024] = {0}, vendor[1024] = {0};
    cl_uint cu = 0, mhz = 0;
    cl_bool unified = CL_FALSE;
    clGetDeviceInfo(dev, CL_DEVICE_TYPE, sizeof type, &type, NULL);
    clGetDeviceInfo(dev, CL_DEVICE_NAME, sizeof name, name, NULL);
    clGetDeviceInfo(dev, CL_DEVICE_VENDOR, sizeof vendor, vendor, NULL);
    clGetDeviceInfo(dev, CL_DEVICE_MAX_COMPUTE_UNITS, sizeof cu, &cu, NULL);
    clGetDeviceInfo(dev, CL_DEVICE_MAX_CLOCK_FREQUENCY, sizeof mhz, &mhz, NULL);
    clGetDeviceInfo(dev, CL_DEVICE_HOST_UNIFIED_MEMORY, sizeof unified, &unified, NULL);

    const cl_long GPU_BONUS = 1000000000LL;
    const cl_long DISCRETE_BONUS = 4000000000LL;
    const cl_long SOFT_PENALTY = 8000000000LL;
    cl_long score = (cl_long)cu * (cl_long)mhz;
    if (type & CL_DEVICE_TYPE_GPU) score += GPU_BONUS;

    // Integrated GPUs share host memory; the name markers catch drivers that
    // misreport unified memory (Intel HD/UHD/Iris, "Integrated").
    const char* igpu[] = {"Iris", "UHD Graphics", "HD Graphics", "Integrated"};
    int integrated = unified;
    for (size_t i = 0; i < sizeof igpu / sizeof igpu[0]; i++) {
        if (str_contains_ci(name, igpu[i])) { integrated = 1; break; }
    }
    if ((type & CL_DEVICE_TYPE_GPU) && !integrated) score += DISCRETE_BONUS;

    const char* software[] = {"OpenCLOn12", "clon12", "Basic Render",
                              "Microsoft", "llvmpipe", "Oclgrind"};
    for (size_t i = 0; i < sizeof software / sizeof software[0]; i++) {
        if (str_contains_ci(name, software[i]) || str_contains_ci(vendor, software[i])) {
            score -= SOFT_PENALTY;
            break;
        }
    }
    return score;
}

// Auto-select the best (platform, device) across all OpenCL platforms using
// scoreDevice. Writes the winners to outPlatform/outDevice.
// Returns 1 on success, 0 if no device was found (caller keeps its defaults).
int pickBestDevice(unsigned int* outPlatform, unsigned int* outDevice) {
    cl_uint numPlatforms = 0;
    if (clGetPlatformIDs(0, NULL, &numPlatforms) != CL_SUCCESS || numPlatforms == 0)
        return 0;
    cl_platform_id* platforms = malloc(sizeof(cl_platform_id) * numPlatforms);
    if (clGetPlatformIDs(numPlatforms, platforms, NULL) != CL_SUCCESS) {
        free(platforms);
        return 0;
    }

    int found = 0;
    cl_long best = 0;
    for (cl_uint p = 0; p < numPlatforms; p++) {
        cl_uint numDevices = 0;
        if (clGetDeviceIDs(platforms[p], CL_DEVICE_TYPE_ALL, 0, NULL, &numDevices) != CL_SUCCESS
            || numDevices == 0)
            continue;
        cl_device_id* devices = malloc(sizeof(cl_device_id) * numDevices);
        if (clGetDeviceIDs(platforms[p], CL_DEVICE_TYPE_ALL, numDevices, devices, NULL) != CL_SUCCESS) {
            free(devices);
            continue;
        }
        for (cl_uint d = 0; d < numDevices; d++) {
            cl_long s = scoreDevice(devices[d]);
            if (!found || s > best) {
                best = s;
                *outPlatform = p;
                *outDevice = d;
                found = 1;
            }
        }
        free(devices);
    }
    free(platforms);
    return found;
}

// ---- Program-binary cache -------------------------------------------------
// The kernel is ~6k lines of OpenCL that the driver JIT-compiles on every run
// (clBuildProgram). Caching the compiled binary keyed on (source + included
// files + device + driver) turns subsequent launches into a near-instant load.

#define FNV_OFFSET 14695981039346656037ULL
#define FNV_PRIME  1099511628211ULL

void fnvUpdate(cl_ulong* h, const void* data, size_t n) {
    const unsigned char* p = (const unsigned char*)data;
    for (size_t i = 0; i < n; i++) { *h ^= p[i]; *h *= FNV_PRIME; }
}

// Fold a whole file's bytes into the running hash. Missing file => no-op.
void hashFileInto(cl_ulong* h, const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return;
    unsigned char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) fnvUpdate(h, buf, n);
    fclose(f);
}

int hasClExt(const char* name) {
    size_t n = strlen(name);
    return (n >= 3 && strcmp(name + n - 3, ".cl") == 0) ||
           (n >= 2 && strcmp(name + n - 2, ".h") == 0);
}

// Fold every *.cl/*.h file (name + contents) in a directory into the hash, so
// edits to includes invalidate the cache. Non-recursive (lib/ and filters/ are
// flat); missing directory => no-op.
void hashDirInto(cl_ulong* h, const char* dir) {
    char path[MAX_PATH * 2];
#ifdef _WIN32
    char pattern[MAX_PATH * 2];
    snprintf(pattern, sizeof pattern, "%s%s*", dir, PATH_SEPARATOR);
    WIN32_FIND_DATA fd;
    HANDLE hf = FindFirstFile(pattern, &fd);
    if (hf == INVALID_HANDLE_VALUE) return;
    do {
        if (!hasClExt(fd.cFileName)) continue;
        fnvUpdate(h, fd.cFileName, strlen(fd.cFileName));
        snprintf(path, sizeof path, "%s%s%s", dir, PATH_SEPARATOR, fd.cFileName);
        hashFileInto(h, path);
    } while (FindNextFile(hf, &fd));
    FindClose(hf);
#else
    DIR* dp = opendir(dir);
    if (!dp) return;
    struct dirent* e;
    while ((e = readdir(dp)) != NULL) {
        if (!hasClExt(e->d_name)) continue;
        fnvUpdate(h, e->d_name, strlen(e->d_name));
        snprintf(path, sizeof path, "%s%s%s", dir, PATH_SEPARATOR, e->d_name);
        hashFileInto(h, path);
    }
    closedir(dp);
#endif
}

// A cached binary is only valid for the exact device + driver it was built for.
void deviceFingerprintInto(cl_ulong* h, cl_device_id device) {
    char buf[1024];
    const cl_device_info fields[] = {CL_DEVICE_NAME, CL_DEVICE_VENDOR,
                                     CL_DEVICE_VERSION, CL_DRIVER_VERSION};
    for (size_t i = 0; i < sizeof fields / sizeof fields[0]; i++) {
        size_t got = 0;
        if (clGetDeviceInfo(device, fields[i], sizeof buf, buf, &got) == CL_SUCCESS && got > 0)
            fnvUpdate(h, buf, got);
    }
}

// Build the OpenCL program, using the on-disk binary cache when possible.
// Falls back to a source compile (and repopulates the cache) on any miss,
// load error, or stale binary. Exits via clErrCheck on a genuine build failure.
cl_program buildProgramCached(cl_context ctx, cl_device_id device, char* source,
                              size_t sourceLen, const char* options,
                              const char* executable_dir, cl_int quiet) {
    cl_int err;

    // Cache key: source + included files (lib/, filters/) + build options + device.
    cl_ulong key = FNV_OFFSET;
    fnvUpdate(&key, source, sourceLen);
    if (options) fnvUpdate(&key, options, strlen(options));
    char dirBuf[MAX_PATH * 2];
    snprintf(dirBuf, sizeof dirBuf, "%s%slib", executable_dir, PATH_SEPARATOR);
    hashDirInto(&key, dirBuf);
    snprintf(dirBuf, sizeof dirBuf, "%s%sfilters", executable_dir, PATH_SEPARATOR);
    hashDirInto(&key, dirBuf);
    deviceFingerprintInto(&key, device);

    char cachePath[MAX_PATH * 2];
    snprintf(cachePath, sizeof cachePath, "%s%simmolate_%016llx.clbin",
             executable_dir, PATH_SEPARATOR, (unsigned long long)key);

    // Try the cache.
    FILE* cf = fopen(cachePath, "rb");
    if (cf) {
        fseek(cf, 0, SEEK_END);
        long sz = ftell(cf);
        fseek(cf, 0, SEEK_SET);
        if (sz > 0) {
            unsigned char* bin = malloc(sz);
            size_t rd = fread(bin, 1, sz, cf);
            fclose(cf);
            if (rd == (size_t)sz) {
                size_t binSize = sz;
                cl_int binStatus;
                cl_program prog = clCreateProgramWithBinary(
                    ctx, 1, &device, &binSize, (const unsigned char**)&bin, &binStatus, &err);
                if (err == CL_SUCCESS && binStatus == CL_SUCCESS &&
                    clBuildProgram(prog, 1, &device, options, NULL, NULL) == CL_SUCCESS) {
                    free(bin);
                    if (!quiet) printf_s("Loaded cached program.\n");
                    return prog;
                }
                if (prog) clReleaseProgram(prog);
            }
            free(bin);
        } else {
            fclose(cf);
        }
        // Any failure here: fall through and rebuild from source.
    }

    // Cache miss / stale: compile from source.
    cl_program prog = clCreateProgramWithSource(ctx, 1, (const char**)&source,
                                                (const size_t*)&sourceLen, &err);
    clErrCheck(err, "clCreateProgramWithSource - Creating OpenCL program");
    if (!quiet) printf_s("Building program...\n");
    err = clBuildProgram(prog, 1, &device, options, NULL, NULL);
    if (err == CL_BUILD_PROGRAM_FAILURE) { // print build log on error
        size_t logLength = 0;
        clGetProgramBuildInfo(prog, device, CL_PROGRAM_BUILD_LOG, 0, NULL, &logLength);
        char* buf = calloc(logLength, sizeof(char));
        clGetProgramBuildInfo(prog, device, CL_PROGRAM_BUILD_LOG, logLength, buf, NULL);
        printf_s("%s\n", buf);
        free(buf);
    }
    clErrCheck(err, "clBuildProgram - Building OpenCL program");

    // Repopulate the cache (best-effort: ignore write failures, e.g. read-only dir).
    size_t binSize = 0;
    if (clGetProgramInfo(prog, CL_PROGRAM_BINARY_SIZES, sizeof binSize, &binSize, NULL) == CL_SUCCESS
        && binSize > 0) {
        unsigned char* bin = malloc(binSize);
        unsigned char* binPtr = bin;
        if (clGetProgramInfo(prog, CL_PROGRAM_BINARIES, sizeof binPtr, &binPtr, NULL) == CL_SUCCESS) {
            FILE* wf = fopen(cachePath, "wb");
            if (wf) {
                fwrite(bin, 1, binSize, wf);
                fclose(wf);
                if (!quiet) printf_s("Cached compiled program.\n");
            }
        }
        free(bin);
    }
    return prog;
}

void getExecutableDir(char *dir) {
    #ifdef _WIN32
        // Windows specific code
         if (GetModuleFileName(NULL, dir, MAX_PATH) != 0) {
            char* last_slash = strrchr(dir, '\\');
            if (last_slash != NULL) {
                *last_slash = '\0';
            }
        } else {
            fprintf(stderr, "Error: Unable to get the current working directory\n");
        }
    #elif __linux__
        // Linux specific code
        ssize_t len = readlink("/proc/self/exe", dir, (size_t)(MAX_PATH - 1));
        if (len != -1) {
            dir[len] = '\0';
            char* last_slash = strrchr(dir, '/');
            if (last_slash != NULL) {
                *last_slash = '\0';
            }
        } else {
            fprintf(stderr, "Error: Unable to get the current working directory\n");
            // exit(EXIT_FAILURE);
        }
    #else
        #error Platform not supported
    #endif
}