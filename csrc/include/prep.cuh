//
// Created by oja7 on 11/12/24.
//

#ifndef PREP_CUH
#define PREP_CUH

#include <cute/layout.hpp>
#include <nvshmemx.h>
#include <nvshmem.h>
#include <host/nvshmemx_api.h>

template<unsigned int bM=128, unsigned int bN=128, unsigned int bK=8, unsigned int bP=3>
__global__ void occupancyTestKernel(){
    __shared__ float sharedA[cute::cosize_v<decltype(cute::make_layout(cute::make_shape(cute::Int<bM>{}, cute::Int<bK>{}, cute::Int<bP>{})))>];
    __shared__ float sharedB[cute::cosize_v<decltype(cute::make_layout(cute::make_shape(cute::Int<bN>{}, cute::Int<bK>{}, cute::Int<bP>{})))>];
}

#define SUPPORTED = 1;
namespace aristos{
    __inline__ bool isInitialized = false;
    __inline__ auto aristosStream = cudaStreamPerThread;
    __forceinline__
    void aristosInit(const unsigned int& seqLen, const unsigned int& embedDim, const unsigned int& hiddenProjDim,
                     const unsigned int& k, const unsigned int& capacityFactor, const unsigned int& globalWorld,
                     const unsigned int& numExperts) {
        int blocksPerSM = 0, l2CacheSize = 0;
        assert(!isInitialized);
        isInitialized = true;
        int cudaDevAttribute = 0;
        int dev = 0;
        CUTE_CHECK_ERROR(cudaGetDevice(&dev));
        CUTE_CHECK_ERROR(cudaDeviceGetAttribute(&cudaDevAttribute, cudaDevAttrMultiProcessorCount, dev));
        CUTE_CHECK_ERROR(cudaOccupancyMaxActiveBlocksPerMultiprocessor(
                &blocksPerSM,
                occupancyTestKernel<BLOCK_M, BLOCK_N, BLOCK_K_FULL, PIPELINE_STAGES>,
                ARISTOS_BLOCK_SIZE,
                SHARED_SIZE));
        const auto blocks = cudaDevAttribute * blocksPerSM;
        CUTE_CHECK_ERROR(cudaDeviceGetAttribute(&cudaDevAttribute,
                                                cudaDevAttrMemoryPoolsSupported, dev));
        assert(cudaDevAttribute);
        CUTE_CHECK_ERROR(cudaDeviceGetAttribute(&cudaDevAttribute, cudaDevAttrComputeCapabilityMajor, dev));
        assert(cudaDevAttribute >= 7);
        CUTE_CHECK_ERROR(cudaDeviceGetAttribute(&l2CacheSize, cudaDevAttrL2CacheSize, dev));

        // Good to go! Let's do some initialization
        // Run decider
        // ...
        // generates the below
        const unsigned int numLocalExperts = 0;
        std::vector<specType> parallelSpec{};
        std::vector<specType> translation{};
        const unsigned int numNeighbors = translation.size();

        // initialize NVSHMEM
        nvshmem_init();
        CUTE_CHECK_ERROR(cudaSetDevice(nvshmem_team_my_pe(NVSHMEMX_TEAM_NODE)));
        // Allocate Symmetric Heap + Flags
        auto memoryBytes = ((STAGES * CELLS * seqLen * (embedDim + k + 2))*sizeof(maxPrecision)) + (STAGES * numNeighbors * sizeof(flagsType));
        memoryBytes = cute::max(memoryBytes, globalWorld * (BETA_BUFFER + (globalWorld + 1) * sizeof(floatPair)));
        /// Allocates symmetric heap
        auto sHeap = nvshmem_calloc(memoryBytes, sizeof(cuda::std::byte));

        //Final Initialization
        void* bookKeeping;
        const auto cap = Config::getCapacity(seqLen, numNeighbors, capacityFactor, k);
        const auto taskBound = cute::ceil_div(cap, BLOCK_M) * numExperts * numNeighbors;
        memoryBytes = sizeof(unsigned int) * numNeighbors + // EP rank -> global rank
            sizeof(unsigned int) * numExperts * 2  + // Expert parallelism specification and EP -> heap
            sizeof(unsigned int) * blocks + // readyQ
            sizeof(unsigned long long int) * blocks + // taskSignal
            sizeof(unsigned long long int) * taskBound + // taskSync
            sizeof(Task) * taskBound * 3 + // taskQ
            sizeof(unsigned long long int) * N_READY_Q_SIGNALS + // rQS
            sizeof(unsigned long long int) * (N_TASK_Q_SIGNALS + 1);// tQS and doorbell
        CUTE_CHECK_ERROR(cudaMallocAsync(&bookKeeping, memoryBytes, aristosStream));
        CUTE_CHECK_ERROR(cudaMemsetAsync(bookKeeping, 0, memoryBytes, aristosStream));
        CUTE_CHECK_ERROR(cudaMemcpyToSymbolAsync(moeConfig, &hostMoEConfig, sizeof(Config), 0,
                                            cudaMemcpyHostToDevice, aristosStream));
        CUTE_CHECK_ERROR(cudaPeekAtLastError());
        CUTE_CHECK_ERROR(cudaStreamSynchronize(aristosStream));

#if (__CUDACC_VER_MAJOR__ >= 11 && __CUDA_ARCH__ >= 800)
        cudaStreamAttrValue stream_attribute;
        stream_attribute.accessPolicyWindow.base_ptr  = bookKeeping;
        stream_attribute.accessPolicyWindow.num_bytes = cuda::std::min(static_cast<size_t>(0.25 * l2CacheSize),
            sizeof(unsigned int) * numNeighbors + sizeof(unsigned int) * numExperts * 2);
        stream_attribute.accessPolicyWindow.hitRatio  = 1.0;
        stream_attribute.accessPolicyWindow.hitProp   = cudaAccessPropertyPersisting;
        stream_attribute.accessPolicyWindow.missProp  = cudaAccessPropertyStreaming;

        //Set the attributes to a CUDA stream of type cudaStream_t
        cudaStreamSetAttribute(aristosStream, cudaStreamAttributeAccessPolicyWindow, &stream_attribute);
#endif

    }

    __forceinline__
    void forwardHost(){
        assert(isInitialized);
    }

    __forceinline__
    void backwardHost(){
        assert(isInitialized);
    }

    __forceinline__
    void aristosFinalize(){
        assert(isInitialized);
        isInitialized = false;
        CUTE_CHECK_ERROR(cudaSetDevice(nvshmem_team_my_pe(NVSHMEMX_TEAM_NODE)));
#if (__CUDACC_VER_MAJOR__ >= 11 && __CUDA_ARCH__ >= 800)
        cudaStreamAttrValue stream_attribute;
        stream_attribute.accessPolicyWindow.num_bytes = 0; // Setting the window size to 0 disable it
        // Overwrite the access policy attribute to a CUDA Stream
        cudaStreamSetAttribute(aristosStream, cudaStreamAttributeAccessPolicyWindow, &stream_attribute);
        cudaCtxResetPersistingL2Cache();
#endif

        CUTE_CHECK_ERROR(cudaFreeAsync(hostMoEConfig.bookKeeping, aristosStream));
        nvshmem_free(hostMoEConfig.sHeap);
        nvshmem_finalize();
        CUTE_CHECK_ERROR(cudaPeekAtLastError());
        CUTE_CHECK_ERROR(cudaStreamSynchronize(aristosStream));
    }
}
#endif //PREP_CUH