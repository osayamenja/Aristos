//
// Created by Jonathan on 7/4/24.
//

#ifndef ARISTOS_QUEUE_CUH
#define ARISTOS_QUEUE_CUH
#include <nvshmem.h>

#include "../types.cuh"
#include "packet.cuh"

namespace aristos::subscriber{
    ///Receive and decode packets deposited
    template<
        unsigned int wSet = 16U,
        unsigned int subscriberCount = SUBSCRIBERS,
        typename Output,
        typename ExpertsUp,
        typename ExpertsDown,
        typename BiasUp,
        typename BiasDown,
        typename Element = typename Output::value_type
    >
    requires(cutlass::ispow2(wSet) && wSet > 1 && wSet <= 16)
    __device__ __forceinline__
    void start(cuda::std::byte* __restrict__ const& workspace,
        unsigned int* const& interrupt,
        const unsigned int* __restrict__ const& peerTranslation, // shared
        const unsigned int* __restrict__ const& peerRemote, // shared
        // remote experts: {actual & local expert idx, peer idx}
        const cuda::std::tuple<uint, uint, uint>* __restrict__ const& rE, // shared
        const cuda::std::tuple<uint, uint, uint>* __restrict__ const& nRe, // p2p experts: like above
        const unsigned int& rEl, // number of remote experts
        unsigned int* __restrict__ const& status, // shared
        unsigned int* __restrict__ const& taskCount,
        Output const& moeOutput,
        ExpertsUp const& expertsUp,
        ExpertsDown const& expertsDown,
        BiasUp const& biasUp,
        BiasDown const& biasDown,
        const uint16_t& lSeqBit){
        // offset due to warp specialization for the scheduler
        const auto tIdx = threadIdx.x - WARP_SIZE;
        static_assert(sizeof(unsigned long long int) == sizeof(flagsType));
        static_assert(sizeof(SignalPayload<>) == sizeof(uint64_t));
        static_assert(sizeof(SignalPayload<PacketStage::last>) == sizeof(uint64_t));
        // Register allocation
        const auto dA = packet::DecoderArg{
            bookkeeping.sHeap,
            bookkeeping.tQ(),
            bookkeeping.cellSize(),
            bookkeeping.eCap,
            bookkeeping.ed,
            bookkeeping.tPs,
            bookkeeping.tN,
            Bookkeeping::tiles<BLOCK_N>(bookkeeping.px),
            bookkeeping.xs,
            bookkeeping.nx
        };

        // each thread gets 64 bytes of workspace
        cutlass::AlignedArray<unsigned int, wSet> rWSet{};

        // token indices
        const auto* tokenIds = bookkeeping.tP();

        // tQ things
        auto* tQHead = bookkeeping.tQH() + tIdx;
        auto lTQHead = 0U; // local tQ Head

        // pointers
        //each thread gets 64 bytes of workspace
        auto* __restrict__ sharedSpace = CAST_TO(unsigned int, workspace);
        auto* __restrict__ sFlags = bookkeeping.flags;
        auto* __restrict__ pGB = bookkeeping.xM(); // post GEMM buffer

        // Constants
        const auto nLx = bookkeeping.nLx;

        // first stage
        const auto fSfC = bookkeeping.world * nLx; // first stage flag count
        const auto fSl = fSfC / subscriberCount + (tIdx < fSfC % subscriberCount);
        const auto fSt = fSl / wSet;
        auto fSp = fSl; // first stage pending

        // second stage: remote
        const auto tCM = bookkeeping.tCM;
        const auto sRfC = rEl * tCM;
        const auto sRl = sRfC / subscriberCount + (tIdx < sRfC % subscriberCount);
        const auto sRt = sRl / wSet;

        // second stage: p2p
        const auto sPfC = (dA.nx - rEl) * tCM * dA.tN;
        const auto sPl = sPfC / subscriberCount + (tIdx < sPfC % subscriberCount);
        const auto sPt = sPl / wSet;
        const auto iPfS = cute::make_shape(tCM, dA.tN);
        const auto fS = make_shape(dA.nx - rEl, iPfS);
        const auto fStride = make_stride(size(iPfS), cute::make_stride(dA.tN, 1));

        auto* __restrict__ ffC = bookkeeping.fC(); // flags checkpoint
        auto* __restrict__ rfC = ffC + fSfC; // second stage: remote flags checkpoint
        auto* __restrict__ pfC = rfC + sRfC; // second stage: p2p flags checkpoint

        // Decoder stuff
        packet::Decoder<PacketStage::initial, PeerConnectivity::p2p, Element> fPd{};
        packet::Decoder<PacketStage::initial, PeerConnectivity::remote, Element> fRd{};
        packet::Decoder<PacketStage::last, PeerConnectivity::p2p> lPd{};
        packet::Decoder<PacketStage::last, PeerConnectivity::remote> lRd{};

        while (!atomicLoad<cuda::thread_scope_block>(interrupt)) {
            auto* __restrict__ flags = sFlags;
            // sweep through flags by stages
            // start with the first stage
            // Apply loop unroll with residue
            if (fSp) {
                for (uint i = 0; i < fSt; ++i) {
                    #pragma unroll
                    for (uint j = 0; j < wSet; ++j) {
                        // global to shared memory
                        const auto flagIdx = tIdx + (j + i * wSet) * subscriberCount;
                        sharedSpace[tIdx + j * subscriberCount] = ffC[flagIdx];
                    }
                    #pragma unroll
                    for (uint j = 0; j < wSet; ++j) {
                        rWSet[j] = sharedSpace[tIdx + j * subscriberCount];
                    }
                    // no need for overlapping the next stage, as most likely, only one trip will occur
                    #pragma unroll
                    for (uint j = 0; j < wSet; ++j) {
                        const auto flagIdx = tIdx + (j + i * wSet) * subscriberCount;
                        // main loop
                        if (!rWSet[j]) {
                            // we need to check this flag
                            auto signal = atomicLoad<cuda::thread_scope_system>(
                                CAST_TO(unsigned long long int, flags + flagIdx));
                            const auto sP = CAST_TO(SignalPayload<>, &signal);
                            rWSet[j] = sP->seqBit == lSeqBit;
                            fSp -= rWSet[j];
                            if (rWSet[j]) {
                                // decode the received packet
                                const auto expertIdx = flagIdx % nLx;
                                const auto peerIdx = flagIdx / nLx;
                                const auto gPeer = peerTranslation[peerIdx];
                                const auto isRemote = peerRemote[peerIdx];
                                cuda::std::array weights{
                                    CONST_CAST_TO(cuda::std::byte, &expertsUp(expertIdx)),
                                    CONST_CAST_TO(cuda::std::byte, &expertsDown(expertIdx))
                                };
                                cuda::std::array bias{
                                    CONST_CAST_TO(cuda::std::byte, &biasUp(expertIdx)),
                                    CONST_CAST_TO(cuda::std::byte, &biasDown(expertIdx))
                                };
                                const auto* packet = heap::advance<0, 1, sizeof(Element)>(dA.sHeap,
                                    dA.cellSize, dA.expertSlots, dA.tokenSize, peerIdx, expertIdx);
                                if (!isRemote) {
                                    // P2P peer
                                    // Enforce consistency
                                    // before decoding the packet
                                    __threadfence_system();
                                    fPd(dA, packet, status, taskCount, sP->routedTokens, sP->totalTilesM,
                                        expertIdx, pGB, weights, bias, peerIdx, gPeer, lTQHead, tQHead);
                                }
                                else {
                                    // Remote peer
                                    // Below enforces consistency
                                    // before reading the packet.
                                    // We cannot decouple the API, unfortunately,
                                    // as the memory ordering mechanism is internal.
                                    nvshmem_ushort_test(&sP->seqBit, NVSHMEM_CMP_EQ, lSeqBit);
                                    fRd(dA, packet, status, taskCount, sP->routedTokens, sP->totalTilesM,
                                        expertIdx, pGB, weights, bias, peerIdx, gPeer, lTQHead, tQHead);
                                }
                            }
                        }
                    }
                    // update checkpoints
                    #pragma unroll
                    for (uint j = 0; j < wSet; ++j) {
                        const auto flagIdx = tIdx + (j + i * wSet) * subscriberCount;
                        ffC[flagIdx] = rWSet[j];
                    }
                }
                // residue
                if (const auto residue = fSl - fSt * wSet) {
                    for (uint j = 0; j < residue; ++j) {
                        // global to shared memory
                        const auto flagIdx = tIdx + (j + fSt * wSet) * subscriberCount;
                        sharedSpace[tIdx + j * subscriberCount] = ffC[flagIdx];
                    }
                    // predicated loops, necessary to ensure the compiler maintains register storage
                    #pragma unroll
                    for (uint j = 0; j < wSet; ++j) {
                        if (j < residue) {
                            rWSet[j] = sharedSpace[tIdx + j * subscriberCount];
                        }
                    }
                    #pragma unroll
                    for (uint j = 0; j < wSet; ++j) {
                        const auto flagIdx = tIdx + (j + fSt * wSet) * subscriberCount;
                        // main loop
                        if (!rWSet[j] && j < residue) {
                            // we need to check this flag
                            auto signal = atomicLoad<cuda::thread_scope_system>(
                                    CAST_TO(unsigned long long int, flags + flagIdx));
                            const auto sP = CAST_TO(SignalPayload<>, &signal);
                            rWSet[j] = sP->seqBit == lSeqBit;
                            fSp -= rWSet[j];
                            if (rWSet[j]) {
                                // decode the received packet
                                auto expertIdx = flagIdx % nLx;
                                auto peerIdx = flagIdx / nLx;
                                const auto gPeer = peerTranslation[peerIdx];
                                const auto isRemote = peerRemote[peerIdx];
                                cuda::std::array weights{
                                    CONST_CAST_TO(cuda::std::byte, &expertsUp(expertIdx)),
                                    CONST_CAST_TO(cuda::std::byte, &expertsDown(expertIdx))
                                };
                                cuda::std::array bias{
                                    CONST_CAST_TO(cuda::std::byte, &biasUp(expertIdx)),
                                    CONST_CAST_TO(cuda::std::byte, &biasDown(expertIdx))
                                };

                                if (const auto* packet = heap::advance<0, 1, sizeof(Element)>(dA.sHeap, dA.cellSize,
                                    dA.expertSlots, dA.tokenSize, peerIdx, expertIdx);
                                    !isRemote) {
                                    // Enforce consistency before decoding the packet
                                    __threadfence_system();
                                    fPd(dA, packet, status, taskCount, sP->routedTokens, sP->totalTilesM,
                                        expertIdx, pGB, weights, bias, peerIdx, gPeer, lTQHead, tQHead);
                                }
                                else {
                                    nvshmem_ushort_test(&sP->seqBit, NVSHMEM_CMP_EQ, lSeqBit);
                                    fRd(dA, packet, status, taskCount, sP->routedTokens, sP->totalTilesM,
                                        expertIdx, pGB, weights, bias, peerIdx, gPeer, lTQHead, tQHead);
                                }
                            }
                        }
                    }
                    #pragma unroll
                    for (uint j = 0; j < wSet; ++j) {
                        if (j < residue) {
                            const auto flagIdx = tIdx + (j + fSt * wSet) * subscriberCount;
                            rWSet[j] = ffC[flagIdx];
                        }
                    }
                }
            }

            flags += fSfC;

            // second stage, where flag dimension is (E, C)
            // remote
            if (sRt) {
                // prefetch to shared memory
                #pragma unroll
                for (uint j = 0; j < wSet; ++j) {
                    const auto flagIdx = tIdx + j * subscriberCount;
                    sharedSpace[tIdx + j * subscriberCount] = rfC[flagIdx];
                }
            }
            for (uint i = 0; i < sRt; ++i) {
                #pragma unroll
                for (uint j = 0; j < wSet; ++j) {
                    rWSet[j] = sharedSpace[tIdx + j * subscriberCount];
                    if (i + 1 < sRt) {
                        const auto flagIdx = tIdx + (j + (i + 1) * wSet) * subscriberCount;
                        sharedSpace[tIdx + j * subscriberCount] = rfC[flagIdx];
                    }
                }
                #pragma unroll
                for (uint j = 0; j < wSet; ++j) {
                    const auto flagIdx = tIdx + (j + i * wSet) * subscriberCount;
                    if (!rWSet[j]) {
                        auto signal = atomicLoad<cuda::thread_scope_system>(
                                CAST_TO(unsigned long long int, flags + flagIdx));
                        // SignalPayload -> {batchIdx, {seqNo, M}}, where M <= BLOCK_M
                        // we do not necessarily need
                        // to transmit batchIdx as we can deduce it locally
                        const auto sP = CAST_TO(SignalPayload<PacketStage::last>, &signal);
                        rWSet[j] = sP->seqBit == lSeqBit;
                        fSp -= rWSet[j];
                        if (rWSet[j]) {
                            // enforce remote memory consistency
                            nvshmem_ushort_test(&sP->seqBit, NVSHMEM_CMP_EQ, lSeqBit);
                            const auto [aEIdx, lEIdx, pIdx] = rE[flagIdx / tCM];
                            const auto* packet = heap::advance<1, 1, sizeof(Element)>(dA.sHeap, dA.cellSize,
                                dA.expertSlots, dA.tokenSize, pIdx, lEIdx,
                                sP->batchIdx * BLOCK_M);
                            lRd(dA, packet, CONST_CAST_TO(cuda::std::byte,
                                tokenIds + (aEIdx * dA.eCap + sP->batchIdx * BLOCK_M)),
                                CAST_TO(cuda::std::byte, moeOutput.data().get()), sP->tokensM,
                                lTQHead, tQHead, aEIdx);
                        }
                    }
                }
                // update checkpoints
                #pragma unroll
                for (uint j = 0; j < wSet; ++j) {
                    const auto flagIdx = tIdx + (j + i * wSet) * subscriberCount;
                    rfC[flagIdx] = rWSet[j];
                }
            }
            if (const auto residue = sRl - sRt * wSet) {
                for (uint j = 0; j < residue; ++j) {
                    const auto flagIdx = tIdx + (j + sRt * wSet) * subscriberCount;
                    sharedSpace[tIdx + j * subscriberCount] = ffC[flagIdx];
                }
                #pragma unroll
                for (uint j = 0; j < wSet; ++j) {
                    if (j < residue) {
                        rWSet[j] = sharedSpace[tIdx + j * subscriberCount];
                    }
                }
                #pragma unroll
                for (uint j = 0; j < wSet; ++j) {
                    const auto flagIdx = tIdx + (j + sRt * wSet) * subscriberCount;
                    if (!rWSet[j] && j < residue) {
                        auto signal = atomicLoad<cuda::thread_scope_system>(
                                CAST_TO(unsigned long long int, flags + flagIdx));
                        // SignalPayload -> {batchIdx, {seqNo, M}}, where M <= BLOCK_M
                        const auto sP = CAST_TO(SignalPayload<PacketStage::last>, &signal);
                        rWSet[j] = sP->seqBit == lSeqBit;
                        fSp -= rWSet[j];
                        if (rWSet[j]) {
                            // enforce remote memory consistency
                            nvshmem_ushort_test(&sP->seqBit, NVSHMEM_CMP_EQ, lSeqBit);
                            const auto [aEIdx, lEIdx, pIdx] = rE[flagIdx / tCM];
                            const auto* packet = heap::advance<1, 1, sizeof(Element)>(dA.sHeap, dA.cellSize,
                                dA.expertSlots, dA.tokenSize,
                                pIdx, lEIdx, sP->batchIdx * BLOCK_M);
                            lRd(dA, packet, CONST_CAST_TO(cuda::std::byte,
                                tokenIds + (aEIdx * dA.eCap + sP->batchIdx * BLOCK_M)),
                                CAST_TO(cuda::std::byte, moeOutput.data().get()),
                                sP->tokensM, lTQHead, tQHead, aEIdx);
                        }
                    }
                }
                #pragma unroll
                for (uint j = 0; j < wSet; ++j) {
                    if (j < residue) {
                        const auto flagIdx = tIdx + (j + sRt * wSet) * subscriberCount;
                        rfC[flagIdx] = rWSet[j];
                    }
                }
            }

            flags += sRfC;
            // second stage
            // p2p
            if (sPt) {
                // prefetch to shared memory
                #pragma unroll
                for (uint j = 0; j < wSet; ++j) {
                    const auto flagIdx = tIdx + j * subscriberCount;
                    sharedSpace[tIdx + j * subscriberCount] = pfC[flagIdx];
                }
            }
            for (uint i = 0; i < sPt; ++i) {
                #pragma unroll
                for (uint j = 0; j < wSet; ++j) {
                    rWSet[j] = sharedSpace[tIdx + j * subscriberCount];
                    if (i + 1 < sPt) {
                        const auto flagIdx = tIdx + (j + (i + 1) * wSet) * subscriberCount;
                        sharedSpace[tIdx + j * subscriberCount] = pfC[flagIdx];
                    }
                }
                #pragma unroll
                for (uint j = 0; j < wSet; ++j) {
                    const auto flagIdx = tIdx + (j + i * wSet) * subscriberCount;
                    if (!rWSet[j]) {
                        auto signal = atomicLoad<cuda::thread_scope_system>(
                                CAST_TO(unsigned long long int, flags + flagIdx));
                        // SignalPayload -> {batchIdx, {seqNo, M}}, where M <= BLOCK_M
                        const auto sP = CAST_TO(SignalPayload<PacketStage::last>, &signal);
                        rWSet[j] = sP->seqBit == lSeqBit;
                        fSp -= rWSet[j];
                        if (rWSet[j]) {
                            // enforce memory consistency
                            __threadfence_system();
                            // [index to nRe, batchIdx, tileIdx]
                            const auto coord = idx2crd(flagIdx, fS, fStride);
                            const auto [aEIdx, lEIdx, pIdx] =
                                nRe[cute::get<0>(coord)];
                            const auto* packet = heap::advance<1, 1, sizeof(Element)>(dA.sHeap, dA.cellSize,
                                dA.expertSlots, dA.tokenSize,
                                pIdx, lEIdx, sP->batchIdx * BLOCK_M);
                            lPd(dA.tQ + (tIdx * dA.tPs + lTQHead++), packet,
                                CONST_CAST_TO(cuda::std::byte,
                                    tokenIds + (aEIdx * dA.eCap + sP->batchIdx * BLOCK_M)),
                                CAST_TO(cuda::std::byte, moeOutput.data().get()), sP->tokensM,
                                cute::get<1>(cute::get<1>(coord)), tQHead, aEIdx);
                        }
                    }
                }
                #pragma unroll
                for (uint j = 0; j < wSet; ++j) {
                    const auto flagIdx = tIdx + (j + i * wSet) * subscriberCount;
                    pfC[flagIdx] = rWSet[j];
                }
            }
            if (const auto residue = sPl - sPt * wSet) {
                for (uint j = 0; j < residue; ++j) {
                    const auto flagIdx = tIdx + (j + sPt * wSet) * subscriberCount;
                    sharedSpace[tIdx + j * subscriberCount] = pfC[flagIdx];
                }
                #pragma unroll
                for (uint j = 0; j < wSet; ++j) {
                    if (j < residue) {
                        rWSet[j] = sharedSpace[tIdx + j * subscriberCount];
                    }
                }
                #pragma unroll
                for (uint j = 0; j < wSet; ++j) {
                    const auto flagIdx = tIdx + (j + sPt * wSet) * subscriberCount;
                    if (!rWSet[j] && j < residue) {
                        auto signal = atomicLoad<cuda::thread_scope_system>(
                                CAST_TO(unsigned long long int, flags + flagIdx));
                        // SignalPayload -> {batchIdx, {seqNo, M}}, where M <= BLOCK_M
                        const auto sP = CAST_TO(SignalPayload<PacketStage::last>, &signal);
                        rWSet[j] = sP->seqBit == lSeqBit;
                        fSp -= rWSet[j];
                        if (rWSet[j]) {
                            // enforce memory consistency
                            __threadfence_system();
                            // [index to nRe, [batchIdx, tileIdx]]
                            const auto coord = idx2crd(flagIdx, fS, fStride);
                            const auto [aEIdx, lEIdx, pIdx] =
                                nRe[cute::get<0>(coord)];
                            const auto* packet = heap::advance<1, 1, sizeof(Element)>(dA.sHeap, dA.cellSize,
                                dA.expertSlots, dA.tokenSize, pIdx, lEIdx, sP->batchIdx * BLOCK_M);
                            lPd(dA.tQ + (tIdx * dA.tPs + lTQHead++), packet,
                                CONST_CAST_TO(cuda::std::byte,
                                    tokenIds + (aEIdx * dA.eCap + sP->batchIdx * BLOCK_M)),
                                CAST_TO(cuda::std::byte, moeOutput.data().get()), sP->tokensM,
                                cute::get<1>(cute::get<1>(coord)), tQHead, aEIdx);
                        }
                    }
                }
                #pragma unroll
                for (uint j = 0; j < wSet; ++j) {
                    if (j < residue) {
                        const auto flagIdx = tIdx + (j + sPt * wSet) * subscriberCount;
                        pfC[flagIdx] = rWSet[j];
                    }
                }
            }
        }
    }
}
#endif //ARISTOS_QUEUE_CUH
