//
// Created by Jonathan on 7/18/24.
//

#ifndef ARISTOS_TYPES_CUH
#define ARISTOS_TYPES_CUH

#define ARISTOS_BLOCK_SIZE 128U
#define ARISTOS_BLOCK_SIZE_WARP (128U / 32)
// number of blocks
#define ARISTOS_SUPER_BLOCK_SIZE 32U

#define CAST_TO(T, p) static_cast<T*>(static_cast<void*>(p))
#define CONST_CAST_TO(T, p) static_cast<const T*>(static_cast<const void*>(p))
/// Number of communication stages S
#define STAGES 2U

/// Per stage, there is one cell for sending and another for reception
#define CELLS 2U
#define SEND_CELL 0U
#define RECEIVE_CELL 1U

#define HEAP_ALIGNMENT 16U

// Hardware description
#define MIN_ARCH 700U
#define THREADS 128U
#define WARP_SIZE 32U
#define SUBSCRIBERS (THREADS - WARP_SIZE)
// GEMM configuration constants
#define BLOCK_M 128U
#define BLOCK_M_EXP 64U
#define BLOCK_N 64U
#define BLOCK_K_HALF 16U
#define BLOCK_K_FULL 8U
#define MAX_REGS (BLOCK_M * BLOCK_N) / THREADS
#define GEMMs 2U // per expert

#define TOPO_LOOP_TRIP 4U // this may be too much
#define BETA_BUFFER (1024UL * 1024UL) // 1MB
#define ALPHA_BUFFER 1024UL // 1KB
#define NANO_TO_MILLI (cuda::std::nano::den / cuda::std::milli::den)
#define NANO_TO_MICRO (cuda::std::nano::den / cuda::std::micro::den)
#define BYTE_MAX cuda::std::numeric_limits<cuda::std::underlying_type_t<cuda::std::byte>>::max()
#define TO_MB(b) (static_cast<float>(b) / (1024.0f*1024.0f))
#define BETA_MB 1024.0f // 1GB
#define ARISTOS_DEBUG 1
#define NOOP_SIGNAL 0

#include <cuda/barrier>
#include <cuda/std/array>
#include <cute/numeric/integral_constant.hpp>
#include <cute/tensor.hpp>
#include <cutlass/epilogue/thread/activation.h>

#include "arch.cuh"

namespace aristos{
    template<typename V>
        concept TensorValueType = cuda::std::is_same_v<V, cute::half_t> ||
            cuda::std::is_same_v<V, cute::bfloat16_t> ||
            cuda::std::is_same_v<V, cute::tfloat32_t> ||
            cuda::std::is_same_v<V, float> /*||
            cuda::std::is_same_v<V, cute::float_e4m3_t> ||
            cuda::std::is_same_v<V, cute::float_e5m2_t>*/;

    template <class T>
    struct isTensor : cuda::std::false_type {};
    template <class Engine, class Layout>
    requires(TensorValueType<typename Engine::value_type>)
    struct isTensor<cute::Tensor<Engine,Layout>> : cuda::std::true_type {};
    template <class Engine, class Layout>
    requires(TensorValueType<typename Engine::value_type>)
    struct isTensor<const cute::Tensor<Engine,Layout>> : cuda::std::true_type {};

    template<typename T>
    concept isMatrix = isTensor<T>::value && cuda::std::is_same_v<decltype(rank(T{})), cute::Int<2>>;

    template<typename S>
    struct ToCute {
        using T = S;
        static_assert(aristos::TensorValueType<T>);
    };
    template<>
    struct ToCute<__half> {
        using T = cute::half_t;
    };
    template<>
    struct ToCute<__nv_bfloat16> {
        using T = cute::bfloat16_t;
    };

    template<typename S>
    requires(aristos::TensorValueType<S>)
    struct ToCDx {
        using T = S;
    };
    template<>
    struct ToCDx<cute::tfloat32_t> {
        using T = float;
    };
    template<>
    struct ToCDx<cute::half_t> {
        using T = __half;
    };
    template<>
    struct ToCDx<cute::bfloat16_t> {
        using T = __nv_bfloat16;
    };

    template<unsigned int dType>
    struct DType {
        static_assert(dType <= 3);
    };

    template<>
    struct DType<0U> {
        using DT = float;
    };

    template<>
    struct DType<1U> {
        using DT = cute::tfloat32_t;
    };

    template<>
    struct DType<2U> {
        using DT = cute::bfloat16_t;
    };

    template<>
    struct DType<3U> {
        using DT = cute::half_t;
    };

    template<
        unsigned int aFunction,
        typename Element
    > requires(TensorValueType<Element>)
    struct AFunction {
        static_assert(aFunction <= 2U);
    };

    template<typename Element>
    struct AFunction<0U, Element> {
        using DT = cutlass::epilogue::thread::ReLU<Element>;
    };

