//
// Created by oja7 on 12/2/24.
//

#ifndef PACKET_CUH
#define PACKET_CUH

#include <nvshmemx.h>
#include <nvshmem.h>
#include <host/nvshmemx_api.h>

#include "../types.cuh"
#include "../atomics.cuh"

namespace aristos::packet {
    template<
        unsigned int blocks,
        DropTokens d = DropTokens::yes,
        unsigned int superBlockSize = ARISTOS_SUPER_BLOCK_SIZE,
        typename Activations
    >
    requires aristos::Matrix<Activations>
    __forceinline__ __device__
    void encode(Bookkeeping const& bk, const Activations& activations, unsigned int* const& __restrict__ workspace) {
        // assert(blocks <= gridDim.x - 1)
        static_assert(blocks % superBlockSize == 0);
        using Element = typename Activations::value_type;
        // Map a static set of blocks to an expert and stride as thus
        constexpr auto numSuperBlocks = blocks / superBlockSize;
        const auto superBlockIdx = blockIdx.x / superBlockSize;
        const auto lBid = blockIdx.x % superBlockSize;
        const bool isLeader = !lBid && !threadIdx.x;

        // cache
        const auto* __restrict__ tP = bk.tP();
        const auto nx = bk.nx;
        const auto world = bk.world;
        const auto eCap = bk.eCap;
        auto* __restrict__ pSA = bk.pSA();
        const auto* __restrict__ pDs = bk.pDs();
        auto* __restrict__ sHeap = bookkeeping.sHeap;
        auto* __restrict__ flags = bookkeeping.flags;
        const auto cellSize = bookkeeping.cellSize();
        const auto expertSlots = bookkeeping.xs;
        const auto tokenDim = bookkeeping.ed;
        const auto rank = bookkeeping.rank;
        const auto rSeqBit = seqBit;

        const auto tokenIds = make_tensor(cute::make_gmem_ptr(tP),
            make_layout(cute::make_shape(nx, eCap), cute::LayoutRight{}));

        // readonly arrays
        // copy only what we need
        // Note that the length of these arrays is rather small,
        // which is why shared memory can accommodate them
        const auto dSl = 3 * nx + world;
        const auto* __restrict__ expertCounts = workspace;
        const auto* __restrict__ pS = expertCounts + nx;
        const auto* __restrict__ xLs = pS + nx;
        const auto* __restrict__ pT = xLs + nx;

        const auto* __restrict__ peerTotalTokens = pT + world;
        auto* __restrict__ pTTx = workspace + dSl;

        // Populate above data structures
        constexpr auto vF = sizeof(uint4) / sizeof(uint);
        const auto vDsL = dSl / vF;
        const auto* __restrict__ vPDs = static_cast<const uint4*>(static_cast<const void*>(pDs));
        #pragma unroll
        for (uint i = threadIdx.x; i < vDsL; i += THREADS) {
            CAST_TO(uint4, workspace)[i] = vPDs[i];
        }
        for (uint i = threadIdx.x + vDsL * vF; i < dSl; i += THREADS) {
            workspace[i] = pDs[i];
        }
        // wipe clean first
        for (uint i = threadIdx.x; i < world; i += THREADS) {
            // done this way to preserve const attribute
            pTTx[i] = 0U;
        }
        __syncthreads();
        #pragma unroll
        for (uint i = threadIdx.x; i < nx; i += THREADS) {
            const auto peer = __ldg(pS + i);
            atomicAdd_block(pTTx + peer, expertCounts[i]);
        }
        __syncthreads();

        for (uint expertIdx = superBlockIdx; expertIdx < nx; expertIdx += numSuperBlocks) {
            const auto pLIdx = xLs[expertIdx]; // local index for current expert on peer
            const auto routedTokens = d == DropTokens::yes ?
                cute::min(expertCounts[expertIdx], eCap) : expertCounts[expertIdx];
            const auto peer = pS[expertIdx];
            const auto pTT = cute::min(peerTotalTokens[peer], eCap);
            const auto isRemote = nvshmem_ptr(sHeap, peer) == nullptr;
            auto* __restrict__ peerHeap = static_cast<cuda::std::byte*>(isRemote ?
                heap::advance<0, 0, sizeof(Element)>(sHeap, cellSize, expertSlots, tokenDim, peer, pLIdx):
                nvshmem_ptr(heap::advance<0, 1, sizeof(Element)>(sHeap, cellSize, expertSlots, tokenDim, peer, pLIdx), peer));
            if (!routedTokens) {
                if (isLeader && !pTT) {
                    // single thread sends a noop packet to unblock the remote peer
                    uint64_t flagSignal = 0;
                    // Pack payload into single signal word
                    *CAST_TO(SignalPayload<>, &flagSignal) = SignalPayload{
                        routedTokens,
                        rSeqBit,
                        Bookkeeping::tiles<BLOCK_M>(pTT)
                    };
                    // transmit signal
                    nvshmemx_signal_op(flags + rank * expertSlots + pLIdx,
                        flagSignal, NVSHMEM_SIGNAL_SET, pT[peer]);
                }
                continue;
            }
            // copy tokens: not padded
            for (uint j = lBid; j < routedTokens; j += superBlockSize) {
                const auto [tokenIdx, _] = tokenIds(expertIdx, j);
                auto* __restrict__ localPH = peerHeap + j * tokenDim * sizeof(Element);
                const auto* __restrict__ aP = &activations(tokenIdx, 0);
                const auto* __restrict__ vAP = static_cast<const uint4*>(static_cast<const void*>(aP));
                const auto vTokenSize = tokenDim / (sizeof(uint4) / sizeof(Element));
                // Use high-throughput vector copy
                for (uint k = threadIdx.x; k < vTokenSize; k += THREADS) {
                    CAST_TO(uint4, localPH)[k] = vAP[k];
                }
                const auto rIdx = vTokenSize * (sizeof(uint4) / sizeof(Element));
                localPH += sizeof(uint4) * vTokenSize;
                for (uint k = threadIdx.x + rIdx; k < tokenDim; k += THREADS) {
                    CAST_TO(Element, localPH)[k] = aP[k];
                }
            }
            __syncthreads();
            if (!threadIdx.x) {
                if (atomicIncrement(pSA + expertIdx) + 1 == superBlockSize) {
                    // I am the last block, let's finalize this transfer.
                    uint64_t flagSignal = 0;
                    *CAST_TO(SignalPayload<>, &flagSignal) = SignalPayload{
                        routedTokens,
                        rSeqBit,
                        Bookkeeping::tiles<BLOCK_M>(pTT)
                    };
                    if (isRemote) {
                        // do RDMA transfer + signal
                        nvshmem_putmem_signal_nbi(
                            heap::advance<0, 1>(sHeap, cellSize, expertSlots, tokenDim, peer, pLIdx),
                            peerHeap,
                            sizeof(Element) * routedTokens * tokenDim,
                            flags + rank * expertSlots + pLIdx,
                            flagSignal,
                            NVSHMEM_SIGNAL_SET,
                            pT[peer]);
                    }
                    else {
                        __threadfence_system();
                        // we've done the DMA transfer already, so we set the signal instead
                        nvshmemx_signal_op(flags + rank * expertSlots + pLIdx,
                            flagSignal,
                            NVSHMEM_SIGNAL_SET,
                            pT[peer]);
                    }
                }
            }
        }
    }

