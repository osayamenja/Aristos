//
// Created by Jonathan on 7/21/24.
//

#ifndef ARISTOS_MEMORY_LAYOUT_CUH
#define ARISTOS_MEMORY_LAYOUT_CUH

namespace aristos{
    /// header
    /// NVSHMEM uses size_t
    /// See https://docs.nvidia.com/nvshmem/api/gen/api/rma.html#nvshmem-put-nbi
    /// But atomicAdd() requires ull
    using n_bytes_repr = unsigned long long int;

    /// Number of bytes for n_bytes_repr
    __constant__ constexpr size_t header_bytes = sizeof(n_bytes_repr);

    /// Number of bytes for micro_header, namely k from top_k.
    /// Of course, 32 bits is overkill, since practical systems use k in [1,2].
    /// However, we desire encouraging much larger k, thus we adopt uint.
    __constant__ constexpr size_t micro_header_bytes = sizeof(unsigned int);

    /// Number of communication stages
    __constant__ constexpr unsigned int stages = 2;

    /// Per stage, there is one cell for send and another for receive
    __constant__ constexpr unsigned int n_cells = 2;

    /// Per embedding vector a la token
    /// k is top_k, +1 for token index, and *4 for unsigned int precision
    CUTE_HOST_DEVICE
    constexpr unsigned int trailer_length_bytes(uint k){
        return (k + 1) * 4;
    }

    template<bool isPrimingStage=false>
    CUTE_HOST_DEVICE
    size_t cell_span(){
        return (stages - 1);
    }

    /// Special case
    template<>
    CUTE_HOST_DEVICE
    size_t cell_span<true>(){
        return 1;
    }

    template<bool isPrimingStage=false>
    CUTE_HOST_DEVICE
    size_t header_size(){
        return micro_header_bytes;
    }

    /// Special case
    template<>
    CUTE_HOST_DEVICE
    size_t header_size<true>(){
        return header_bytes;
    }

    template<bool isPrimingStage=false>
    CUTE_HOST_DEVICE
    size_t packet_bytes(const unsigned int capacity,
                        const unsigned int embed_bytes,
                        const unsigned int trailer_len){
        return capacity * (header_size<false>() + embed_bytes + trailer_len);
    }

    /// Special case
    template<>
    CUTE_HOST_DEVICE
    size_t packet_bytes<true>(const unsigned int capacity,
                               const unsigned int embed_bytes,
                               const unsigned int trailer_len){
        return (capacity * (embed_bytes + trailer_len)) + header_size<true>();
    }


    CUTE_HOST_DEVICE
    size_t symmetric_heap_peer_offset(const unsigned int cap,
                                      const unsigned int k,
                                      size_t embed_bytes){
        return n_cells * ((packet_bytes<true>(cap, embed_bytes,trailer_length_bytes(k)) * cell_span<true>())
                            + (packet_bytes<false>(cap,embed_bytes,
                                                   trailer_length_bytes(k)) * cell_span<false>()));
    }

    //(checkpoint * (trailer_length_bytes(k) + embed_bytes + header_size<false>());
    template<bool isPrimingStage=false>
    CUTE_HOST_DEVICE
    size_t packet_trailer_start(const unsigned int cell,
                                const unsigned int checkpoint,
                                const unsigned int capacity,
                                const size_t embed_bytes,
                                unsigned int k){
        return (packet_bytes<false>(capacity, embed_bytes, trailer_length_bytes(k)) * cell) +
                (cell * (embed_bytes + header_size<false>()));
    }
}
#endif //ARISTOS_MEMORY_LAYOUT_CUH