    template<typename Element>
    struct AFunction<1U, Element> {
        using DT = cutlass::epilogue::thread::GELU<Element>;
    };

    using mp_t = float; // or tf32
    using GEA = float;
    using specType = unsigned int;
    using flagsType = uint64_t;

    using Nano = cuda::std::chrono::duration<float, cuda::std::nano>;
    using Milli = cuda::std::chrono::duration<float, cuda::std::milli>;
    using ull_t = unsigned long long int;
    static_assert(sizeof(ull_t) == sizeof(flagsType) && alignof(ull_t) == alignof(flagsType));

    struct __align__(8) floatPair {
        float alpha;
        float beta;

        __device__ __forceinline__
        friend bool operator<(const floatPair &lhs, const floatPair &rhs) {
            return fmaf(lhs.beta, BETA_MB, lhs.alpha) < fmaf(rhs.beta, BETA_MB, rhs.alpha);
        }

        __device__ __forceinline__
        friend bool operator<=(const floatPair &lhs, const floatPair &rhs) {
            return rhs >= lhs;
        }

        __device__ __forceinline__
        friend bool operator>(const floatPair &lhs, const floatPair &rhs) {
            return rhs < lhs;
        }

        __device__ __forceinline__
        friend bool operator>=(const floatPair &lhs, const floatPair &rhs) {
            return !(lhs < rhs);
        }
    };

    __device__
    struct __align__(8) TQState {
        uint tQTail;
        uint tasks;
    };

    __device__
    struct __align__(8) TQSignal{
        uint signal; // one ahead
        uint interrupt;

        __device__ __forceinline__
        void encodeSig(const uint& sig) {
            signal = sig + 1;
        }
        __device__ __forceinline__
        auto decodeSig() const {
            return signal - 1;
        }
    };

    // These could be much more, as supported by CUTLASS
    __host__ __device__
    enum ActivationFunction: uint8_t {
        ReLu,
        GeLU
    };

    __device__
    enum class PacketStage: uint {
        initial,
        last,
    };

    __device__
    enum class GateReductionLevel {
        singleBlock,
        multiBlock
    };

    __device__
    enum class PeerConnectivity {
        remote,
        p2p
    };

    __host__ __device__
    enum class UseBarrier {
        yes,
        no
    };

    __device__
    enum class DropTokens {
        yes,
        no
    };

    __device__
    enum ReadySignal : uint {
        observed,
        ready
    };

    __device__
    enum class CombineMode {
        single,
        multithreaded
    };

    __device__
    enum class JobType : uint8_t {
        training,
        inference
    };

    __device__
    enum SchedulerConstants : uint {
        interruptSignal = 0,
        tQHeadGroundState = 0
    };

    struct __align__(4) WorkerAttribute{
        cute::half_t throughput; // expert per ms; could be fractional
        uint16_t memoryCapacity; // upper bound of experts that we can accommodate
    };
    struct __align__(8) TopologySignal{
        unsigned int signal;
        WorkerAttribute wA;
    };

    __device__
    struct __align__(8) RingSoftmaxPayload {
        mp_t mI;
        cute::half_t dI;
        uint16_t signal;
    };
    __device__
    struct __align__(8) RingTopKPayload {
        mp_t sV;
        uint16_t sIdx;
        uint16_t signal;
    };
    
    template<PacketStage p = PacketStage::initial>
    __device__
    struct __align__(8) SignalPayload {
        static_assert(p == PacketStage::initial);
        uint routedTokens;
        uint16_t totalTilesM;
        uint16_t seqBit;

       __device__ __forceinline__
       void dump() const {
            printf("{\n\t"
                   "this: %p,\n\t"
                   "routedTokens: %u,\n\t"
                   "totalTilesM: %u,\n\t"
                   "seqBit: %u"
                   "\n}\n",
                   this, routedTokens, totalTilesM, seqBit);
        }
    };

    template<>
    __device__
    struct __align__(8) SignalPayload<PacketStage::last> {
        uint batchIdx;
        uint16_t tokensM; // <= BLOCK_M
        uint16_t seqBit;

       __device__ __forceinline__
       void dump() const {
            printf("{\n\t"
                   "this: %p,\n\t"
                   "batchIdx: %u,\n\t"
                   "tokensM: %u,\n\t"
                   "seqBit: %u"
                   "\n}\n",
                   this, batchIdx, tokensM, seqBit);
        }
    };

    /// Expert lookup info: key is global expert index
    __device__
    struct __align__(8) ELI {
        uint epRank; // host peer
        uint16_t localExpertIndex;
        uint16_t isRemote;

        __host__ __device__ __forceinline__
        void dump() const {
            printf("{\n\t"
                   "this: %p,\n\t"
                   "epRank: %u,\n\t"
                   "localExpertIndex: %u,\n\t"
                   "isRemote: %s"
                   "\n}\n",
                   this,
                   epRank, localExpertIndex, isRemote ? "True" : "False");
        }
    };

