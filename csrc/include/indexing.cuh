//
// Created by Jonathan on 7/13/24.
//

#ifndef ARISTOS_INDEXING_CUH
#define ARISTOS_INDEXING_CUH

#include <../cmake/cache/cutlass/3a9de332b38746b489cce3a24161f80aafa1feaa/include/cute/config.hpp>

namespace aristos{
    namespace block{
        /// Block-scoped thread id
        decltype(auto)
        CUTE_HOST_DEVICE
        threadID() {
            #if defined(__CUDA_ARCH__)
                        return threadIdx.x + threadIdx.y*blockDim.x + threadIdx.z*blockDim.x*blockDim.y;
            #else
                        return 0;
            #endif
        }

        /// Block-scoped warp id
        decltype(auto)
        CUTE_HOST_DEVICE
        warpID() {
            #if defined(__CUDA_ARCH__)
                        return (threadIdx.x + threadIdx.y*blockDim.x + threadIdx.z*blockDim.x*blockDim.y) >> 5;
            #else
                        return 0;
            #endif
        }
    }
    namespace warp{
        /// Block-scoped and warp-scoped thread id
        decltype(auto)
        CUTE_HOST_DEVICE
        laneID() {
        #if defined(__CUDA_ARCH__)
                    return (threadIdx.x + threadIdx.y*blockDim.x + threadIdx.z*blockDim.x*blockDim.y) % 32;
        #else
                    return 0;
        #endif
        }
    }
    namespace grid{
        /// Grid-scoped thread id
        decltype(auto)
        CUTE_HOST_DEVICE
        threadID() {
        #if defined(__CUDA_ARCH__)
            return (blockIdx.x + blockIdx.y * gridDim.x + gridDim.x * gridDim.y * blockIdx.z)
                    * (blockDim.x * blockDim.y * blockDim.z)
                    + (threadIdx.z * (blockDim.x * blockDim.y)) + (threadIdx.y * blockDim.x) + threadIdx.x;
        #else
                    return 0;
        #endif
        }

        decltype(auto)
        CUTE_HOST_DEVICE
        blockID() {
        #if defined(__CUDA_ARCH__)
                    return blockIdx.x + blockIdx.y * gridDim.x + gridDim.x * gridDim.y * blockIdx.z;
        #else
                    return 0;
        #endif
        }
    }
}

#endif //ARISTOS_INDEXING_CUH