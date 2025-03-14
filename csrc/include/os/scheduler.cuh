//
// Created by oja7 on 11/17/24.
//

#ifndef SCHEDULER_CUH
#define SCHEDULER_CUH

#include <cub/cub.cuh>
#include <cuda/std/cstddef>
#include <cutlass/array.h>

#include "../atomics.cuh"
#include "../types.cuh"

namespace aristos::scheduler {
    enum class ProcessorInterrupt {
        yes,
        no
    };
    template<
        unsigned int processors,
        ProcessorInterrupt interrupt = ProcessorInterrupt::no,
        DQType dqt = DQType::stride,
        typename WSet
    >
    requires(processors > 0 && isRegisterV<WSet>)
    __device__ __forceinline__
    void schedule(WSet& wSet, const uint& cSetB,
    const uint& canSchedule, const uint& qIdx, uint& lRQIdx,
    const uint& gRQIdx, uint* __restrict__ const& rQ,
    TQSignal* __restrict__ const& pDB) {
        auto sig = TQSignal{interrupt == ProcessorInterrupt::yes ? 1U : 0U};
        for (uint k = 0; k < cSetB; ++k) {
            #pragma unroll
            for (uint l = 0; l < WSet::kElements; ++l) {
                wSet[l] = rQ[(gRQIdx + lRQIdx++) % processors];
            }
            if constexpr (interrupt == ProcessorInterrupt::yes) {
                #pragma unroll
                for (uint l = 0; l < WSet::kElements; ++l) {
                    // interrupt processor
                    #if ARISTOS_DEBUG
                    printf("Scheduler::Interrupt::pid is %u\n", wSet[l]);
                    #endif
                    signalPayload(pDB + wSet[l], &sig);
                }
            }
            else {
                #pragma unroll
                for (uint l = 0; l < WSet::kElements; ++l) {
                    // signal processor
                    sig.encodeSig(DQ::next<dqt>(qIdx, k * WSet::kElements + l));
                    #if ARISTOS_DEBUG
                    printf("Scheduler::pid is %u\n", wSet[l]);
                    #endif
                    signalPayload(pDB + wSet[l], &sig);
                }
            }
        }
        // Residual scheduling
        const auto residue = canSchedule - cSetB * WSet::kElements;
        #pragma unroll
        for (uint l = 0; l < WSet::kElements; ++l) {
            if (l < residue) {
                wSet[l] = rQ[(gRQIdx + lRQIdx++) % processors];
            }
        }
        if constexpr (interrupt == ProcessorInterrupt::yes) {
            #pragma unroll
            for (uint l = 0; l < WSet::kElements; ++l) {
                if (l < residue) {
                    #if ARISTOS_DEBUG
                    printf("Scheduler::Interrupt::pid: %u, taskIdx is %u\n", wSet[l], sig.signal);
                    #endif
                    signalPayload(pDB + wSet[l], &sig);
                }
            }
        }
        else {
            #pragma unroll
            for (uint l = 0; l < WSet::kElements; ++l) {
                if (l < residue) {
                    sig.encodeSig(DQ::next<dqt>(qIdx, cSetB * WSet::kElements + l));
                    #if ARISTOS_DEBUG
                    printf("Scheduler::pid: %u, taskIdx is %u\n", wSet[l], sig.signal);
                    #endif
                    signalPayload(pDB + wSet[l], &sig);
                }
            }
        }
    }