    /// Local expert lookup: key is local expert index
    __device__
    struct __align__(4) LXI {
        uint expertIndex;
        __host__ __device__ __forceinline__
        void dump() const {
            printf("{\n\t"
                   "this: %p\n\t"
                   "expertIndex: %u\n}\n", this, expertIndex);
        }
    };

    /// Peer lookup info: key is ep rank
    __device__
    struct __align__(16) PLI {
        cuda::std::byte* remoteSHeap;
        flagsType* remoteSFlags;
        uint pe;
        uint isRemote;

        __host__ __device__ __forceinline__
        void dump() const {
            printf("{\n\t"
                   "this: %p,\n\t"
                   "remoteSHeap: %p,\n\t"
                   "remoteSFlags: %p,\n\t"
                   "pe: %u,\n\t"
                   "isRemote: %s"
                   "\n}\n",
                   this, remoteSHeap, remoteSFlags, pe, isRemote ? "True" : "False");
        }
    };

    /// Packet Encoding Lookup info, retrievable in a single memory lookup
    /// Key is global expert index
    __device__
    struct __align__(16) PEL {
        cuda::std::byte* remoteSHeap;
        flagsType* remoteSFlags;
        uint eC;
        uint16_t pTTt;
        uint16_t expertLocalIdx;
        uint16_t peer;
        uint16_t pe;
        uint16_t isRemote;
        uint16_t nLocalExperts;

        __host__ __device__ __forceinline__
        void dump() const {
            printf("{\n\t"
                   "this: %p,\n\t"
                   "remoteSHeap: %p,\n\t"
                   "remoteSFlags: %p,\n\t"
                   "eC: %u,\n\t"
                   "pTTt: %u,\n\t"
                   "expertLocalIndex: %u,\n\t"
                   "peer: %u,\n\t"
                   "pe: %u,\n\t"
                   "isRemote: %s,\n\t"
                   "nLocalExperts: %u"
                   "\n}\n",
                   this, remoteSHeap, remoteSFlags, eC, pTTt, expertLocalIdx,
                   peer, pe, isRemote ? "True" : "False", nLocalExperts);
        }
    };

    /// Computes precise number of integers needed to represent a consecutive set of bits
    /// each of T threads has stride ownership of a single bit
    /// and requires an integer to store 32 of such bits.
    template<
        unsigned int T,
        unsigned int integerBitWidth = 32U,
        unsigned int width = integerBitWidth * T
    >
    __host__ __device__ __forceinline__
    constexpr uint nSI(const unsigned int& numBits) {
        return (numBits / width) * T + cute::min(numBits % width, T);
    }

