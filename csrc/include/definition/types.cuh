//
// Created by Jonathan on 7/18/24.
//

#ifndef ARISTOS_TYPES_CUH
#define ARISTOS_TYPES_CUH

#define ARISTOS_BLOCK_SIZE 128
#define ARISTOS_BLOCK_SIZE_WARP (128 / 32)

#define CAST_TO(T, p) static_cast<T*>(static_cast<void*>(p))

#define N_READY_Q_SIGNALS 2
#define N_TASK_Q_SIGNALS 2

/// The symmetric heap is a 4-D tensor (P, S, C, T)
/// where P, S, C, and T denote dimensions for peers, communication stages,
/// cells and tokens.
/// Number of communication stages S
#define STAGES 2

/// Per stage, there is one cell for sending and another for reception
#define CELLS 2
#define SEND_CELL 0
#define RECEIVE_CELL 1

#define HEAP_ALIGNMENT 16

namespace aristos{
    using maxPrecision = float;
    using specType = unsigned int;
    using flagsType = uint64_t;

    struct ModelConfig{
        unsigned int numLayers;
        unsigned int globalBatch;
        unsigned int redAmount;
        unsigned int miniBatch;
        unsigned int moeFreq;
        unsigned int p2pBuffer;
        unsigned int gradBuffer;
        ModelConfig() = default;
        ModelConfig(const unsigned int& numLayers, const unsigned int& redAmount, const unsigned int& globalBatch,
                    const unsigned int& miniBatch, const unsigned int& moeFreq,
                    const unsigned int& p2PBuffer, const unsigned int& gradBuffer) :
                    numLayers(numLayers), globalBatch(globalBatch),
                    redAmount(redAmount), miniBatch(miniBatch), moeFreq(moeFreq),
                    p2pBuffer(p2PBuffer), gradBuffer(gradBuffer) {}
    };

    struct __align__(16) Config{
        cuda::std::byte* sHeap;
        flagsType* flags;
        /// Needed for free
        cuda::std::byte* bookKeeping;
        /// EP rank -> global rank
        unsigned int* peerTranslation;
        /// EP rank -> heap offsets
        unsigned int* heapOffsets;
        unsigned int* parallelismSpec;
        /// Expert parallel group rank
        unsigned int rank;
        unsigned long sequenceNumber;
        unsigned int seqLen;
        unsigned int numExperts;
        unsigned int k;
        unsigned int worldSize;
        unsigned int embedDim;
        unsigned int upProjection;
        unsigned int capacity;
        unsigned int tilesN;

        CUTE_HOST_DEVICE
        Config() = default;

        CUTE_HOST
        Config(cuda::std::byte* _symmetricHeap,
               flagsType* _flags,
               cuda::std::byte* _bk,
               const unsigned int& _rank,
               const unsigned long& _sequenceNumber,
               const unsigned int& _k,
               const unsigned int& _embedDim,
               const unsigned int& _numExperts,
               const unsigned int& _seqLen,
               const unsigned int& _world,
               const unsigned int& _proj,
               const unsigned int& _cap,
               const unsigned int& _tilesN):
                sHeap(_symmetricHeap),
                flags(_flags),
                bookKeeping(_bk),
                peerTranslation(CAST_TO(unsigned int, _bk)),
                heapOffsets(peerTranslation + _world),
                parallelismSpec(heapOffsets + _world),
                rank(_rank),
                sequenceNumber(_sequenceNumber),
                seqLen(_seqLen),
                numExperts(_numExperts),
                k(_k), worldSize(_world),
                embedDim(_embedDim),
                upProjection(_proj),
                capacity(_cap),
                tilesN(_tilesN){}

        CUTE_HOST_DEVICE
        static unsigned int getCapacity(const unsigned int& _seqLen, const unsigned int& _numPeers,
                                        const unsigned int& _capacityFactor, const unsigned int& _k){
            return cute::ceil_div(_seqLen, _numPeers) * _capacityFactor * _k;
        }


