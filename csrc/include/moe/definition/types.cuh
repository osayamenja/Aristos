//
// Created by Jonathan on 7/18/24.
//

#ifndef ARISTOS_TYPES_CUH
#define ARISTOS_TYPES_CUH

#include "memory_layout.cuh"
#include "../../../cmake-build-debug/_deps/nlohmann_json-src/include/nlohmann/json.hpp"

namespace aristos{
    using maxPrecision = float;
    /// 2 Bytes
    using medium_int = unsigned short;
    namespace cg = cooperative_groups;

    /// Types can be much smaller than int
    struct Config{
        void* sHeap;
        uint64_t* flags;
        unsigned int* shardSpec;
        // Expert parallel World Size
        unsigned int worldSize;
        unsigned int capacity;
        unsigned long peerOffset;
        unsigned int rank;
        unsigned long sequenceNumber;
        unsigned int seqLen;
        unsigned int numExperts;
        unsigned int k;
        unsigned int embedDim;
        unsigned int embedPrecision;
        unsigned int numCommBlocks;
        size_t maxDynamicSharedPerBlock;

        CUTE_HOST_DEVICE
        Config() = default;

        CUTE_HOST_DEVICE
        Config(uint64_t* _flags,
               void* _symmetricHeap,
               unsigned int* _shardSpec,
               const unsigned int _worldSize,
               const unsigned int _rank,
               const unsigned long _sequenceNumber,
               const unsigned int _capacityFactor,
               const unsigned int _k,
               const unsigned int _embedDim,
               const unsigned int _embedPrecision,
               const unsigned int _numExperts,
               const unsigned int _seqLen):
                sHeap(_symmetricHeap),
                flags(_flags),
                shardSpec(_shardSpec),
                worldSize(_worldSize),
                capacity(getCapacity(_seqLen, _numExperts, _capacityFactor, _k)),
                peerOffset(symmetric_heap_peer_offset(capacity, _k,
                                              (_embedDim * _embedPrecision)) / micro_header_bytes),
                rank(_rank),
                sequenceNumber(_sequenceNumber),
                seqLen(_seqLen),
                numExperts(_numExperts),
                k(_k), embedDim(_embedDim),
                embedPrecision(_embedPrecision)
                {};

        CUTE_HOST_DEVICE
        static unsigned int getCapacity(const unsigned int _seqLen, const unsigned int _numExperts,
                                        const unsigned int _capacityFactor, const unsigned int _k){
            return cute::ceil_div(_seqLen, _numExperts) * _capacityFactor * _k;
        }

        CUTE_HOST_DEVICE
        void dump(){
            printf("{\n\t"
                   "\"Capacity\": %u,\n\t"
                   "\"E\": %u,\n\t"
                   "\"H\": %u,\n\t"
                   "\"PeerOffset\": %lu,\n\t"
                   "\"Rank\": %u,\n\t"
                   "\"SB\": %u,\n\t"
                   "\"SequenceNumber\": %lu,\n\t"
                   "\"WorldSize\": %u,\n\t"
                   "\"k\": %u\n}\n",
                   capacity, numExperts, embedDim, peerOffset,
                   rank, seqLen, sequenceNumber, worldSize, k);
        }
    };

    /// Owned by a block
    struct SenderConfig : Config{
        unsigned int bid;
        unsigned long blocksToPeers;
        unsigned int peerStripeLength;
        unsigned int intraPeerIndex;
        unsigned int firstPeer;

        CUTE_DEVICE
        SenderConfig() = default; // Circumvents warning about 'initializing shared variables'

        CUTE_DEVICE
        SenderConfig(const Config c){
            /// Old Stuff
            sHeap = c.sHeap;
            flags = c.flags;
            shardSpec = c.shardSpec;
            worldSize = c.worldSize;
            capacity = c.capacity;
            peerOffset = c.peerOffset;
            rank = c.rank;
            sequenceNumber = c.sequenceNumber;
            seqLen = c.seqLen;
            numExperts = c.numExperts;
            singularPacketBytes = c.singularPacketBytes;
            k = c.k;
            embedDim = c.embedDim;
            embedPrecision = c.embedPrecision;

            /// New stuff
            bid = aristos::bid();
            blocksToPeers = max((gridDim.z - 1) * (gridDim.x * gridDim.y) / worldSize, 1);
            peerStripeLength = cuda::ceil_div(1UL, blocksToPeers);
            intraPeerIndex = bid - ((bid / blocksToPeers) * blocksToPeers);
            firstPeer = static_cast<int>(bid / blocksToPeers);
        };

        CUTE_DEVICE
        void dump(){
            printf("{\n\t"
                   "\"BlockID\": %u,\n\t"
                   "\"BlocksToPeers\": %lu,\n\t"
                   "\"Capacity\": %u,\n\t"
                   "\"E\": %u,\n\t"
                   "\"H\": %u,\n\t"
                   "\"FirstPeer\": %u,\n\t"
                   "\"IntraPeerIndex\": %u,\n\t"
                   "\"PeerOffset\": %lu,\n\t"
                   "\"PeerStripeLength\": %u,\n\t"
                   "\"Rank\": %u,\n\t"
                   "\"SB\": %u,\n\t"
                   "\"SequenceNumber\": %lu,\n\t"
                   "\"WorldSize\": %u,\n\t"
                   "\"k\": %u\n}\n",
                   bid, blocksToPeers, capacity, numExperts, embedDim, firstPeer, intraPeerIndex, peerOffset,
                   peerStripeLength, rank, seqLen, sequenceNumber, worldSize, k);
        }
    };
}
#endif //ARISTOS_TYPES_CUH