    template<
        unsigned int processors,
        unsigned int sL = (THREADS - WARP_SIZE) / WARP_SIZE,
        ProcessorInterrupt interrupt = ProcessorInterrupt::no,
        unsigned int wS = WARP_SIZE,
        unsigned int blockQStride = ACC::TNx::value,
        typename WarpScan = cub::WarpScan<uint>,
        typename SQState,
        typename TQState,
        typename WSet
    >
    requires (processors > 0 && wS == 32 &&
        isRegisterV<SQState> && isRegisterV<TQState> && isRegisterV<WSet>)
    __device__ __forceinline__
    void schedulerLoop(SQState& sQState, TQState& tqState, WSet& wSet,
        const unsigned int& tQOffset,
        uint& lTt, uint& processorTally,
        uint& gRQIdx, bool& pTEpilog, uint& scheduled,
        typename WarpScan::TempStorage* __restrict__ const& wSt,
        unsigned int* __restrict__ const& sQ,
        uint* __restrict__ const& rQ,
        TQSignal* __restrict__ const& pDB,
        const bool& isMedley = false) {
        uint lRQIdx;
        uint taskTally;
        // things are about to get warped :)
        // Aggregate tally across the warp
        WarpScan(wSt[0]).InclusiveSum(lTt, lRQIdx, taskTally);
        lRQIdx -= lTt;
        while (taskTally) {
            // Find processors if we are not currently aware of any
            while (!processorTally) {
                // sweep sQ to identify ready processes
                uint lPt = 0U; // local processor tally
                constexpr auto pL = processors / wS;
                #pragma unroll
                for (uint j = 0; j < pL; ++j) {
                    const auto readiness = atomicExch(sQ + (j * wS + threadIdx.x),
                        observed) == ready;
                    lPt += readiness;
                    sQState[j] = readiness;
                }
                if (threadIdx.x < processors - pL * wS) {
                    const auto readiness = atomicExch(sQ + (pL * wS + threadIdx.x),
                        observed) == ready;
                    lPt += readiness;
                    sQState[pL] = readiness;
                }
                uint startIdx;
                // Aggregate tally across the warp
                WarpScan(wSt[1]).InclusiveSum(lPt, startIdx, processorTally);
                startIdx -= lPt;
                // write to rQ
                if (lPt) {
                    #pragma unroll
                    for (uint j = 0; j < SQState::kElements; ++j) {
                        if (sQState[j]) {
                            // write ready process pid to rQ
                            rQ[(gRQIdx + startIdx++) % processors] = j * wS + threadIdx.x;
                        }
                    }
                }
                pTEpilog = true;
            }
            if (pTEpilog) {
                pTEpilog = false;
                gRQIdx += processorTally;
                // Below ensures writes to rQ in shared memory are visible warp-wide
                __syncwarp();
            }
            // schedule tasks
            const auto tasks = cute::min(processorTally, taskTally);
            scheduled += tasks;
            processorTally -= tasks;
            taskTally -= tasks;
            // these will get scheduled now
            if (lRQIdx < tasks) {
                auto tasksToSchedule = cute::min(tasks - lRQIdx, lTt);
                lTt -= tasksToSchedule;
                if (isMedley) {
                    if constexpr (sL > 0) {
                        #pragma unroll
                        for (uint j = 0; j < sL; ++j) {
                            if (tqState[j].tasks && tasksToSchedule) {
                                const auto canSchedule = cute::min(tasksToSchedule, tqState[j].tasks);
                                const auto qIdx = DQ::next(j * wS + threadIdx.x, tqState[j].tQTail);
                                tasksToSchedule -= canSchedule;
                                tqState[j].tasks -= canSchedule;
                                // have to increment tails as we will revisit this queue later on
                                tqState[j].tQTail += canSchedule;
                                const auto cSetB = canSchedule / WSet::kElements;
                                schedule<processors, interrupt>(wSet, cSetB, canSchedule, qIdx, lRQIdx, gRQIdx, rQ,
                                    pDB);
                            }
                        }
                    }
                }
                #pragma unroll
                for (uint j = sL; j < TQState::kElements; ++j) {
                    if (tqState[j].tasks && tasksToSchedule) {
                        const auto canSchedule = cute::min(tasksToSchedule, tqState[j].tasks);
                        #if ARISTOS_DEBUG
                        printf("Thread %u, tasks: %u, cS: %u\n", threadIdx.x,
                            tqState[j].tasks, canSchedule);
                        #endif
                        const auto qHead = ((j - sL) * wS + threadIdx.x) * blockQStride;
                        const auto qIdx = interrupt == ProcessorInterrupt::yes? NOOP_SIGNAL : tQOffset + qHead;
                        tasksToSchedule -= canSchedule;
                        tqState[j].tasks -= canSchedule;
                        const auto cSetB = canSchedule / WSet::kElements;
                        schedule<processors, interrupt, DQType::block>(wSet, cSetB, canSchedule, qIdx, lRQIdx, gRQIdx, rQ,
                            pDB);
                    }
                }
            }
        }
    }

