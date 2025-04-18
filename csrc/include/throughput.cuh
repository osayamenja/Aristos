//
// Created by oja7 on 2/15/25.
//

#ifndef THROUGHPUT_CUH
#define THROUGHPUT_CUH

#include <fmt/ranges.h>
#include <thrust/device_vector.h>
#include <thrust/generate.h>
#include <thrust/host_vector.h>
#include <thrust/random.h>

#include "debug.cuh"
#include "moe/expert.cuh"
#include "telemetry.cuh"
#include "types.cuh"
#define TIME_EXPERT 0
namespace aristos {
    template<unsigned int n, typename Container>
    requires(std::is_floating_point_v<typename Container::value_type> ||
        std::is_integral_v<typename Container::value_type> ||
        TensorValueType<typename Container::value_type>)
    __host__ __forceinline__
    auto findMedian(Container& container) {
        using Element = typename Container::value_type;
        if (container.empty()) {
            return static_cast<Element>(0.0f);
        }

        constexpr int mid = n / 2;
        std::nth_element(container.begin(), container.begin() + mid, container.end());

        if constexpr (n % 2 == 0) {
            // Even number of elements, average the two middle elements
            std::nth_element(container.begin(), container.begin() + mid - 1, container.end());
            return static_cast<Element>(container[mid - 1] + container[mid]) / static_cast<Element>(2.0f);
        } else {
            // Odd number of elements, the median is the middle element
            return static_cast<Element>(container[mid]);
        }
    }
    template<
        UseBarrier u,
        unsigned int trials,
        unsigned int N = ACC::P::value,
        unsigned int K = ACC::H::value,
        unsigned int blocks = ACC::PeakHardware::OS::processorBlocks::value,
        unsigned int threads = ACC::PeakHardware::OS::threads::value,
        CombineMode c = ACC::CM::value,
        typename Element,
        unsigned int skip = 64
    >
    requires(trials > 0)
    __host__ __forceinline__
    void mFT(unsigned int const& M,
        cuda::barrier<cuda::thread_scope_device>* __restrict__ const& dB,
        float* __restrict__ const& deviceThroughput, uint* __restrict__ const& tileSync,
        const Element* __restrict__ const& iP /* A, B, D, S, W*/, Element* __restrict__ const& oP /*C*/) {
        #if ARISTOS_NVTX
        aristosRange mFTRange{__func__};
        #endif
        const auto tSz = sizeof(uint) * (M / BLOCK_M) * cute::min(K / BLOCK_N, blocks);
        #pragma unroll
        for (uint i = 0; i < skip; ++i) {
            expert<u, N, K><<<blocks, threads, 0, aristosStream>>>(M, dB, deviceThroughput, tileSync, iP, oP);
            if constexpr (u == UseBarrier::no) {
                CHECK_ERROR_EXIT(cudaMemsetAsync(tileSync, 0, tSz, aristosStream));
            }
            // Needed to clear accumulator buffer
            if constexpr (c == CombineMode::multithreaded) {
                CHECK_ERROR_EXIT(cudaMemsetAsync(oP + M * N, 0, sizeof(Element) * (M * K),
                    aristosStream));
            }
        }
        #pragma unroll
        for (uint i = 0; i < trials; ++i) {
            expert<u, N, K><<<blocks, threads, 0, aristosStream>>>(M, dB,
                deviceThroughput + i, tileSync, iP, oP, false);
            if constexpr (u == UseBarrier::no) {
                CHECK_ERROR_EXIT(cudaMemsetAsync(tileSync, 0, tSz, aristosStream));
            }
            // Needed to clear accumulator buffer
            if constexpr (c == CombineMode::multithreaded) {
                CHECK_ERROR_EXIT(cudaMemsetAsync(oP + M * N, 0, sizeof(Element) * (M * K),
                    aristosStream));
            }
        }
        CHECK_ERROR_EXIT(cudaPeekAtLastError());
    }
    template<
        UseBarrier u = UseBarrier::no,
        unsigned int trials = 16U
    >
    __host__ __forceinline__
    void mT(WorkerAttribute* __restrict__ const& dWa) {
        #if ARISTOS_NVTX
        aristosRange mTRange{__PRETTY_FUNCTION__};
        #endif
        constexpr unsigned int M = ACC::pEC::value;
        constexpr unsigned int N = ACC::P::value;
        constexpr unsigned int K = ACC::H::value;
        using Element = ACC::Element;

        constexpr auto aZ =  M * K;
        constexpr auto bZ =  aZ + N * K;
        constexpr auto b2Z =  bZ + N * K;
        constexpr auto dZ =  b2Z + N;
        constexpr auto d2Z =  dZ + K;
        constexpr auto sZ =  d2Z + M;
        constexpr auto cWz =  sZ + M;

        constexpr auto cZ =  cWz + M * N;
        constexpr auto hZ =  cZ + M * K;

        cuda::std::byte* p;
        constexpr unsigned int blocks = ACC::PeakHardware::OS::processorBlocks::value;
        // Scheduling state
        constexpr auto tSz = sizeof(uint) * ACC::TM::value * cute::min(ACC::TNx::value, blocks);
        constexpr auto stateSize = sizeof(cuda::barrier<cuda::thread_scope_device>) +
            sizeof(float) * trials + tSz;
        constexpr auto dMz = stateSize + hZ * sizeof(Element);
        CHECK_ERROR_EXIT(cudaMallocAsync(&p, dMz, aristosStream));
        CHECK_ERROR_EXIT(cudaMemsetAsync(p, 0, stateSize, aristosStream));
        const auto hB = new cuda::barrier<cuda::thread_scope_device>{blocks};
        CHECK_ERROR_EXIT(cudaMemcpyAsync(p, hB,
            sizeof(cuda::barrier<cuda::thread_scope_device>),
            cudaMemcpyHostToDevice, aristosStream));

        thrust::default_random_engine rng(42);
        thrust::normal_distribution<float> dist(2,3);
        thrust::host_vector<float> hV(cWz);
        thrust::generate(hV.begin(), hV.end(), [&] { return dist(rng); });
        constexpr cutlass::NumericConverter<Element, float> conv{};
        auto* hVd = CAST_TO(Element, hV.data());
        #pragma unroll 16
        for (uint i = 0; i < cWz; ++i) {
            hVd[i] = conv(hV[i]);
        }
        CHECK_ERROR_EXIT(cudaMemcpyAsync(p + stateSize, hVd,
            cWz * sizeof(Element), cudaMemcpyHostToDevice, aristosStream));

        auto* __restrict__ dB = CAST_TO(cuda::barrier<cuda::thread_scope_device>, p);
        static_assert(alignof(cuda::barrier<cuda::thread_scope_device>) % alignof(float) == 0);
        auto* __restrict__ deviceThroughput = CAST_TO(float, dB + 1);
        static_assert(alignof(float) % alignof(uint) == 0);
        auto* __restrict__ tileSync = CAST_TO(uint, deviceThroughput + trials);
        static_assert(alignof(uint) % alignof(Element) == 0);
        const auto* __restrict__ iP = CAST_TO(Element, p + stateSize);
        auto* __restrict__ oP = CAST_TO(Element, p + stateSize) + cWz;
        mFT<u, trials>(M, dB, deviceThroughput, tileSync, iP, oP);
        std::array<float, trials> latency{};
        CHECK_ERROR_EXIT(cudaMemcpyAsync(latency.data(), deviceThroughput,
            sizeof(float) * trials,
            cudaMemcpyDeviceToHost, aristosStream));
        CHECK_ERROR_EXIT(cudaStreamSynchronize(aristosStream));
        const float throughput = 1.0f / findMedian<trials>(latency);
        dWa->throughput = cute::half_t(throughput); // latency should be > 0
        CHECK_ERROR_EXIT(cudaFreeAsync(p, aristosStream));
        delete hB;
    }
}
#endif //THROUGHPUT_CUH