    // Captures transitory states of a finite state machine
    enum SignalConstants : flagsType {
        ground = 0U,
        sequenceStart = 1U,
    };
    __inline__ uint16_t seqBit = sequenceStart;
    /// Aristos Compile-time Config
    struct ACC {
        // Upper bound of allowable early exits
        using AEE = cute::C<0U>;
        using IDZ = cute::C<AEE::value + 1>;
        // Below ensures we can represent all states in the given integer type
        static_assert(2 * AEE::value <= cuda::std::numeric_limits<decltype(seqBit)>::max() - 3);
        // TODO write a proof for the below in the paper
        // sequence bit states necessary to break symmetry in forward or backward detection
        // includes ground state
        using SBS = cute::C<2U * (2U + AEE::value)>;
        using GRL = cute::C<NUM_EXPERTS <= BLOCK_N ? GateReductionLevel::singleBlock :
            GateReductionLevel::multiBlock>;
        using TK = cute::C<E_TOP_K>;
        using CM = cute::C<(E_TOP_K > 1) ? CombineMode::multithreaded : CombineMode::single>;
        using ElementC = float;
        using Element = DType<DTYPE>::DT;
        using DTK = cute::C<DROP_TOKENS? DropTokens::yes : DropTokens::no>;
        using HA = cute::C<HIDDEN_ACT>;
        using ActivationOp = AFunction<HIDDEN_ACT, GEA>::DT;
        using ActivationOpX = cute::identity;
        using PeakHardware = aristos::Hardware<ARISTOS_ARCH, 255>;
        using sharedSize = cute::C<PeakHardware::sharedMemory::value +
            (PeakHardware::spare::value > 2048 ? PeakHardware::spare::value - 2048 : PeakHardware::spare::value)>;
        using GSM = cute::C<cute::max(BLOCK_M * BLOCK_N * 2,
            BLOCK_K_FULL * PeakHardware::pipeStages::value * sizeof(Element) * (BLOCK_M + BLOCK_N))>;
        static_assert(sharedSize::value >= sizeof(mp_t) * BLOCK_M * BLOCK_N / 2);
        using STE = cute::C<sharedSize::value >= BLOCK_M * BLOCK_N * sizeof(mp_t) ? BLOCK_N : BLOCK_N / 2U>;
        using JT = cute::C<IS_TRAINING? JobType::training : JobType::inference>;
        using S = cute::C<SEQ_LEN * MINI_BATCH>;
        using P = cute::C<I_SIZE>;
        using H = cute::C<HIDDEN_SIZE>;
        using E = cute::C<NUM_EXPERTS>;
        static_assert(E::value <= cuda::std::numeric_limits<uint16_t>::max());
        // padded expert dimension
        using PX = cute::C<cute::ceil_div(E::value, BLOCK_N) * BLOCK_N>;
        using L = cute::C<NUM_LAYERS>;
        using F = cute::C<MOE_FREQ>;
        using GB = cute::C<GLOBAL_BATCH>;
        using MB = cute::C<MINI_BATCH>;
        // Global MoE Stages
        using GMS = cute::C<(JT::value == JobType::training ? 3 : 1) *
                (GB::value / MB::value) * (L::value / F::value)>;
        using BPP = cute::C<JT::value == JobType::training ? 2 * sizeof(Element) + 12 : sizeof(Element)>;
        // parameter count
        // source: https://arxiv.org/abs/2401.14489
        using PC = cute::C<H::value * (L::value * (12UL * H::value + 13U) + (VOCAB_SIZE + H::value))>;
        using GRB = cute::C<cute::ceil_div(PC::value, 1024 * 1024)>;
        using P2PB = cute::C<cute::ceil_div(S::value * H::value, 1024 * 1024)>;
        using CF = cute::C<CAP_FACTOR>;
        static_assert(CF::value >= 0);
        static_assert(TK::value <= E::value);
        using EC = cute::C<(DTK::value == DropTokens::no ? S::value : cute::ceil_div(S::value, E::value)) *
            CF::value * TK::value>;
        using pEC = cute::C<cute::ceil_div(EC::value, BLOCK_M) * BLOCK_M>;
        using SZ = cute::C<pEC::value * H::value>;
        using TM = cute::C<cute::ceil_div(S::value, BLOCK_M)>;
        using TN = cute::C<cute::ceil_div(P::value, BLOCK_N)>;
        using TNx = cute::C<cute::ceil_div(H::value, BLOCK_N)>;
        using TCM = cute::C<cute::ceil_div(EC::value, BLOCK_M)>;
        static_assert(TCM::value <= cuda::std::numeric_limits<uint16_t>::max());
        using TPX = cute::C<cute::ceil_div(PX::value, BLOCK_N)>;
        using TSZ = cute::C<TM::value * cute::min(TNx::value, PeakHardware::blocks::value)>;

        // Scheduling state upper bound inside FFN
        using TMU = cute::C<128>;
        using FZ = cute::C<TSZ::value * sizeof(uint) + sizeof(Element) * (S::value * P::value)>;
    };

    /// A more apropos name would be "static storage" rather than registers.
    template<class T>
    struct isRegister : cuda::std::false_type {};

    template<class T, int N, int Alignment>
    struct isRegister<cutlass::AlignedArray<T, N, Alignment>> : cuda::std::true_type {};

    template<class T, int N, bool RegisterSized>
    struct isRegister<cutlass::Array<T, N, RegisterSized>> : cuda::std::true_type {};

    template<class Engine, class Layout>
    struct isRegister<cute::Tensor<Engine, Layout>> :
    cuda::std::conditional_t<cute::is_rmem_v<cute::Tensor<Engine, Layout>>,
    cuda::std::true_type, cuda::std::false_type> {};

    template <class T>
    constexpr bool isRegisterV = isRegister<T>::value;

    // Index and gate combine weight
    struct __align__(8) TPS {
        uint tokenIdx;
        mp_t probability;
    };

    enum class TaskType : uint16_t {
        preGEMM,
        postGEMM,
        combine
    };

    enum class EP {
        yes,
        no
    };

    __device__
    enum class FlagState {
        unidentified,
        identified,
        completed
    };

    // Also applies to shared memory banks
    template<typename Element>
    requires(128 % sizeof(Element) == 0)
    __device__ __forceinline__
    constexpr auto rTCL(uint const& zb) {
        return cute::ceil_div(zb, 128U / sizeof(Element)) * (128U / sizeof(Element));
    }

    struct __align__(16) Task {
        using TST = uint16_t;
        static_assert(BLOCK_M <= cuda::std::numeric_limits<TST>::max());
        // D = A * B + C
        // sensible sentinel values
        const cuda::std::byte* aData = nullptr;
        cuda::std::array<const cuda::std::byte*, GEMMs> bData = {};
        cuda::std::array<cuda::std::byte*, GEMMs> cData = {};
        cuda::std::array<const cuda::std::byte*, GEMMs> dData = {};
        cuda::std::byte* rcData = nullptr;
        flagsType* flags = nullptr;
        // crd2Idx(peer, expertIdx, offset)
        unsigned int syncIdx = 0UL;
        unsigned int tileIdx = 0U;
        //padded
        unsigned int M = 0U;
        unsigned int batchIdx = 0U;
        uint peerIdx = 0U;
        uint expertIdx = 0U;
        uint isPeerRemote = 0U;
        TaskType taskType;
        TST tileSize = 0U; // <= BLOCK_M
        // below pads the struct to a cache line of 128 bytes
        uint padding[6] = {};