    // Resident in registers
    struct __align__(16) DecoderArg {
        cuda::std::byte* sHeap;
        Task* tQ;
        const unsigned int cellSize;
        const unsigned int eCap;
        const unsigned int tokenSize;
        const unsigned int tPs;
        const unsigned int tN;
        const unsigned int tNx;
        const unsigned int expertSlots;
        const unsigned int nx;

        DecoderArg(
            cuda::std::byte* const& _sHeap,
            Task* const& _tQ,
            unsigned int const& _cellSize,
            unsigned int const& _eCap,
            unsigned int const& _tokenSize,
            unsigned int const& _tPs,
            unsigned int const& _tN,
            unsigned int const& _tNx,
            unsigned int const& _expertSlots,
            unsigned int const& _nx) :
        sHeap(_sHeap), tQ(_tQ), cellSize(_cellSize),
        eCap(_eCap), tokenSize(_tokenSize), tPs(_tPs), tN(_tN),
        tNx(_tNx), expertSlots(_expertSlots), nx(_nx) {}
    };

    /// Decodes a single packet from the initial stage
    template<
        PacketStage s,
        PeerConnectivity p,
        typename Element = void,
        typename ElementScale = Element
    >
    struct Decoder {
        static_assert(aristos::TensorValueType<Element> && aristos::TensorValueType<ElementScale>);
        static_assert(s == PacketStage::initial);
        __device__ __forceinline__
        void operator()(const DecoderArg& dA,
            cuda::std::byte* __restrict__ const& packet,
            unsigned int* __restrict__ const& status,
            unsigned int* __restrict__ const& taskCount,
            uint const& routedTokens, uint const& globalTaskTiles,
            unsigned int const& localExpertIdx,
            cuda::std::byte* __restrict__ const& pGB, //postGEMM buffer
            const cuda::std::array<cuda::std::byte*, GEMMs>& weights,
            const cuda::std::array<cuda::std::byte*, GEMMs>& bias,
            unsigned int const& peer, // relative to the EP group
            unsigned int& lTQHead,
            unsigned int* __restrict__ const& tQHead) const {
            //assert(!__isShared(&dA) && !__isGlobal(&dA) && !__isLocal(&dA))
            auto* __restrict__ sHeap = dA.sHeap;
            auto* __restrict__ tQ = dA.tQ + (threadIdx.x * dA.tPs + lTQHead);
            const auto fTilesM = routedTokens / BLOCK_M;
            const auto padM = Bookkeeping::pad<BLOCK_M>(routedTokens);

            if (!atomicTAS<cuda::thread_scope_block>(status + peer)) {
                // atomically reduce taskCount
                const auto superfluous = (dA.tN + dA.tNx) * (Bookkeeping::tiles<BLOCK_M>(dA.eCap) - globalTaskTiles);
                atomicSub_block(taskCount, superfluous);
            }

            // expert, peer offset
            const auto pXo = dA.eCap * (peer * dA.nx + localExpertIdx);
            cuda::std::array<cuda::std::byte*, GEMMs> taskResults{};
            // Staging buffer for results of preGEMM
            taskResults[0] = pGB + pXo * dA.tokenSize * sizeof(Element);
            // Egress packet buffer
            taskResults[1] = p == PeerConnectivity::remote ?
                heap::advance<1, 0>(sHeap, dA.cellSize, dA.expertSlots, dA.tokenSize, peer, localExpertIdx) :
            heap::advance<1, 1>(sHeap, dA.cellSize, dA.expertSlots, dA.tokenSize, peer, localExpertIdx);
            for (uint i = 0; i < fTilesM; ++i) {
                for (uint j = 0; j < dA.tN; ++j) {
                    const auto tileIdx = j + i * dA.tN;
                    tQ[tileIdx] = Task{
                        TaskType::preGEMM,
                        packet,
                        weights,
                        taskResults,
                        bias,
                        pXo + i,
                        tileIdx,
                        padM,
                        pXo + (p == PeerConnectivity::remote ? i : tileIdx),
                        BLOCK_M,
                        peer,
                        i
                    };
                }
            }

            // residue tile
            if (const auto residue = routedTokens - fTilesM * BLOCK_M; residue) {
                for (uint j = 0; j < dA.tN; ++j) {
                    const auto tileIdx = j + fTilesM * dA.tN;
                    tQ[tileIdx] = Task{
                        TaskType::preGEMM,
                        packet,
                        weights,
                        taskResults,
                        bias,
                        pXo + fTilesM,
                        tileIdx,
                        padM,
                        pXo + (p == PeerConnectivity::remote ? fTilesM : tileIdx),
                        residue,
                        peer,
                        fTilesM
                    };
                }
            }

            if (routedTokens) {
                __threadfence();
                const auto totalTasks = Bookkeeping::tiles<BLOCK_M>(routedTokens) * dA.tN;
                lTQHead += totalTasks;
                // notifies scheduler of work
                atomicAdd_block(tQHead, totalTasks);
            }
        }
    };


