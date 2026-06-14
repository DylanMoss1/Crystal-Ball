#include "lib/immolate.h"
#include "query_parse.h"
#include <time.h>
int main(int argc, char **argv) {
    
    // Detect quiet mode early so even the banner can be suppressed. In quiet
    // mode the only stdout is the matching seed(s); see -q below.
    cl_int quiet = 0;
    for (int qi = 0; qi < argc; qi++) {
        if (strcmp(argv[qi], "-q") == 0) quiet = 1;
    }

    // Print version
    if (!quiet) printf_s("Immolate Beta v1.0.1f.1\n");

    // Handle CLI arguments
    unsigned int platformID = 0;
    unsigned int deviceID = 0;
    cl_int platformSet = 0; // whether -p/-d were given explicitly; if not, auto-select.
    cl_int deviceSet = 0;
    // When -g is given, globalSize = numGroups^2 work-items. When it is NOT given, the
    // work-item count is auto-sized to the device's compute units (see below) so it is
    // optimal on any GPU -- a fixed default can't be: a big globalSize starves a slow GPU
    // (TDR-bounded chunks can't fill it) and a small one under-occupies a fast one.
    unsigned int numGroups = 64;
    cl_int groupsSet = 0;
    cl_char8 startingSeed;
    for (int i = 0; i < 8; i++) {
        startingSeed.s[i] = '\0';
    };
    cl_long numSeeds = 2318107019761;
    cl_long cutoff = 1;
    char* filter = "erratic_flush_five";
    char* queryJson = NULL;
    cl_int stopOnFirst = 0;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "-h")==0) {
            printf_s("Valid command line arguments:\n-h        Shows this help dialog.\n-f <F>    Sets the filter used by Immolate to F. Defaults to erratic_flush_five.\n-j <J>    Passes a JSON search query to a query-aware filter (e.g. find_joker). See README.\n-J <F>    Like -j, but reads the JSON query from file F (avoids shell-quoting the query).\n--first   Stops the search as soon as one matching seed is found (prints exactly one).\n-q        Quiet mode: suppress all output except matching seeds (prints just <SEED>).\n-s <S>    Sets the starting seed to S. Defaults to empty seed. Use \"random\" for a random starting seed.\n-n <N>    Sets the number of seeds to search to N. Defaults to full seed pool.\n-c <C>    Sets the cutoff score for a seed to be printed to C. Defaults to 1.\n-p <P>    Sets the platform ID of the CL device being used to P. Defaults to 0.\n-d <D>    Sets the device ID of the CL device being used to D. Defaults to 0.\n-g <G>    Sets the number of thread groups to G (globalSize = G*G work-items). Default: auto-sized to the GPU's compute units. Override only to tune.\n\n--list_devices   Lists information about the detected CL devices.");
            return 0;
        }
        if (strcmp(argv[i],  "-p")==0) {
            platformID = atoi(argv[i+1]);
            platformSet = 1;
            i++;
        }
        if (strcmp(argv[i],  "-f")==0) {
            filter = argv[i+1];
            i++;
        }
        if (strcmp(argv[i],  "-j")==0) {
            queryJson = argv[i+1];
            i++;
        }
        if (strcmp(argv[i],  "-J")==0) {
            // Read the JSON query from a file instead of argv. Lets callers that
            // invoke Immolate through a shell (e.g. the Windows mod's io.popen)
            // avoid escaping the query's quotes/braces on the command line.
            FILE* qf = fopen(argv[i+1], "rb");
            if (qf) {
                fseek(qf, 0, SEEK_END);
                long qn = ftell(qf);
                fseek(qf, 0, SEEK_SET);
                char* qbuf = malloc(qn + 1);
                size_t rd = fread(qbuf, 1, qn, qf);
                qbuf[rd] = '\0';
                fclose(qf);
                queryJson = qbuf;
            } else {
                printf_s("Warning: could not open query file '%s', ignoring...\n", argv[i+1]);
            }
            i++;
        }
        if (strcmp(argv[i],  "--first")==0) {
            stopOnFirst = 1;
        }
        if (strcmp(argv[i],  "-d")==0) {
            deviceID = atoi(argv[i+1]);
            deviceSet = 1;
            i++;
        }
        if (strcmp(argv[i],  "-g")==0) {
            numGroups = atoi(argv[i+1]);
            groupsSet = 1;
            i++;
        }
        if (strcmp(argv[i],  "-n")==0) {
            numSeeds = strtoll(argv[i+1], NULL, 10);
            i++;
        }
        if (strcmp(argv[i],  "-c")==0) {
            cutoff = strtoll(argv[i+1], NULL, 10);
            i++;
        }
        if (strcmp(argv[i],  "-s")==0) {
            if (strcmp(argv[i+1],"random")==0) {
                srand(time(NULL));
                char seedCharacters[] = {'1','2','3','4','5','6','7','8','9','A','B','C','D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z'};
                for (int j = 0; j < 8; j++) {
                    startingSeed.s[j] = seedCharacters[rand() % 35];
                }
            } else if (strlen(argv[i+1]) <= 8) {
                for (int j = 0; j < strlen(argv[i+1]); j++) {
                    startingSeed.s[j] = argv[i+1][j];
                }
                for (int j = strlen(argv[i+1]); j < 8; j++) {
                    startingSeed.s[j] = '\0';
                }
            } else {
                printf_s("Warning: Inputted seed is not valid, ignoring...\n");
            }
            i++;
        }
        if (strcmp(argv[i],  "--list_devices")==0) {
            cl_int err;
            char buf[1024];
            cl_uint temp_int;
            
            // Get # of OpenCL Platforms
            cl_uint numPlatforms;
            err = clGetPlatformIDs(0, NULL, &numPlatforms);
            clErrCheck(err, "clGetPlatformIDs - Getting number of available OpenCL platforms");

            // Nothing available? Then leave!
            if (numPlatforms == 0) {
                printf_s("No OpenCL devices found.\n");
                return 0;
            }

            // Now get OpenCL Platforms
            cl_platform_id* platforms = malloc(sizeof(cl_platform_id) * numPlatforms);

            err = clGetPlatformIDs(numPlatforms, platforms, NULL);
            clErrCheck(err, "clGetPlatformIDs - Getting list of availble OpenCL platforms");

            int foundDevice = 0;
            for (unsigned int p = 0; p < numPlatforms; p++) {
                //Now we do the same thing for devices...
                cl_uint numDevices;
                err = clGetDeviceIDs(platforms[p], CL_DEVICE_TYPE_ALL, 0, NULL, &numDevices);
                clErrCheck(err, "clGetDeviceIDs - Getting number of available OpenCL devices");

                if (numDevices > 0) foundDevice = 1;

                cl_device_id* devices = malloc(sizeof(cl_device_id) * numDevices);
                err = clGetDeviceIDs(platforms[p], CL_DEVICE_TYPE_ALL, numDevices, devices, NULL);
                clErrCheck(err, "clGetDeviceIDs - Getting list of available OpenCL devices");

                for (unsigned int d = 0; d < numDevices; d++) {
                    printf_s("Platform ID %i, Device ID %i\n", p, d);

                    // Get Device Info
                    err = clGetDeviceInfo(devices[d], CL_DEVICE_NAME, sizeof(buf), &buf, NULL);
                    clErrCheck(err, "clGetDeviceInfo - Getting device name");
                    printf_s("Name: %s\n", buf);
                    
                    err = clGetDeviceInfo(devices[d], CL_DEVICE_VENDOR, sizeof(buf), &buf, NULL);
                    clErrCheck(err, "clGetDeviceInfo - Getting device vendor");
                    printf_s("Vendor: %s\n", buf);
                    
                    err = clGetDeviceInfo(devices[d], CL_DEVICE_MAX_COMPUTE_UNITS, sizeof(temp_int), &temp_int, NULL);
                    clErrCheck(err, "clGetDeviceInfo - Getting device compute units");
                    printf_s("Compute Units: %i\n", temp_int);
                    
                    err = clGetDeviceInfo(devices[d], CL_DEVICE_MAX_CLOCK_FREQUENCY, sizeof(temp_int), &temp_int, NULL);
                    clErrCheck(err, "clGetDeviceInfo - Getting device clock frequency");
                    printf_s("Clock Frequency: %iMHz\n", temp_int);
                }
            }
            if (foundDevice == 0) {
                printf_s("No OpenCL devices found.\n");
            }
            return 0;
        }
    }
    cl_int err;

    // Load the kernel source code into the array ssKernel
    FILE *fp;
    char *ssKernelCode;
    char *ssKernelBuf;
    size_t ssKernelSize;

    // Get CWD
    char executable_dir[MAX_PATH];
    char include_path[MAX_PATH+6];
    char kernel_path[MAX_PATH+12];
    getExecutableDir(executable_dir);
    strcpy_s(include_path, sizeof include_path, "-I \"");
    strcat_s(include_path, sizeof include_path, executable_dir);
    strcat_s(include_path, sizeof include_path, "\"");
    strcpy_s(kernel_path, sizeof kernel_path, executable_dir);
    strcat_s(kernel_path, sizeof kernel_path, PATH_SEPARATOR);
    strcat_s(kernel_path, sizeof kernel_path, "search.cl");
    fp = fopen(kernel_path, "r");
    if (!fp) {
        printf_s("Warning: Kernel not found at ");
        printf_s("%s", kernel_path);
        printf_s(", attempting working directory...\n");
        fp = fopen("search.cl","r");
        if (!fp) {
            fprintf_s(stderr, "Failed to load kernel.\n");
            exit(1);
        }
    }
    ssKernelCode = (char*)malloc(MAX_CODE_SIZE);
    ssKernelBuf = (char*)malloc(MAX_CODE_SIZE);
    // Set include information
    strcpy_s(ssKernelCode, MAX_CODE_SIZE, "#include \"filters/");
    strcat_s(ssKernelCode, MAX_CODE_SIZE, filter);
    strcat_s(ssKernelCode, MAX_CODE_SIZE, ".cl\"\n\n");
    size_t bytes_read = fread( ssKernelBuf, 1, MAX_CODE_SIZE - 1, fp);
    ssKernelBuf[bytes_read] = '\0';
    strcat_s(ssKernelCode, MAX_CODE_SIZE, ssKernelBuf);
    ssKernelSize = strlen(ssKernelCode);
    fclose( fp );
    free(ssKernelBuf);

    // Set up platform and device based on CLI args

    // No explicit -p/-d? Auto-select the best device (real GPU over CPU/software
    // layers like Windows' OpenCLOn12), so users need not know their device IDs.
    if (!platformSet && !deviceSet) {
        unsigned int bestPlatform, bestDevice;
        if (pickBestDevice(&bestPlatform, &bestDevice)) {
            platformID = bestPlatform;
            deviceID = bestDevice;
            if (!quiet) printf_s("Auto-selected platform %u, device %u\n", platformID, deviceID);
        }
    }

    // Get # of OpenCL Platforms
    cl_uint numPlatforms;
    err = clGetPlatformIDs(0, NULL, &numPlatforms);
    clErrCheck(err, "clGetPlatformIDs - Getting number of available OpenCL platforms");

    // Nothing available? Then leave!
    if (numPlatforms == 0) {
        printf_s("No OpenCL platforms found.\n");
        return 0;
    }
    if (platformID > numPlatforms-1) {
        printf_s("Platform ID %i not found.\n", platformID);
        return 0;
    }

    // Now get OpenCL Platforms
    cl_platform_id* platforms = malloc(sizeof(cl_platform_id) * numPlatforms);

    err = clGetPlatformIDs(numPlatforms, platforms, NULL);
    clErrCheck(err, "clGetPlatformIDs - Getting list of availble OpenCL platforms");
    cl_platform_id platform = platforms[platformID];
    
    //Now we do the same thing for devices...
    cl_uint numDevices;
    err = clGetDeviceIDs(platform, CL_DEVICE_TYPE_ALL, 0, NULL, &numDevices);
    clErrCheck(err, "clGetDeviceIDs - Getting number of available OpenCL devices");

    if (numDevices == 0) {
        printf_s("No OpenCL devices found for platform %i.\n", platformID);
        return 0;
    }
    if (deviceID > numDevices-1) {
        printf_s("Device ID %i not found.\n", deviceID);
        return 0;
    }

    cl_device_id* devices = malloc(sizeof(cl_device_id) * numDevices);
    err = clGetDeviceIDs(platform, CL_DEVICE_TYPE_ALL, numDevices, devices, NULL);
    clErrCheck(err, "clGetDeviceIDs - Getting list of available OpenCL devices");
    cl_device_id device = devices[deviceID];

    // Create an OpenCL context
    cl_context ctx = clCreateContext(NULL, 1, &device, NULL, NULL, &err);
    clErrCheck(err, "clCreateContext - Creating OpenCL context");
 
    // Create a command queue. Profiling is enabled so the chunked search loop can
    // measure each launch's kernel time and size the next chunk to a TDR-safe target.
    cl_command_queue queue = clCreateCommandQueue(ctx, device, CL_QUEUE_PROFILING_ENABLE, &err);
    clErrCheck(err, "clCreateCommandQueue - Creating OpenCL command queue");

    // Create + build the program, served from the on-disk binary cache when the
    // source, includes, device and driver all match (see buildProgramCached).
    cl_program ssKernelProgram = buildProgramCached(ctx, device, ssKernelCode, ssKernelSize, include_path, executable_dir, quiet);

    // Create OpenCL kernel
    cl_kernel ssKernel = clCreateKernel(ssKernelProgram, "search", &err);
    clErrCheck(err, "clCreateKernel - Creating OpenCL kernel");

    // Set arguments
    err = clSetKernelArg(ssKernel, 0, sizeof(startingSeed), &startingSeed);
    clErrCheck(err, "clSetKernelArg - Adding starting seed argument");
    err = clSetKernelArg(ssKernel, 1, sizeof(numSeeds), &numSeeds);
    clErrCheck(err, "clSetKernelArg - Adding number of seeds argument");
    // Loading a writable buffer to the kernel
    cl_mem cutoffBuf = clCreateBuffer(ctx, CL_MEM_READ_WRITE, sizeof(long), NULL, &err);
    clErrCheck(err, "clCreateBuffer - Creating cutoff buffer");
    clEnqueueWriteBuffer(queue, cutoffBuf, CL_TRUE, 0, sizeof(long), &cutoff, 0, NULL, NULL);
    err = clSetKernelArg(ssKernel, 2, sizeof(cl_mem), &cutoffBuf);
    clErrCheck(err, "clSetKernelArg - Adding cutoff argument");

    // Build the structured query buffer (empty when -j is absent: numGroups=0,
    // so query-aware filters match nothing). Args are always set since the
    // kernel signature always declares them.
    int emptyQuery[1] = {0};
    int* queryData = emptyQuery;
    int queryLen = 1;
    if (queryJson != NULL) {
        queryData = build_query_buffer(queryJson, &queryLen);
        if (queryData == NULL) {
            fprintf_s(stderr, "Failed to parse -j query JSON.\n");
            return EXIT_FAILURE;
        }
    }
    cl_mem queryBuf = clCreateBuffer(ctx, CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR, sizeof(int) * queryLen, queryData, &err);
    clErrCheck(err, "clCreateBuffer - Creating query buffer");
    err = clSetKernelArg(ssKernel, 3, sizeof(cl_mem), &queryBuf);
    clErrCheck(err, "clSetKernelArg - Adding query argument");
    err = clSetKernelArg(ssKernel, 4, sizeof(int), &queryLen);
    clErrCheck(err, "clSetKernelArg - Adding query length argument");
    if (queryData != emptyQuery) free(queryData);

    // Early-exit flag: work-items poll this and bail once a match is claimed.
    cl_int stopInit = 0;
    cl_mem stopBuf = clCreateBuffer(ctx, CL_MEM_READ_WRITE, sizeof(cl_int), NULL, &err);
    clErrCheck(err, "clCreateBuffer - Creating stop buffer");
    clEnqueueWriteBuffer(queue, stopBuf, CL_TRUE, 0, sizeof(cl_int), &stopInit, 0, NULL, NULL);
    err = clSetKernelArg(ssKernel, 5, sizeof(cl_mem), &stopBuf);
    clErrCheck(err, "clSetKernelArg - Adding stop buffer argument");
    err = clSetKernelArg(ssKernel, 6, sizeof(cl_int), &stopOnFirst);
    clErrCheck(err, "clSetKernelArg - Adding stop-on-first argument");
    err = clSetKernelArg(ssKernel, 7, sizeof(cl_int), &quiet);
    clErrCheck(err, "clSetKernelArg - Adding quiet argument");

    // Work-item count (globalSize). Explicit -g => numGroups^2 (legacy knob). Otherwise
    // auto-size to the device: ~512 work-items per compute unit saturates the GPU without
    // overshooting (tuned on a 16-CU GTX 1650, which plateaus around 4k-8k work-items),
    // and it scales straight to high-end parts (e.g. an RTX 4090's ~128 CUs => ~64k). The
    // separate, time-bounded chunk loop below keeps each launch TDR-safe regardless.
    size_t globalSize;
    if (groupsSet) {
        globalSize = (size_t)numGroups * numGroups;
    } else {
        cl_uint computeUnits = 0;
        clGetDeviceInfo(device, CL_DEVICE_MAX_COMPUTE_UNITS, sizeof computeUnits, &computeUnits, NULL);
        if (computeUnits == 0) computeUnits = 8;
        globalSize = (size_t)computeUnits * 512;
        if (globalSize < 1024) globalSize = 1024;
    }
    // localSize NULL: let the driver pick the work-group size (avoids exceeding the
    // kernel's max work-group size, and globalSize need not be a multiple of it). The
    // kernel strides by global size, so correctness does not depend on the local size.
    if (!quiet) printf_s("Starting searcher (%zu work-items)...\n", globalSize);
    clock_t begin = clock();

    // Chunk sizes are ABSOLUTE seed counts (independent of globalSize), so a large
    // globalSize can't inflate a launch past the GPU watchdog. Start tiny (TDR-safe on
    // any GPU), then grow toward TARGET_NS, capped per step so a noisy first measurement
    // can't overshoot into a multi-second launch.
    const cl_ulong TARGET_NS = 200000000ULL; // ~0.2s/launch (<< a ~2s TDR)
    const cl_long INIT_CHUNK = 1 << 13;       // 8192: tiny first launch
    const cl_long MIN_CHUNK = 1 << 10;        // 1024
    const cl_long MAX_CHUNK = 1 << 28;        // ~268M ceiling per launch
    const double MAX_GROWTH = 8.0;            // at most 8x larger per launch
    cl_long chunk = INIT_CHUNK;
    cl_long offset = 0;
    cl_int stopFlag = 0;
    while (offset < numSeeds) {
        cl_long thisChunk = (numSeeds - offset < chunk) ? (numSeeds - offset) : chunk;
        err = clSetKernelArg(ssKernel, 1, sizeof(thisChunk), &thisChunk);
        clErrCheck(err, "clSetKernelArg - Setting chunk size");
        err = clSetKernelArg(ssKernel, 8, sizeof(offset), &offset);
        clErrCheck(err, "clSetKernelArg - Setting seed offset");

        cl_event ev;
        err = clEnqueueNDRangeKernel(queue, ssKernel, 1, NULL, &globalSize, NULL, 0, NULL, &ev);
        clErrCheck(err, "clEnqueueNDRangeKernel - Executing OpenCL kernel");
        clFinish(queue);
        offset += thisChunk;

        // Size the next chunk toward TARGET_NS from this launch's measured kernel time.
        cl_ulong t0 = 0, t1 = 0;
        clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_START, sizeof t0, &t0, NULL);
        clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_END, sizeof t1, &t1, NULL);
        clReleaseEvent(ev);
        if (t1 > t0) {
            double ideal = (double)thisChunk * (double)TARGET_NS / (double)(t1 - t0);
            double cap = (double)thisChunk * MAX_GROWTH;
            if (ideal > cap) ideal = cap;
            chunk = (cl_long)ideal;
            if (chunk < MIN_CHUNK) chunk = MIN_CHUNK;
            if (chunk > MAX_CHUNK) chunk = MAX_CHUNK;
        }

        // --first: stop the moment any chunk has claimed a match.
        if (stopOnFirst) {
            clEnqueueReadBuffer(queue, stopBuf, CL_TRUE, 0, sizeof(cl_int), &stopFlag, 0, NULL, NULL);
            if (stopFlag) break;
        }
    }

    // Clean up
    err = clFlush(queue);
    err = clFinish(queue);
    err = clReleaseKernel(ssKernel);
    err = clReleaseProgram(ssKernelProgram);
    err = clReleaseCommandQueue(queue);
    err = clReleaseContext(ctx);
    clock_t end = clock();
    double time_spent = (double)(end-begin) / CLOCKS_PER_SEC;
    if (!quiet) printf("Done in %fs",time_spent);

    return EXIT_SUCCESS;
}