        __forceinline__ __device__
        Task() = default;

        // Stage 1
        __device__ __forceinline__
        Task(const TaskType& _taskType,
            const cuda::std::byte* const& _aData,
            const cuda::std::array<const cuda::std::byte*, GEMMs>& _bData,
            const cuda::std::array<cuda::std::byte*, GEMMs>& _cData,
            const cuda::std::array<const cuda::std::byte*, GEMMs>& _dData,
            cuda::std::byte* const& _rcData,
            flagsType* const& _flags,
            const unsigned int& _syncIdx,
            const unsigned int& _tile,
            const unsigned int& _M,
            const uint16_t& _size,
            const unsigned int& _peerIdx,
            const unsigned int& _batchIdx,
            const uint& _isPeerRemote):
        aData(_aData), bData(_bData),
        cData(_cData), dData(_dData), rcData(_rcData), flags(_flags),
        syncIdx(_syncIdx), tileIdx(_tile),  M(_M),
        batchIdx(_batchIdx), peerIdx(_peerIdx), isPeerRemote(_isPeerRemote), taskType(_taskType), tileSize(_size){}

        // Stage 2
        __device__ __forceinline__
        Task(const TaskType& _taskType,
        const cuda::std::byte*  const& _aData,
        const cuda::std::array<const cuda::std::byte*, GEMMs>& _bData,
        const unsigned int& _size,
        const unsigned int& _tile,
        const unsigned int& _expertIdx):
        aData(_aData), bData(_bData), tileIdx(_tile), expertIdx(_expertIdx), taskType(_taskType),
        tileSize(_size){}

        __device__ __forceinline__
        void dump() const {
            printf("{\n\t"
                   "this: %p,\n\t"
                   "aData: %p,\n\t"
                   "bData[0]: %p,\n\t"
                   "bData[1]: %p,\n\t"
                   "cData[0]: %p,\n\t"
                   "cData[1]: %p,\n\t"
                   "dData[0]: %p,\n\t"
                   "dData[1]: %p,\n\t"
                   "rcData: %p,\n\t"
                   "flags: %p,\n\t"
                   "syncIdx: %u,\n\t"
                   "tileIdx: %u,\n\t"
                   "M: %u,\n\t"
                   "batchIdx: %u,\n\t"
                   "peerIdx: %u,\n\t"
                   "expertIdx: %u,\n\t"
                   "isPeerRemote: %s,\n\t"
                   "taskType: %u,\n\t"
                   "tileSize: %u"
                   "\n}\n",
                   this, aData, bData[0], bData[1], cData[0], cData[1],
                   dData[0], dData[1], rcData, flags, syncIdx, tileIdx, M,
                   batchIdx, peerIdx, expertIdx, isPeerRemote ? "True" : "False",
                   taskType, tileSize);
        }
    };
    static_assert(sizeof(Task) == 128);

    /// Information about auxiliary data structures comprising bookkeeping state
    /// Includes length of data structures (arrays) and pointer arithmetic functions
    using BookType = unsigned int;
    struct __align__(16) Bookkeeping {
        /// needed for free
        cuda::std::byte* symHeap = nullptr;
        flagsType* syncArray = nullptr;
        flagsType* syncCount = nullptr;
        flagsType* flags = nullptr;
        cuda::std::byte* sHeap = nullptr;
        /// default type for bookkeeping data structures
        cuda::std::byte *book = nullptr;
        /// gRl + gB + eDsA + sBfC + brs
        unsigned long int bookSize = ACC::FZ::value;
        /// length of gTQHeads
        unsigned int gtQCl = 0U;
        unsigned int sT = 0U;
        /// Block Ring Softmax flags in bytes, non-cumulative
        unsigned int brs = 0UL;
        /// EP rank
        uint rank = 0U;
        /// EP world
        uint world = 0U;
        /// number of local experts
        uint nLx = 0U;
        /// expert slots
        uint xs = 0U;

        __host__ __device__ __forceinline__
        Bookkeeping() = default;