    /// Making processorCount a compile-time constant is not a functional requirement but rather strictly
    /// for globally optimizing the modulo operation, which is incredibly expensive.
    /// Benchmarks confirm an order of magnitude performance improvement for that operation.
    template<unsigned int processors>
    requires(processors > 0)
    __device__ __forceinline__
    void start(cuda::std::byte* __restrict__ workspace,
        const unsigned int& sO,
        const unsigned int& gtQCL,
        unsigned int* __restrict__ const& sInterrupts,
        unsigned int* __restrict__ const& tQHeads, // shared
        unsigned int* __restrict__ const& gtQHeads, // global
        unsigned int* __restrict__ const& taskBound, // shared
        unsigned int* __restrict__ const& rQ, // shared
        unsigned int* __restrict__ const& sQ, // global
        TQSignal* __restrict__ const& pDB) { //  global
        uint scheduled = 0U;
        constexpr auto wS = 32U;
        constexpr auto sQsL = cute::ceil_div(processors, wS);
        static_assert(sQsL <= 32);

        constexpr auto subscribers = SUBSCRIBERS;
        static_assert(subscribers % wS == 0);
        constexpr auto sL = subscribers / wS;
        // initialize register buffers
        constexpr auto gTQWSet = 8;
        cutlass::Array<TQState, gTQWSet + sL> tqState{};
        cutlass::Array<uint, sQsL> sQState{};
        constexpr auto wSz = 16;
        cutlass::Array<uint, wSz> wSet{};
        tqState.fill({0U,0U});
        sQState.fill(0U);

        constexpr auto dQL = decltype(tqState)::kElements - sL;
        const uint dT = gtQCL / (wS * dQL);

        // cub stuff
        using WarpScan = cub::WarpScan<uint>;
        auto* __restrict__ wSt = CAST_TO(WarpScan::TempStorage, workspace);
        uint gRQIdx = 0U; // what's the purpose of this?
        uint processorTally = processors; // initially, all processors are available, ensure that rQ has all pids
        bool pTEpilog = false;
        auto tTB = atomicLoad<cuda::thread_scope_block>(taskBound);
        while (scheduled < tTB) {
            // statically sweep tQ for tasks
            uint lTt = 0U; // local task tally
            #pragma unroll
            for (uint i = 0; i < sL; ++i) {
                const auto tasks = atomicLoad<cuda::thread_scope_block>(tQHeads + (i * wS + threadIdx.x)) -
                    tqState[i].tQTail;
                tqState[i].tasks = tasks;
                lTt += tasks;
            }

            // Abstract queues as a 3-D tensor (B, Q, T),
            // where B is the batch dimension or total queue / (Q * T);
            // Q is the number of queues a thread observes in one-pass;
            // and T is the number of threads in a warp
            if (dT > 0) {
                // One-shot scheduling, so tails are irrelevant.
                // Special case, where i == 0
                #pragma unroll
                for (uint j = sL; j < decltype(tqState)::kElements; ++j) {
                    const auto qIdx = wS * (j - sL) + threadIdx.x;
                    const auto tasks = atomicLoad(gtQHeads + qIdx);
                    tqState[j].tasks = tasks;
                    lTt += tasks;
                }
                // schedule observed tasks
                schedulerLoop<processors>(sQState, tqState, wSet, sO, lTt,
                    processorTally, gRQIdx, pTEpilog, scheduled,
                    wSt, sQ, rQ, pDB, true);

                for (uint i = 1; i < dT; ++i) {
                    // Needed to enforce register storage
                    #pragma unroll
                    for (uint j = sL; j < decltype(tqState)::kElements; ++j) {
                        const auto qIdx = wS * (dQL * i + (j - sL)) + threadIdx.x;
                        const auto tasks = atomicLoad(gtQHeads + qIdx);
                        tqState[j].tasks = tasks;
                        lTt += tasks;
                    }
                    // schedule observed tasks
                    schedulerLoop<processors>(sQState, tqState, wSet, sO, lTt,
                        processorTally, gRQIdx, pTEpilog, scheduled,
                        wSt, sQ, rQ, pDB);
                }
            }

            // residue
            #pragma unroll
            for (uint j = sL; j < decltype(tqState)::kElements; ++j) {
                if (const auto qIdx = wS * (dQL * dT + (j - sL)) + threadIdx.x; qIdx < gtQCL) {
                    // TODO atomicExch to ground state
                    const auto tasks = atomicLoad(gtQHeads + qIdx);
                    tqState[j].tasks = tasks;
                    lTt += tasks;
                }
            }
            // schedule observed tasks
            schedulerLoop<processors>(sQState, tqState, wSet, sO, lTt,
                processorTally, gRQIdx, pTEpilog, scheduled,
                wSt, sQ, rQ, pDB, dT == 0);
            if (!threadIdx.x) {
                tTB = atomicLoad<cuda::thread_scope_block>(taskBound);
            }
            tTB = __shfl_sync(0xffffffff, tTB, 0);
        }
        // interrupt subscribers
        #pragma unroll
        for (uint i = threadIdx.x; i < subscribers; i += wS) {
            atomicExch_block(sInterrupts + i, 1U);
        }

        uint lTt = 0U; // local task tally
        if constexpr (constexpr auto trips = processors / (decltype(tqState)::kElements * WARP_SIZE); trips > 0) {
            #pragma unroll
            for (uint i = 0; i < trips; ++i) {
                #pragma unroll
                for (uint j = 0; j < decltype(tqState)::kElements; ++j) {
                    tqState[j].tasks = 1U;
                    tqState[j].tQTail = 0U;
                    lTt += 1U;
                }
                schedulerLoop<processors, 0U, ProcessorInterrupt::yes>(sQState, tqState, wSet, 0U,
                    lTt,
                    processorTally, gRQIdx, pTEpilog, scheduled,
                    wSt, sQ, rQ, pDB, false);
            }
        }
        lTt = 0U;
        constexpr auto pT = processors / WARP_SIZE;
        #pragma unroll
        for (uint j = 0; j < pT; ++j) {
            tqState[j].tasks = 1U;
            tqState[j].tQTail = 0U;
            lTt += 1U;
        }
        constexpr auto rT = processors - pT * WARP_SIZE;
        const uint residue = threadIdx.x < rT;
        tqState[pT].tQTail = 0U;
        tqState[pT].tasks = residue;
        lTt += residue;
        schedulerLoop<processors, 0U, ProcessorInterrupt::yes>(sQState, tqState, wSet, 0U, lTt,
                processorTally, gRQIdx, pTEpilog, scheduled,
                wSt, sQ, rQ, pDB, false);
    }
}
#endif //SCHEDULER_CUH
