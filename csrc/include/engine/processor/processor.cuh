//
// Created by osayamen on 7/13/24.
//

#ifndef ARISTOS_COMPUTE_CUH
#define ARISTOS_COMPUTE_CUH

#include <cutlass/epilogue/thread/activation.h>
#include <cutlass/gemm/collective/collective_mma.hpp>
#include "mmaConfig.cuh"

#define SHARED_SIZE 16 * 1024UL

namespace aristos::processor{
    template<
        unsigned int Arch,
        typename ElementA,
        typename ElementB,
        typename ElementC = float,
        typename ActivationOp = cute::identity>
    struct ProcessorGEMM {
        using GEMM = decltype(cublasdx::Size<BLOCK_M, BLOCK_N, BLOCK_K_FULL>()
                              + cublasdx::Precision<toCDX<ElementA>, toCDX<ElementB>, toCDX<ElementC>>()
                              + cublasdx::Type<cublasdx::type::real>()
                              + cublasdx::Arrangement<cublasdx::row_major, cublasdx::row_major, cublasdx::row_major>()
                              + cublasdx::Function<cublasdx::function::MM>()
                              + cublasdx::SM<Arch>()
                              + cublasdx::Block()
                              + cublasdx::BlockDim<THREADS>());
        using MatrixAType = ElementA;
        using MatrixBType = ElementB;
        using MatrixCType = ElementC;
        using MatrixDType = ElementA;
        using BlockTiler = cute::Shape<cute::Int<cublasdx::size_of<GEMM>::m>,
                                        cute::Int<cublasdx::size_of<GEMM>::n>,
                                        cute::Int<cublasdx::size_of<GEMM>::k>>;
        using TilerOut = cute::Shape<cute::Int<cublasdx::size_of<GEMM>::m>, cute::Int<cublasdx::size_of<GEMM>::n>>;
        using Parameters = CollectiveMMAConfig<GEMM, LayoutOptimization::UseSwizzle>;
        using MMA = typename Parameters::mma_t;
        using CollectiveMainloop = cutlass::gemm::collective::CollectiveMma<
            typename Parameters::dispatch,
            BlockTiler,
            ElementA,
            cute::Underscore,
            ElementB,
            cute::Underscore,
            typename Parameters::mma_t,
            typename Parameters::gCopyA,
            typename Parameters::sLayA,
            typename Parameters::sCopyA,
            cute::identity,
            typename Parameters::gCopyB,
            typename Parameters::sLayB,
            typename Parameters::sCopyB,
            cute::identity
        >;

        using EpilogueOp = ActivationOp;
        // TODO CollectiveMMA support for Hopper
    };

    template <typename Element, typename ActivationFunction>
    requires(cuda::std::is_same_v<Element, cute::half_t> ||
        cuda::std::is_same_v<Element, cute::bfloat16_t> ||
        cuda::std::is_same_v<Element, cute::tfloat32_t> ||
        cuda::std::is_same_v<Element, float> ||
        cuda::std::is_same_v<Element, cute::float_e4m3_t> ||
        cuda::std::is_same_v<Element, cute::float_e5m2_t>)
    CUTE_DEVICE
    auto fusedAddActivate(Element& accumulator, const Element& term, const ActivationFunction& op) {
            if constexpr (sizeof(Element) >= 4) {
                return op(fma(Element(1.0f), accumulator, term));
            }
            if constexpr(sizeof(Element) == 2) {
                // Half FMA
                if constexpr (cuda::std::is_same_v<Element, cute::half_t>) {
                    return op(cute::half_t(__hfma(__half(1.0f), accumulator.to_half(), term.to_half())));
                }
                // bfloat16 FMA
                return op(cute::bfloat16_t(__hfma(__nv_bfloat16(1.0f), accumulator.to_nv_bfloat16(), term.to_nv_bfloat16())));
            }
            return op(accumulator + term);
        }

    // conversion operators are reinterpret casts, so technically should be free at runtime
    template<>
    CUTE_DEVICE
    auto fusedAddActivate(cute::half_t& accumulator, const cute::half_t& term,
        const cutlass::epilogue::thread::ReLU<cute::half_t>& op) {
        return cute::half_t(__hfma_relu(__half(1.0f),
            accumulator.to_half(), term.to_half()));
    }

