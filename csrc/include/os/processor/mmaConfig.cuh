//
// Created by oja7 on 11/5/24.
//

#ifndef MMACONFIG_CUH
#define MMACONFIG_CUH

#include <cublasdx.hpp>
#include <cute/arch/copy.hpp>
#include <cute/arch/copy_sm80.hpp>
#include "../../types.cuh"

namespace aristos {
    template<unsigned int Arch, typename TC, typename TA=TC, typename TB=TA>
    requires (Arch >= 700)
    struct MMAConfig {
        using mma = cute::TiledMMA<
                    cute::MMA_Atom<cute::UniversalFMA<TC, TA, TB>>,
                    cute::Layout<cute::Shape<cute::_16, cute::_8, cute::_1>>
        >;
    };

    template<>
    struct MMAConfig<700, cute::half_t> {
        using mma = cute::TiledMMA<
          cute::MMA_Atom<cute::SM70_8x8x4_F16F16F16F16_TN>,
          cute::Layout<cute::Shape<cute::_4, cute::_4, cute::_1>>,
        cute::Tile<cute::_32, cute::_32, cute::_8>
        >;
    };

    template<>
    struct MMAConfig<700, float, cute::half_t> {
        using mma = cute::TiledMMA<
          cute::MMA_Atom<cute::SM70_8x8x4_F32F16F16F32_TN>,
          cute::Layout<cute::Shape<cute::_4, cute::_4, cute::_1>>,
        cute::Tile<cute::_32, cute::_32, cute::_8>
        >;
    };

    template<>
    struct MMAConfig<800, cute::half_t> {
        using mma = cute::TiledMMA<
          cute::MMA_Atom<cute::SM80_16x8x8_F16F16F16F16_TN>,
          cute::Layout<cute::Shape<cute::_2, cute::_2, cute::_1>>,
        cute::Tile<cute::_32, cute::_32, cute::_8>
        >;
    };

    template<>
    struct MMAConfig<800, float, cute::half_t> {
        using mma = cute::TiledMMA<
          cute::MMA_Atom<cute::SM80_16x8x8_F32F16F16F32_TN>,
          cute::Layout<cute::Shape<cute::_2, cute::_2, cute::_1>>,
        cute::Tile<cute::_32, cute::_32, cute::_8>
        >;
    };

    template<>
    struct MMAConfig<800, float, cute::bfloat16_t> {
        using mma = cute::TiledMMA<
          cute::MMA_Atom<cute::SM80_16x8x8_F32BF16BF16F32_TN>,
          cute::Layout<cute::Shape<cute::_2, cute::_2, cute::_1>>,
        cute::Tile<cute::_32, cute::_32, cute::_8>
        >;
    };

    template<>
    struct MMAConfig<800, float, cute::tfloat32_t> {
        using mma = cute::TiledMMA<
          cute::MMA_Atom<cute::SM80_16x8x8_F32TF32TF32F32_TN>,
          cute::Layout<cute::Shape<cute::_2, cute::_2, cute::_1>,
                        cute::Stride<cute::_2, cute::_1, cute::_1>>,
        cute::Tile<cute::_32, cute::_32, cute::_8>
        >;
    };

    template <cublasdx::arrangement a, unsigned int midSwizzle, unsigned int sizeK>
    requires(a == cublasdx::arrangement::row_major
        && (midSwizzle == 2 || midSwizzle == 3) && (sizeK >= 8 && sizeK <= 64))
    struct SwizzleAtom {
        using swizzleAtom =  decltype(
        cute::composition(cute::Swizzle<3, midSwizzle, 3>{},
                    cute::Layout<cute::Shape<cute::_8, cute::Int<sizeK>>,
                           cute::Stride<cute::Int<sizeK>, cute::_1>>{}));
    };

    template<typename Element, unsigned int Arch>
    using copyArch = cuda::std::conditional_t<sizeof(Element) >= 4 && Arch >= 800,
        cute::SM80_CP_ASYNC_CACHEALWAYS<Element>, cute::UniversalCopy<Element>>;

    template<typename Element>
    using sCopyLay = cuda::std::conditional_t<cuda::std::is_same_v<Element, float>,
    cute::UniversalCopy<float>, cuda::std::conditional_t<sizeof(Element) >= 4,
    cute::SM75_U32x4_LDSM_N, cute::SM75_U32x2_LDSM_N>>;

    template<
        typename ElementA,
        typename ElementB,
        unsigned int Arch,
        cublasdx::arrangement a = cublasdx::arrangement::row_major, // T
        cublasdx::arrangement b = cublasdx::arrangement::row_major  // N
    >
    struct CopyOp {
        using copyAT = decltype(cute::make_tiled_copy(
            cute::Copy_Atom<copyArch<ElementA, Arch>, ElementA>{},
            cute::Layout<cute::Shape<cute::_16, cute::_8>,
                cute::Stride<cute::_8, cute::_1>>{},
            cute::Layout<cute::Shape<cute::_1, cute::_1>>{}));

        using copyBN = decltype(cute::make_tiled_copy(
            cute::Copy_Atom<copyArch<ElementB, Arch>, ElementB>{},
            cute::Layout<cute::Shape<cute::_16, cute::_8>,
                cute::Stride<cute::_8, cute::_1>>{},
            cute::Layout<cute::Shape<cute::_1, cute::_1>>{}));

        using copyAN = decltype(cute::make_tiled_copy(
            cute::Copy_Atom<copyArch<ElementA, Arch>, ElementA>{},
            cute::Layout<cute::Shape<cute::_16, cute::_8>>{},
            cute::Layout<cute::Shape<cute::_1, cute::_1>>{}));