        __host__ __forceinline__
        explicit Bookkeeping(cuda::std::byte* const& _symHeap,
            flagsType* const& _sA,
            flagsType* const& _flags,
            cuda::std::byte* const& _sHeap,
            cuda::std::byte* const& _book,
            const uint& _nLx, // dynamically decided by an optimization algorithm
            const uint& _rank,
            const uint& _world,
            const uint& _xS) : symHeap(_symHeap),
            syncArray(_sA), syncCount(_sA + _world), flags(_flags), sHeap(_sHeap), book(_book), rank(_rank),
            world(_world), nLx(_nLx), xs(_xS){
            constexpr auto TCM = ACC::TCM::value;
            constexpr auto TN = ACC::TN::value;
            constexpr auto blocks = ACC::PeakHardware::OS::processorBlocks::value;
            constexpr auto E = ACC::E::value;
            constexpr auto S = ACC::S::value;
            constexpr auto pEC = ACC::pEC::value;
            constexpr auto P = ACC::P::value;
            constexpr auto TPX = ACC::TPX::value;
            if constexpr (E > 1) {
                gtQCl = world * nLx * TCM;
                // maximum gemm tiles/tasks scheduled by processors
                const auto prT = world * nLx * TCM * ACC::TNx::value;
                // maximum gemm tiles/tasks scheduled by subscriber threads
                static_assert(SUBSCRIBERS % WARP_SIZE == 0);
                const auto tPS = cute::ceil_div(world * nLx, SUBSCRIBERS / WARP_SIZE) *
                        cute::ceil_div(TCM * TN, WARP_SIZE) +
                        cute::ceil_div(TCM * E, SUBSCRIBERS) * ACC::TNx::value;
                sT = tPS * SUBSCRIBERS;
                tQl = sizeof(Task) * (sT + prT);
                tQml = tQl + blocks * sizeof(TQSignal) + E * sizeof(PEL) + sizeof(PLI) * world +
                    sizeof(TPS) * (E * pEC);
                brs = tQml + (ACC::GRL::value == GateReductionLevel::singleBlock ? 0U : S * TPX *
                    (sizeof(RingSoftmaxPayload) + 2 * sizeof(RingTopKPayload)));
                tQXt = brs + sizeof(ELI) * E + sizeof(cuda::barrier<cuda::thread_scope_device>) + sizeof(LXI) * _nLx;
                gRl = tQXt + (ACC::JT::value == JobType::inference ? 0U :
                    sizeof(mp_t) * (2 * E + 1));
                sBfC = gRl + sizeof(BookType) * (1 + (E * TCM * ACC::TNx::value) + blocks +
                    2 * (E + world * nLx * TCM) + 2 * ACC::S::value * ACC::TNx::value);
                bookSize = sBfC + sizeof(ACC::Element) * (ACC::TK::value * S * ACC::H::value + _world * _nLx * pEC * P);
            }
        }

        /// Needed for malloc
        __host__ __forceinline__
        constexpr static unsigned long int bookLength(const unsigned int& _nLx, const unsigned int& _world) {
            constexpr auto TCM = ACC::TCM::value;
            constexpr auto TN = ACC::TN::value;
            constexpr auto blocks = ACC::PeakHardware::OS::processorBlocks::value;
            constexpr auto E = ACC::E::value;
            constexpr auto S = ACC::S::value;
            constexpr auto pEC = ACC::pEC::value;
            constexpr auto P = ACC::P::value;
            constexpr auto TPX = ACC::TPX::value;
            // maximum gemm tiles/tasks scheduled by processors
            const auto prT = _world * _nLx * TCM * ACC::TNx::value;
            static_assert(SUBSCRIBERS % WARP_SIZE == 0);
            // maximum gemm tiles/tasks scheduled by subscriber threads
            const auto tPS = cute::ceil_div(_world * _nLx, SUBSCRIBERS / WARP_SIZE) *
                    cute::ceil_div(TCM * TN, WARP_SIZE) +
                    cute::ceil_div(TCM * E, SUBSCRIBERS) * ACC::TNx::value;
            const auto sT = tPS * SUBSCRIBERS;
            const auto tQl = sizeof(Task) * (sT + prT);
            const auto tQml = tQl + blocks * sizeof(TQSignal) + E * sizeof(PEL) + sizeof(PLI) * _world +
                sizeof(TPS) * (E * pEC);
            const auto brs = tQml + (ACC::GRL::value == GateReductionLevel::singleBlock ? 0U :
                S * TPX * (sizeof(RingSoftmaxPayload) + 2 * sizeof(RingTopKPayload)));
            const auto tQXt = brs + sizeof(ELI) * E + sizeof(cuda::barrier<cuda::thread_scope_device>) +
                sizeof(LXI) * _nLx;
            const auto gRl = tQXt +
                (ACC::JT::value == JobType::inference ? 0U : sizeof(mp_t) * (2 * E + 1));
            const auto sBfC = gRl + sizeof(BookType) * (1 + (E * TCM * ACC::TNx::value) + blocks +
                2 * (E + _world * _nLx * TCM) + 2 * ACC::S::value * ACC::TNx::value);
            return sBfC + sizeof(ACC::Element) * (ACC::TK::value * S * ACC::H::value + _world * _nLx * pEC * P);
        }

        __host__ __forceinline__
        constexpr static unsigned long int bookLength() {
            return ACC::TSZ::value * sizeof(BookType) + sizeof(ACC::Element) * (ACC::S::value * ACC::P::value);
        }