    template<>
    CUTE_DEVICE
    auto fusedAddActivate(cute::bfloat16_t& accumulator, const cute::bfloat16_t& term,
        const cutlass::epilogue::thread::ReLU<cute::bfloat16_t>& op) {
        return cute::bfloat16_t(__hfma_relu(__nv_bfloat16(1.0f),
            accumulator.to_nv_bfloat16(), term.to_nv_bfloat16()));
    }

    // Fused GEMM, Epilogue and Data transfer
    template<
        unsigned int sharedSize,
        typename BlockGEMM,
        class FrgTensorD>
    __forceinline__ __device__
    void fGET(FrgTensorD accumulator,
        const typename BlockGEMM::MatrixAType* __restrict__ inputs,
        const typename BlockGEMM::MatrixBType* __restrict__ weights,
        typename BlockGEMM::MatrixDType* __restrict__ output,
        const typename BlockGEMM::MatrixDType* __restrict__ bias,
        const unsigned int& M,
        const unsigned int& N,
        const unsigned int& K,
        const unsigned int& tileIdx) {
        // Instantiate mainloop
        typename BlockGEMM::CollectiveMainloop mainLoop{};
        cute::clear(accumulator);

        // Row-major
        auto mA = make_tensor(cute::make_gmem_ptr(inputs),
            make_layout(cute::make_shape(M, K), cute::make_stride(K, 1)));
        // Row-major, transposed
        auto mB = make_tensor(cute::make_gmem_ptr(weights),
            make_layout(cute::make_shape(N, K), cute::make_stride(K, 1)));
        // Row-major
        auto mC = make_tensor(cute::make_gmem_ptr(output,
            make_layout(cute::make_shape(M, N), cute::make_stride(N, 1))));
        auto mD = make_tensor(cute::make_gmem_ptr(bias),
            make_layout(cute::make_shape(M, N), cute::make_stride(0, 1)));

        auto tileCoord = idx2crd(tileIdx, cute::Shape(M, N), cute::Stride(N ,1));
        auto ctaCoord = make_coord(cute::get<0>(tileCoord), cute::get<1>(tileCoord), cute::_);
        auto gA = cute::local_tile(mA, typename BlockGEMM::BlockTiler{}, ctaCoord, cute::Step<cute::_1, cute::X,cute::_1>{});
        auto gB = cute::local_tile(mB, typename BlockGEMM::BlockTiler{}, ctaCoord, cute::Step< cute::X,cute::_1,cute::_1>{});
        auto gC = cute::local_tile(mC, typename BlockGEMM::BlockTiler{}, ctaCoord, cute::Step<cute::_1,cute::_1, cute::X>{});
        auto gD = cute::local_tile(mD, typename BlockGEMM::BlockTiler{}, ctaCoord, cute::Step<cute::_1,cute::_1, cute::X>{});

        auto k_tile_iter = cute::make_coord_iterator(size<2>(gA));
        int k_tile_count = size<2>(gA);

        extern __shared__ typename BlockGEMM::MatrixCType scratch[];
        mainLoop(
            accumulator,
            gA,
            gB,
            accumulator,
            k_tile_iter, k_tile_count,
            cute::Underscore{},
            threadIdx.x,
            CAST_TO(char, scratch));

        // Ensure shared memory is ready for reuse
        __syncthreads();

        // Epilogue
        typename BlockGEMM::MMA tiledMMA{};
        auto tCgC = tiledMMA.get_slice(threadIdx.x).partition_C(gC);
        auto tDgD = tiledMMA.get_slice(threadIdx.x).partition_C(gD);

        // Accounts for GEMMs that accumulate in types differing from input types,
        // given that the result moonlights as the input for the succeeding GEMM.
        auto gCStoreOp = cutlass::NumericConverter<typename decltype(tCgC)::value_type,
                                                    typename decltype(accumulator)::value_type>{};
        auto gDLoadOp = cutlass::NumericConverter<typename decltype(accumulator)::value_type,
                                                    typename decltype(tDgD)::value_type>{};

        // Assume elementwise operator
        typename BlockGEMM::EpilogueOp epilogueOp{};
        constexpr auto elemsBytes = sharedSize / THREADS;
        constexpr auto trips = size(accumulator) * sizeof(typename BlockGEMM::MatrixCType) / elemsBytes;
        constexpr auto elems = elemsBytes / sizeof(typename BlockGEMM::MatrixCType);

        #pragma unroll
        for (unsigned int i = 0; i < trips; ++i) {
            // Prefetch from global to shared memory that will be reused per trip
            // Use addressing that minimizes bank conflicts in shared memory
            #pragma unroll
            for (unsigned int j = 0; j < elems; ++j) {
                scratch[threadIdx.x + j * THREADS] = gDLoadOp(tDgD(j + i * elems));
            }
            // Fused Bias Add and Activation Function on register fragment
            // Also fuses copy to GMEM, which is where things get interesting
            #pragma unroll
            for (int j = 0; j < elems; ++j) {
                tCgC(j + i * elems) = gCStoreOp(fusedAddActivate(accumulator(j + i * elems),
                    scratch[threadIdx.x + j * THREADS], epilogueOp));
            }
        }

        __syncthreads();
        if (!threadIdx.x) {
            // The above GMEM copy could be local or p2p,
            // with the latter being a direct store to an NVLink-connected peer.
            // Thus, we must use a memory fence that spans all such cases.
            __threadfence_system();
        }
        __syncthreads();
    }