        using copyBT = decltype(cute::make_tiled_copy(
            cute::Copy_Atom<copyArch<ElementB, Arch>, ElementB>{},
            cute::Layout<cute::Shape<cute::_16, cute::_8>>{},
            cute::Layout<cute::Shape<cute::_1, cute::_1>>{}));

        using copyA = cuda::std::conditional_t<(a == cublasdx::arrangement::row_major &&
            b == cublasdx::arrangement::row_major), copyAT, copyAN>;
        using copyB = cuda::std::conditional_t<(a == cublasdx::arrangement::row_major &&
            b == cublasdx::arrangement::row_major), copyBN, copyBT>;
    };

    enum class LayoutOptimization {
        UseSwizzle,
        UseVanilla
    };

    template<typename T>
    requires (sizeof(T) == 2 || sizeof(T) == 4)
    using MiddleSwizzle = cute::Int<sizeof(T) == 2 ? 3 : 2>;

    template<
        class GEMM,
        typename ElementA,
        typename ElementB,
        typename ElementC,
        LayoutOptimization lOpt = LayoutOptimization::UseVanilla
    >
    requires (cublasdx::is_complete_blas<GEMM>::value
    && cublasdx::sm_of<GEMM>::value >= MIN_ARCH
    && cublasdx::sm_of<GEMM>::value < 900)
    struct CollectiveMMAConfig{
        static_assert(cublasdx::arrangement_of<GEMM>::a == cublasdx::arrangement::row_major &&
            cublasdx::arrangement_of<GEMM>::b == cublasdx::arrangement::row_major,
            "Only row-major is supported for either A or B");
        using ldA = cuda::std::conditional_t<cublasdx::arrangement_of<GEMM>::a == cublasdx::row_major,
        cute::Int<cublasdx::size_of<GEMM>::k>, cute::Int<cublasdx::size_of<GEMM>::m>>; // A: (m,k)
        using ldB = cuda::std::conditional_t<cublasdx::arrangement_of<GEMM>::b == cublasdx::row_major,
        cute::Int<cublasdx::size_of<GEMM>::k>, cute::Int<cublasdx::size_of<GEMM>::n>>; // B: (n,k)
        using ldC = cuda::std::conditional_t<cublasdx::arrangement_of<GEMM>::c == cublasdx::row_major,
        cute::Int<cublasdx::size_of<GEMM>::n>, cute::Int<cublasdx::size_of<GEMM>::m>>; //C: (m,n)

        using copyAB = CopyOp<
            ElementA,
            ElementB,
            cublasdx::sm_of<GEMM>::value,
            cublasdx::arrangement_of<GEMM>::a,
            cublasdx::arrangement_of<GEMM>::b
        >;

        using gCopyA = typename copyAB::copyA;
        using gCopyB = typename copyAB::copyB;

        using sCopyA = cute::Copy_Atom<cuda::std::conditional_t<cublasdx::sm_of<GEMM>::value < 800,
        cute::AutoVectorizingCopyWithAssumedAlignment<8 * cublasdx::alignment_of<GEMM>::a>,
        sCopyLay<ElementA>>, ElementA>;
        using sCopyB = cute::Copy_Atom<cuda::std::conditional_t<cublasdx::sm_of<GEMM>::value < 800,
        cute::AutoVectorizingCopyWithAssumedAlignment<8 * cublasdx::alignment_of<GEMM>::b>,
        sCopyLay<ElementB>>, ElementB>;
        using sCopyC = cute::Copy_Atom<cute::AutoVectorizingCopyWithAssumedAlignment<8 * cublasdx::alignment_of<GEMM>::c>, ElementC>;

        using vSLayA = cute::Layout<cute::Shape<cute::Int<cublasdx::size_of<GEMM>::m>, cute::Int<cublasdx::size_of<GEMM>::k>>,
        cuda::std::conditional_t<cublasdx::arrangement_of<GEMM>::a == cublasdx::arrangement::col_major,
        cute::Stride<cute::_1, ldA>, cute::Stride<ldA, cute::_1>>>;
        using sLayA = cuda::std::conditional_t<lOpt == LayoutOptimization::UseSwizzle,
        typename SwizzleAtom<cublasdx::arrangement_of<GEMM>::a,
        MiddleSwizzle<ElementA>{}, cublasdx::size_of<GEMM>::k>::swizzleAtom, vSLayA>;

        using vSLayB = cute::Layout<cute::Shape<cute::Int<cublasdx::size_of<GEMM>::n>, cute::Int<cublasdx::size_of<GEMM>::k>>,
        cuda::std::conditional_t<cublasdx::arrangement_of<GEMM>::b == cublasdx::arrangement::col_major,
        cute::Stride<cute::_1, ldB>, cute::Stride<ldB, cute::_1>>>;
        using sLayB = cuda::std::conditional_t<lOpt == LayoutOptimization::UseSwizzle,
        typename SwizzleAtom<cublasdx::arrangement_of<GEMM>::b,
        MiddleSwizzle<ElementB>{}, cublasdx::size_of<GEMM>::k>::swizzleAtom, vSLayB>;

        using sLayC = cute::Layout<cute::Shape<cute::Int<cublasdx::size_of<GEMM>::m>, cute::Int<cublasdx::size_of<GEMM>::n>>,
        cuda::std::conditional_t<cublasdx::arrangement_of<GEMM>::c == cublasdx::arrangement::col_major,
        cute::Stride<cute::_1, ldC>, cute::Stride<ldC, cute::_1>>>;

        using mma_t = typename MMAConfig<cublasdx::sm_of<GEMM>::value, ElementC, ElementA,
        ElementB>::mma;
    };
}
#endif //MMACONFIG_CUH