        template<unsigned int tileDimension>
        __host__ __device__ __forceinline__
        static constexpr unsigned int pad(const unsigned int& dimension) {
            // find next multiple of dimension.
            return cute::ceil_div(dimension, tileDimension) * tileDimension;
        }

        template<unsigned int tileDimension>
        __host__ __device__ __forceinline__
        static constexpr unsigned int tiles(const unsigned int& dimension) {
            // find next multiple of dimension.
            return cute::ceil_div(dimension, tileDimension);
        }

        /**********Salami slice Pointers!************/
        /// stride task queue
        __device__ __forceinline__
        auto* tQ() const {
            return CAST_TO(Task, book);
        }
        /// blocked
        __device__ __forceinline__
        auto* ptQ() const {
            return tQ() + sT;
        }
        static_assert(alignof(Task) % alignof(PEL) == 0);
        __host__ __device__ __forceinline__
        auto* pEL() const {
            return CAST_TO(PEL, book + tQl);
        }
        static_assert(alignof(PEL) % alignof(PLI) == 0);
        __host__ __device__ __forceinline__
        auto* pL() const {
            return CAST_TO(PLI, pEL() + ACC::E::value);
        }
        static_assert(alignof(PLI) % alignof(TPS) == 0);
        __host__ __device__ __forceinline__
        auto* tP() const {
            return CAST_TO(TPS, pL() + world);
        }
        static_assert(alignof(TPS) % alignof(TQSignal) == 0);
        /// processors' doorbell
        __device__ __forceinline__
        auto* pDB() const {
            return CAST_TO(TQSignal, tP() + ACC::E::value * ACC::pEC::value);
        }

        static_assert(alignof(ull_t) % alignof(RingSoftmaxPayload) == 0
            && alignof(ull_t) % alignof(RingTopKPayload) == 0
            && alignof(RingSoftmaxPayload) % alignof(RingTopKPayload) == 0);
        /***********CONTIGUOUS**************/
        __device__ __forceinline__
        auto* gateBk() const {
            static_assert(sizeof(uint2) == sizeof(RingSoftmaxPayload) &&
                sizeof(uint2) == sizeof(RingTopKPayload) &&
                alignof(uint2) % alignof(RingSoftmaxPayload) == 0 &&
                sizeof(uint2) % sizeof(RingTopKPayload) == 0);
            // Entrypoint for vectorized memory cleaning
            return CAST_TO(uint2, book + tQml);
        }
        __device__ __forceinline__
        static constexpr auto gateBkz() {
            // Entrypoint for vectorized memory cleaning
            return 3 * ACC::S::value * ACC::TPX::value;
        }
        __device__ __forceinline__
        auto* bRsP() const {
            return CAST_TO(RingSoftmaxPayload, gateBk());
        }
        /// Ring top k flags
        /// Two sets for pipelining termination phase of round i and initial phase of round i + 1
        __device__ __forceinline__
        auto* rTp() const {
            return CAST_TO(RingTopKPayload, bRsP() + ACC::S::value * ACC::TPX::value);
        }
        /***********CONTIGUOUS**************/

        static_assert(alignof(RingTopKPayload) % alignof(cuda::barrier<cuda::thread_scope_device>) == 0);
        /// Device-wide barrier
        __host__ __device__ __forceinline__
        auto* dB() const {
            return CAST_TO(cuda::barrier<cuda::thread_scope_device>, book + brs);
        }
        static_assert(alignof(cuda::barrier<cuda::thread_scope_device>) % alignof(ELI) == 0);
        /// Expert Lookup
        /// expert index -> ELI
        __host__ __device__ __forceinline__
        auto* eL() const {
            return CAST_TO(ELI, dB() + 1);
        }

        static_assert(alignof(ELI) % alignof(LXI) == 0);
        __host__ __device__ __forceinline__
        auto* lX() const {
            return CAST_TO(LXI, eL() + ACC::E::value);
        }

        static_assert(alignof(PLI) % alignof(mp_t) == 0);
        /// entrypoint for clearing
        __device__ __forceinline__
        auto* gBp() const {
            return CAST_TO(mp_t, book + tQXt);
        }
        __device__ __forceinline__
        static constexpr auto gBz() {
            return 2 * ACC::E::value + 1;
        }
        /***********CONTIGUOUS**************/
        /// Gate mean logits
        __device__ __forceinline__
        auto* gML() const {
            return CAST_TO(mp_t, book + tQXt);
        }
        /// Gate mean expert counts
        __device__ __forceinline__
        auto* gMeC() const {
            return gML() + ACC::E::value;
        }
        /// Gate loss
        __device__ __forceinline__
        auto* gL() const {
            return gMeC() + ACC::E::value;
        }
        /***********CONTIGUOUS**************/

        static_assert(alignof(mp_t) % alignof(BookType) == 0);
        /// second stage flag count
        __host__ __device__ __forceinline__
        auto* ssFc() const {
            return CAST_TO(BookType, book + gRl);
        }