    template<
        unsigned int processorCount,
        unsigned int Arch,
        unsigned int sharedSize,
        typename ElementA,
        typename ElementB,
        typename ElementC = float,
        typename ActivationOp = cute::identity
    > requires(processorCount > 0 && Arch >= MIN_ARCH)
    __device__ __forceinline__
    void start(){
        __shared__ unsigned long long int signal;
        __shared__ Task currentTask;
        __shared__ bool interrupt[ARISTOS_BLOCK_SIZE];
        interrupt[threadIdx.x] = false;
        atomicExch(&signal, 0UL);
        using Operation = ProcessorGEMM<Arch, ElementA, ElementB, ElementC, ActivationOp>;
        auto accumulator = cute::partition_fragment_C(typename Operation::MMA{}, typename Operation::TilerOut{});

        while (!interrupt[threadIdx.x]) {
            // Indicate readiness
            schedulerState.readyQ[atomicAdd(schedulerState.readyQSignals, 1U) % processorCount] = blockIdx.x;
            if (!threadIdx.x) {
                // Grabs next task
                auto nextTask = atomicLoad(schedulerState.taskQSignals + blockIdx.x);
                while (nextTask == signal) {
                    nextTask = atomicLoad(schedulerState.taskQSignals + blockIdx.x);
                }
                signal = nextTask;
                currentTask = schedulerState.taskQ[signal - 1];
            }
            __syncthreads();
            switch (currentTask.taskType) {
                case TaskType::preGEMM: {
                    fGET<sharedSize, Operation>(accumulator,
                        CAST_TO(typename Operation::MatrixAType, currentTask.aData),
                        CAST_TO(typename Operation::MatrixBType, currentTask.bData),
                        CAST_TO(typename Operation::MatrixDType, currentTask.cData),
                        CAST_TO(typename Operation::MatrixDType, currentTask.dData),
                        currentTask.M,
                        moeConfig.upProjection,
                        moeConfig.embedDim,
                        currentTask.tile);
                    if (threadIdx.x == 1 &&
                        atomicAdd(schedulerState.taskSync + currentTask.syncIdx, 1U) == moeConfig.tilesN) {
                        // Enqueue next tasks
                    }
                }
                break;
                case TaskType::postGEMM: {
                    fGET<sharedSize, Operation>(accumulator,
                        CAST_TO(typename Operation::MatrixAType, currentTask.aData),
                        CAST_TO(typename Operation::MatrixBType, currentTask.bData),
                        CAST_TO(typename Operation::MatrixDType, currentTask.cData),
                        CAST_TO(typename Operation::MatrixDType, currentTask.dData),
                        currentTask.M,
                        moeConfig.embedDim,
                        moeConfig.upProjection,
                        currentTask.tile);
                    if (threadIdx.x == 1) {
                        if (currentTask.isPeerRemote) {
                            nvshmem_putmem(currentTask.cData, currentTask.cData,
                                sizeof(Operation::MatrixDType) * currentTask.packetSize, currentTask.peerIdx);
                        }
                        if (atomicAdd(schedulerState.taskSync + currentTask.syncIdx, 1U)
                            == 2 * moeConfig.tilesN) {
                            nvshmemx_signal_op(moeConfig.flags + moeConfig.worldSize + currentTask.peerIdx,
                                constructSignal(processed), NVSHMEM_SIGNAL_SET, currentTask.peerIdx);
                        }
                    }
                }
                break;
                case TaskType::GateScale: {
                    // Do scale
                    // TODO read GShard paper for this op
                }
                break;
                case TaskType::Interrupt:
                    interrupt[threadIdx.x] = true;
            }
        }
    }
}
#endif //ARISTOS_COMPUTE_CUH