    template<>
    struct Decoder<PacketStage::last, PeerConnectivity::p2p> {
        __device__ __forceinline__
        void operator()(Task* __restrict__ tQ,
            cuda::std::byte* __restrict__ const& packet,
            cuda::std::byte* __restrict__ const& tokenIndices,
            cuda::std::byte* __restrict__ const& activations,
            const unsigned int& nTokens,
            const unsigned int& tileIdx,
            unsigned int* __restrict__ const& tQHead,
            const unsigned int& expertIdx) const {
            // now let's decode this single tile
            *tQ = Task{
                TaskType::combine,
                tokenIndices,
                cuda::std::array<cuda::std::byte*, GEMMs>{packet},
                cuda::std::array<cuda::std::byte*, GEMMs>{activations},
                nTokens,
                tileIdx,
                BLOCK_M,
                expertIdx
            };
            __threadfence();
            // notifies scheduler of work
            atomicIncrement<cuda::thread_scope_block>(tQHead);
        }
    };

    template<>
    struct Decoder<PacketStage::last, PeerConnectivity::remote> {
        __device__ __forceinline__
        void operator()(const DecoderArg& dA,
            cuda::std::byte* __restrict__ const& packet,
            cuda::std::byte* __restrict__ const& tokenIndices,
            cuda::std::byte* __restrict__ const& activations,
            const unsigned int& nTokens,
            unsigned int& lTQHead,
            unsigned int* __restrict__ const& tQHead,
            const unsigned int& expertIdx) const {
            auto* __restrict__ tQ = dA.tQ + (threadIdx.x * dA.tPs + lTQHead);
            constexpr auto tB = 8;
            const auto tBs = dA.tN / tB;
            for (uint i = 0; i < tBs; ++i) {
                #pragma unroll
                for (uint j = 0; j < tB; ++j) {
                    tQ[j + i * tB] = Task{
                        TaskType::combine,
                        tokenIndices,
                        cuda::std::array<cuda::std::byte*, GEMMs>{packet},
                        cuda::std::array<cuda::std::byte*, GEMMs>{activations},
                        nTokens,
                        j + i * tB,
                        BLOCK_M,
                        expertIdx
                    };
                }
            }

            for (uint j = tBs * tB; j < dA.tN; ++j) {
                tQ[j] = Task{
                    TaskType::combine,
                    tokenIndices,
                    cuda::std::array<cuda::std::byte*, GEMMs>{packet},
                    cuda::std::array<cuda::std::byte*, GEMMs>{activations},
                    nTokens,
                    j,
                    BLOCK_M,
                    expertIdx
                };
            }

            __threadfence();
            lTQHead += dA.tN;
            // notifies scheduler
            atomicAdd_block(tQHead, dA.tN);
        }
    };
}
#endif //PACKET_CUH
