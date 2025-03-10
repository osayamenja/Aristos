//
// Created by oja7 on 1/1/25.
//

#ifndef OS_CUH
#define OS_CUH

#include <cuda/std/cstddef>
#include "../types.cuh"

#include "scheduler.cuh"
#include "subscriber.cuh"

namespace aristos::os {
    template<
        unsigned int processors,
        DropTokens d = DropTokens::yes,
        typename Output,
        typename ExpertsUp,
        typename ExpertsDown,
        typename BiasUp,
        typename BiasDown,
        unsigned int threads = ACC::PeakHardware::OS::threads::value
    >
    __device__ __forceinline__
    void start(cuda::std::byte* __restrict__ const& workspace,
        Output const& moeOutput,
        ExpertsUp const& expertsUp,
        ExpertsDown const& expertsDown,
        BiasUp const& biasUp,
        BiasDown const& biasDown,
        const uint16_t& lSeqBit) {
        const auto nRx = __ldg(bookkeeping.nRx());
        const auto* __restrict__ eC = bookkeeping.eC();
        const auto world = bookkeeping.world;
        constexpr auto subscriberCount = threads - WARP_SIZE;

        // each subscriber thread gets wSet * sizeof(uint) bytes of workspace
        constexpr auto wSet = 16U; // working set size
        constexpr auto bitSetSizePs = cute::ceil_div(wSet, sizeof(uint) * 8U);
        const auto ssfC = ACC::TCM::value * (ACC::TNx::value * (ACC::E::value - nRx) + nRx);
        const auto bitSetSize = bookkeeping.nLx * bookkeeping.world + ssfC;
        const auto bSSI = nSI<subscriberCount>(bitSetSize);
        constexpr auto E = ACC::E::value;
        constexpr auto TNx = ACC::TNx::value;
        constexpr auto TN = ACC::TNx::value;
        constexpr auto EC = ACC::TNx::value;

        // subscriber shared memory allocation
        auto* __restrict__ eL = CAST_TO(ELI, workspace);
        static_assert(alignof(ELI) % alignof(PLI) == 0);
        auto* __restrict__ pL = CAST_TO(PLI, eL + E);
        static_assert(alignof(PLI) % alignof(uint) == 0);
        const auto dZ = sizeof(ELI) * E + sizeof(PLI) * world;
        auto* __restrict__ bitSet = CAST_TO(uint, workspace + roundToCacheLine(dZ));
        const auto* __restrict__ geL = bookkeeping.eL();
        const auto* __restrict__ gpL = bookkeeping.pLI();
        const auto z = dZ + bSSI + SUBSCRIBERS * wSet * sizeof(uint);
        for (uint i = threadIdx.x; i < bSSI; i += threads) {
            bitSet[i] = 0U;
        }
        #pragma unroll
        for (uint i = threadIdx.x; i < E; ++i) {
            eL[i] = geL[i];
            pL[i] = gpL[i];
        }
        auto* __restrict__ scratch = CAST_TO(uint, workspace + roundToCacheLine(z));
        auto* __restrict__ tQHeads = scratch;
        auto* __restrict__ interrupt = tQHeads + subscriberCount;
        auto* __restrict__ rQ = interrupt + subscriberCount;
        auto* __restrict__ status = rQ + processors;
        auto* __restrict__ schedulerScratch = CAST_TO(cuda::std::byte, status + world);
        // shared memory arrays
        // Upper bound for expectant tasks
        auto* __restrict__ taskBound = scratch;
        const auto* __restrict__ eCs = taskBound + 1;
        scratch += 1;
        #pragma unroll
        for (uint i = threadIdx.x; i < E; i += threads) {
            scratch[i] = __ldg(eC + i);
        }
        __syncthreads();
        // compute taskBound
        #pragma unroll
        for (uint i = threadIdx.x; i < E; i += threads) {
            const auto eCt = Bookkeeping::tiles<BLOCK_M>(d == DropTokens::yes ? cute::min(eCs[i], EC)
                : eCs[i]);
            atomicAdd_block(taskBound, eCt * TN);
            #pragma unroll 4
            for (uint j = 0; j < world; ++j) {
                atomicAdd_block(taskBound, eCt * TNx);
            }
        }
        __syncthreads();
        #pragma unroll
        for (uint i = threadIdx.x; i < processors; i += threads) {
            rQ[i] = i; // initially, all processors are ready
        }
        #pragma unroll
        for (uint i = threadIdx.x; i < SUBSCRIBERS; i += threads) {
            tQHeads[i] = 0U;
            interrupt[i] = 0U;
        }
        __syncthreads();
        // build arguments for scheduler and subscriber
        if (threadIdx.x / WARP_SIZE == 0) {
            // scheduler
            const auto gtQCl = bookkeeping.gtQCl;
            const auto tQRl = cute::ceil_div(gtQCl * ACC::TN::value, subscriberCount);
            auto* __restrict__ gtQHeads = bookkeeping.tQH();
            auto* __restrict__ sQ = bookkeeping.tSA();
            auto* __restrict__ pDB = bookkeeping.pDB();
            scheduler::start<processors>(schedulerScratch, tQRl, gtQCl, interrupt, tQHeads,
                gtQHeads, taskBound, rQ, sQ, pDB);
        }
        else {
            // subscriber
            subscriber::start<bitSetSizePs, wSet>(bitSet, CAST_TO(cuda::std::byte,bitSet + bSSI), interrupt, pL, eL, nRx,
                status, taskBound, moeOutput, expertsUp, expertsDown, biasUp, biasDown, lSeqBit);
        }
    }
}
#endif //OS_CUH