        /// Scheduler buffers and flag checkpoints
        __host__ __device__ __forceinline__
        auto* tIx() const {
            return ssFc() + 1;
        }

        __host__ __device__ __forceinline__
        auto* sQ() const {
            return tIx() + ACC::E::value * ACC::TCM::value * ACC::TNx::value;
        }

        /// entrypoint for clearing
        __device__ __forceinline__
        auto* sBp() const {
            return sQ() + ACC::PeakHardware::OS::processorBlocks::value;
        }
        __device__ __forceinline__
        constexpr auto sBz() const {
            return 2 * (ACC::E::value + world * nLx * ACC::TCM::value);
        }
        /***********CONTIGUOUS**************/
        __host__ __device__ __forceinline__
        auto* eC() const {
            return sQ() + ACC::PeakHardware::OS::processorBlocks::value;
        }
        __device__ __forceinline__
        auto* tQH() const {
            return eC() + ACC::E::value;
        }
        /// Packet Sync array
        __device__ __forceinline__
        auto* pSA() const {
            return tQH() + world * nLx * ACC::TCM::value;
        }
        /// tile sync array
        __device__ __forceinline__
        auto* tSA() const {
            return pSA() + ACC::E::value;
        }
        /***********CONTIGUOUS**************/

        // Intermediate buffer
        static_assert(alignof(BookType) % alignof(ACC::Element) == 0);
        __device__ __forceinline__
        auto* xM() const {
            return book + sBfC;
        }

        private:
            /// Scheduler buffers in bytes
            unsigned long int sBfC = ACC::FZ::value;
            unsigned long int tQXt = 0UL;
            /// gate routing and loss vectors in bytes
            unsigned long int gRl = 0U;
            /// Task Q maximum length
            unsigned int tQml = 0U;
            /// Task Q length
            unsigned int tQl = 0U;
    };

    __constant__ __inline__ Bookkeeping bookkeeping{};
    __inline__ Bookkeeping hostBookkeeping{};
    __inline__ bool isInitialized = false;
    __inline__ auto aristosStream = cudaStreamPerThread;

    namespace heap {
        /// The symmetric heap is a 5-D tensor (P, S, C, E, EC) of tokens,
        /// where P, S, C, E, EC denote dimensions for peers, communication stages,
        /// cells, experts, expert capacity, respectively.
        template<
            unsigned int stage,
            unsigned int cell,
            /*The user should not specify the parameters below*/
            unsigned long int EC = ACC::pEC::value,
            unsigned long int H = ACC::H::value,
            unsigned long int B = sizeof(ACC::Element)
        >
        requires (stage < STAGES && cell < CELLS)
        __device__ __forceinline__
        constexpr auto* advance(cuda::std::byte* __restrict__ const& sHeap, const uint& peer,
            const uint& expert, const uint& token = 0){
            return sHeap + B * H * (EC * (CELLS * (STAGES * (peer * bookkeeping.xs + expert) + stage) + cell) + token);
        }
    }
    struct __align__(4) BitSet {
        uint storage = 0U;
        __device__ __forceinline__
        constexpr auto get(const uint& idx) const {
            return storage >> idx & 1U;
        }
        __device__ __forceinline__
        constexpr void set(const uint& idx) {
            storage |= 1U << idx;
        }
    };
    // sequence bits' state
    namespace sbs {
        __forceinline__ __host__
        constexpr uint16_t next(const uint16_t& current) {
            return current + 1 == ACC::SBS::value ?
                static_cast<decltype(current)>(sequenceStart) : current + 1;
        }

        __forceinline__ __device__
        constexpr auto ahead(const uint16_t& receivedState, const uint16_t& localState) {
            if (receivedState < sequenceStart) {
                // this is the case, when we observe the ground state
                return false;
            }
            const auto wD =  (ACC::SBS::value - localState) + (receivedState -
                static_cast<decltype(receivedState)>(sequenceStart));
            return (receivedState > localState && ((receivedState - localState) <= ACC::IDZ::value)) ||
                (receivedState < localState && wD <= ACC::IDZ::value);
        }
    }
    enum class DQType {
        stride,
        block
    };
    /// Decoupled Queue, comprises tail and doorbell
    namespace DQ {
        template<
            DQType dqt = DQType::stride,
            unsigned int nQ = SUBSCRIBERS
        >
        __device__ __forceinline__
        constexpr auto next(const uint& prev, const uint& slot) {
            if constexpr (dqt == DQType::stride) {
                return prev + slot * nQ;
            }
            return prev + slot;
        }
        template<
            DQType dqt = DQType::stride,
            unsigned int nQ = SUBSCRIBERS
        >
        __device__ __forceinline__
        constexpr auto sNext(const uint& slot) {
            return next<dqt, nQ>(0, slot);
        }
    }
}
#endif //ARISTOS_TYPES_CUH