        CUTE_HOST_DEVICE
        void dump() const {
            printf("{\n\t"
                   "\"Capacity\": %u,\n\t"
                   "\"E\": %u,\n\t"
                   "\"H\": %u,\n\t"
                   "\"World\": %u,\n\t"
                   "\"Rank\": %u,\n\t"
                   "\"SB\": %u,\n\t"
                   "\"SequenceNumber\": %lu,\n\t"
                   "\"k\": %u\n}\n",
                   capacity, numExperts, embedDim, worldSize,
                   rank, seqLen, sequenceNumber, k);
        }
    };

    enum class TaskType {
        Interrupt,
        preGEMM,
        postGEMM,
        GateScale
    };

    struct __align__(16) Task {
        // sensible sentinel values
        cuda::std::byte* aData = nullptr;
        cuda::std::byte* bData = nullptr;
        cuda::std::byte* bDataNext = nullptr;
        cuda::std::byte* cData = nullptr;
        cuda::std::byte* dData = nullptr;
        cuda::std::byte* dDataNext = nullptr;
        // crd2Idx(peer, expertIdx, offset)
        unsigned long long int syncIdx = 0UL;
        unsigned int tile = 0U;
        unsigned int M = 0U;
        unsigned long long int packetSize = 0U;
        int peerIdx = 0U;
        bool isPeerRemote = false;
        TaskType taskType = TaskType::Interrupt;

        __forceinline__ __device__
        Task() = default;

        __device__ __forceinline__
        Task(const TaskType& _taskType,
            cuda::std::byte* _aData,
            cuda::std::byte* _bData,
            cuda::std::byte* _bDataNext,
            cuda::std::byte* _cData,
            cuda::std::byte* _dData,
            cuda::std::byte* _dDataNext,
            const unsigned int& _syncIdx,
            const unsigned int& _tile,
            const unsigned int& _M,
            const long long int& _size,
            const bool& _remote,
            const int& _peerIdx):
        aData(_aData), bData(_bData), bDataNext(_bDataNext),
        cData(_cData), dData(_dData), dDataNext(_dDataNext),
        syncIdx(_syncIdx), tile(_tile), M(_M), packetSize(_size), peerIdx(_peerIdx),
        isPeerRemote(_remote), taskType(_taskType){}

        __device__ __forceinline__
        explicit Task(const TaskType& _taskType):
        taskType(_taskType) {}
    };

    struct __align__(16) SchedulerConfig{
        unsigned int* readyQ;
        /// rQS[0] -> head
        /// rQS[1] -> tail
        unsigned int* readyQSignals;
        unsigned long long int* taskSignal;
        unsigned long long int* taskSync;
        Task* taskQ;
        unsigned long long int* taskQSignals;
        unsigned long long int taskBound;

        __forceinline__ __device__
        SchedulerConfig() = default;

        SchedulerConfig(cuda::std::byte* _bk,
               const unsigned int& numberBlocks,
               const unsigned int& _syncTasksBound) {
            readyQ = CAST_TO(unsigned int, _bk);
            readyQSignals = CAST_TO(unsigned int, readyQ + numberBlocks);
            taskSignal = CAST_TO(unsigned long long int, readyQSignals + N_READY_Q_SIGNALS);
            taskSync = CAST_TO(unsigned long long int, taskSignal + numberBlocks);
            taskQSignals = CAST_TO(unsigned long long int, taskSync + _syncTasksBound);
            taskQ = CAST_TO(Task, taskQSignals + N_TASK_Q_SIGNALS);
            taskBound = (STAGES + 1) * _syncTasksBound;
        }
    };

    __constant__ __inline__ uint64_t seqNo;
    __constant__ __inline__ Config moeConfig{};
    __constant__ __inline__ SchedulerConfig schedulerState{};
    __inline__ Config hostMoEConfig;

    __device__
    enum header : unsigned short {
        NOOP = 0,
        processed = 0,
        shouldProcess = 1,
        begin = 2
    };

    __device__
    enum putSignal : uint64_t {
        sent = 1
    };

    template<typename E = header> requires cuda::std::is_integral_v<cuda::std::underlying_type_t<E>>
    CUTE_DEVICE
    uint64_t constructSignal(E const& signal, uint64_t const& tagAlong = 0U){
        return tagAlong + signal + seqNo;
    }
}
#endif //ARISTOS_TYPES_CUH