#ifndef SPS_INC_RESOLVER_FRAG
#define SPS_INC_RESOLVER_FRAG

#include "../common/sps_cell_frag.cginc"
#include "sps_resolver_read.cginc"
#include "sps_resolver_payload.cginc"
#include "sps_resolver_types.cginc"

float sps_resolver_vector_component(float3 value, int component) {
    if (component == 0) return value.x;
    if (component == 1) return value.y;
    return value.z;
}

uint sps_resolver_id() {
    return sps_id();
}

uint sps_resolver_player_id() {
    return sps_player_id();
}

#define SPS_SELECT_5(result, index, value0, value1, value2, value3, value4) \
    { \
        uint spsSelectIndex = (uint)(index); \
        if (spsSelectIndex == 0u) result = (value0); \
        else if (spsSelectIndex == 1u) result = (value1); \
        else if (spsSelectIndex == 2u) result = (value2); \
        else if (spsSelectIndex == 3u) result = (value3); \
        else result = (value4); \
    }

float sps_resolver_metadata_color_component(uint payloadIndex) {
    float value = _SPS_MetadataColor.z;
    if (payloadIndex == SPS_RESOLVER_METADATA_COLOR_X_INDEX) value = _SPS_MetadataColor.x;
    else if (payloadIndex == SPS_RESOLVER_METADATA_COLOR_Y_INDEX) value = _SPS_MetadataColor.y;
    return value;
}

bool sps_resolver_payload_rgba(SpsTexture socketTex, v2f input, uint payloadIndex, out float4 rgba) {
    rgba = 0;
    if (payloadIndex >= SPS_RESOLVER_PAYLOAD_VALUES) return false;

    if (payloadIndex >= SPS_RESOLVER_METADATA_BASE
        && payloadIndex < SPS_RESOLVER_METADATA_BASE + SPS_RESOLVER_METADATA_VALUES) {
        if (payloadIndex <= SPS_RESOLVER_METADATA_COLOR_Z_INDEX) {
            rgba = sps_encode_float(sps_resolver_metadata_color_component(payloadIndex));
            return true;
        }
        if (payloadIndex == SPS_RESOLVER_METADATA_LENGTH_INDEX) {
            rgba = sps_encode_float(sps_resolver_length());
            return true;
        }
        if (payloadIndex == SPS_RESOLVER_METADATA_RADIUS_INDEX) {
            rgba = sps_encode_float(sps_resolver_radius());
            return true;
        }
        if (input.chainSlotIndex[0] < 0) {
            rgba = 0;
            return true;
        }
        SpsCell firstSocket = sps_get_cell(socketTex, (uint)input.chainSlotIndex[0]);
        if (payloadIndex == SPS_RESOLVER_METADATA_SOCKET_PLAYER_ID_INDEX) {
            rgba = sps_encode_uint(sps_cell_header_player_id(firstSocket));
            return true;
        }
        if (payloadIndex == SPS_RESOLVER_METADATA_SOCKET_UNIQUE_ID_INDEX) {
            rgba = sps_encode_uint(sps_cell_header_unique_id(firstSocket));
            return true;
        }
        float firstSocketFraction = 0;
        float resolverLength = sps_resolver_length();
        if (resolverLength > 0) {
            float3 plugWorld = sps_object_origin_world();
            float3 firstSocketWorld = sps_cell_header_world(firstSocket);
            uint firstSocketFlags = firstSocket.read_uint(sps_cell_pixel_index_from_payload_index(SPS_SOCKET_PAYLOAD_FLAGS));
            float3 targetWorld = firstSocketWorld;
            if (sps_has_flag(firstSocketFlags, SPS_SOCKET_FLAG_RADIUS_OFFSET)) {
                targetWorld += sps_normalize(sps_cell_header_up(firstSocket)) * sps_resolver_radius();
            }
            float distanceToTarget = length(targetWorld - plugWorld);
            firstSocketFraction = saturate(1.0 - distanceToTarget / resolverLength);
        }
        rgba = sps_encode_float(firstSocketFraction);
        return true;
    }
    if (payloadIndex >= SPS_RESOLVER_RADIUS_SAMPLE_BASE
        && payloadIndex < SPS_RESOLVER_RADIUS_SAMPLE_BASE + SPS_RESOLVER_RADIUS_SAMPLE_COUNT) {
        rgba = sps_encode_float(sps_resolver_radius_sample((int)(payloadIndex - SPS_RESOLVER_RADIUS_SAMPLE_BASE)));
        return true;
    }
    if (payloadIndex >= SPS_RESOLVER_CHAIN_END) return true;

    uint chainValueIndex = payloadIndex - SPS_RESOLVER_CHAIN_BASE;
    uint segmentIndex = chainValueIndex / SPS_RESOLVER_CHAIN_STRIDE;
    int chainSlotIndex = SPS_CHAIN_REF_INVALID;
    bool isGuideTarget = false;
    float3 chainForward = 0;
    float3 chainUp = 0;
    SPS_SELECT_5(chainSlotIndex, segmentIndex, input.chainSlotIndex[0], input.chainSlotIndex[1], input.chainSlotIndex[2], input.chainSlotIndex[3], input.chainSlotIndex[4]);
    SPS_SELECT_5(chainForward, segmentIndex, input.chainForward[0], input.chainForward[1], input.chainForward[2], input.chainForward[3], input.chainForward[4]);
    SPS_SELECT_5(chainUp, segmentIndex, input.chainUp[0], input.chainUp[1], input.chainUp[2], input.chainUp[3], input.chainUp[4]);
    SPS_SELECT_5(isGuideTarget, segmentIndex, input.isGuideTarget[0], input.isGuideTarget[1], input.isGuideTarget[2], input.isGuideTarget[3], input.isGuideTarget[4]);
    if (chainSlotIndex <= SPS_CHAIN_REF_INVALID) return true;

    uint fieldIndex = chainValueIndex - segmentIndex * SPS_RESOLVER_CHAIN_STRIDE;
    CellData socket = sps_read_cell(socketTex, chainSlotIndex);
    SocketData socketData = sps_read_socket(socketTex, socket.cellIndex);
    float3 tangentOffset = sps_has_flag(socketData.flags, SPS_SOCKET_FLAG_RADIUS_OFFSET)
        ? socket.up * sps_resolver_radius()
        : 0;
    if (fieldIndex < 3) {
        // Align to axis of one-way rings if hilted.
        if (!sps_has_flag(socketData.flags, SPS_SOCKET_FLAG_HOLE) &&
            !sps_has_flag(socketData.flags, SPS_SOCKET_FLAG_DOUBLE_SIDED))
        {
            // Geomatry shader is unable to pass modified socket position without exceeding output size limits.
            // Instead, modify the socket position for here.

            // Fetch data
            const float worldLength = sps_resolver_length();
            const float3 normal = socket.normal;
            // TODO: Guided rings can produce sharp bends when shifted
            // May want to skip ring if next ring approaches min-distance
            // Or maybe we need to snap to curve instead of shifting?
            //float3 previousWorld = chainSlotIndex > 0 ? sps_read_cell(socketTex, chainSlotIndex - 1).world : sps_object_origin_world();
            float3 previousWorld = sps_object_origin_world();

            // Prevent orifice from getting too close to plug as that can introduce excessive roll.
            const float minDistance = 0;
            const float lerpDistance = minDistance;

            // Calculate lerp/min distance based on target centre (candidate.world - previousWorld), matching HOLE logic.
            // Consider plane aligned to orifice
            float3 rootPos = socket.world - previousWorld;
            const float orfPerpDistance = dot(-normal, rootPos);
            float shiftLerp = (orfPerpDistance > minDistance) ? 0 : 1;

            const float shiftAmount = (minDistance - orfPerpDistance);
            const float3 shiftedRoot = rootPos - normal * shiftAmount;

            /*
            // Lerp out as ring extends away from plug
            // https://stackoverflow.com/a/52471226
            const float orfPlaneDistance = length(shiftedRoot + normal * dot(shiftedRoot, -normal) / dot(normal, normal));
            shiftLerp *= sps_saturated_map(orfPlaneDistance, minDistance + lerpDistance, minDistance);
            */

            rootPos = lerp(rootPos, shiftedRoot, shiftLerp);
            socket.world = rootPos + previousWorld;

            // Don't need to update these
            /*
            const float3 position = sps_resolver_socket_target_world(socket, socketData.flags);
            const float3 entryOffset = position - previousWorld;
            socket.distanceSq = sps_length_sq(entryOffset);
            */
        }

        float3 sampleWorld = sps_resolver_socket_target_world(socket, socketData.flags);
        rgba = sps_encode_float(sps_resolver_vector_component(sampleWorld, (int)fieldIndex));
        return true;
    }
    if (fieldIndex < 6) {
        rgba = sps_encode_float(sps_resolver_vector_component(chainForward, (int)(fieldIndex - 3u)));
        return true;
    }
    if (fieldIndex < 9) {
        rgba = sps_encode_float(sps_resolver_vector_component(chainUp, (int)(fieldIndex - 6u)));
        return true;
    }
    if (fieldIndex < 10) {
        rgba = sps_encode_uint(socketData.flags);
        return true;
    }
    if (fieldIndex < 11) {
        rgba = sps_encode_uint(isGuideTarget ? 1u : 0u);
        return true;
    }
    if (fieldIndex < 14) {
        float3 tangentIn = sps_is_zero(socketData.tangentIn) ? 0 : socketData.tangentIn + tangentOffset;
        rgba = sps_encode_float(sps_resolver_vector_component(tangentIn, (int)(fieldIndex - 11u)));
        return true;
    }
    if (fieldIndex < 17) {
        float3 tangentOut = sps_is_zero(socketData.tangentOut) ? 0 : socketData.tangentOut + tangentOffset;
        rgba = sps_encode_float(sps_resolver_vector_component(tangentOut, (int)(fieldIndex - 14u)));
        return true;
    }
    return true;
}

float4 sps_resolver_frag(SpsTexture socketTex, v2f input) {
    int cellIndex = input.cellIndex;
    uint pixelIndex;
    float4 rgba;
    if (sps_cell_frag(
        cellIndex,
        input.vertex,
        pixelIndex,
        rgba
    )) return rgba;

    uint resolverId = sps_resolver_id();
    uint resolverPlayerId = sps_resolver_player_id();
    if (sps_try_get_slot_header_rgba(
        pixelIndex,
        resolverId,
        resolverPlayerId,
        SPS_PRODUCT_PLUG,
        sps_object_origin_world(),
        sps_object_forward_world(),
        sps_object_up_world(),
        sps_object_scale_world(),
        input.debug,
        rgba
    )) {
        return rgba;
    }

    uint payloadIndex;
    if (sps_cell_payload_index_from_pixel_index(pixelIndex, payloadIndex)
        && sps_resolver_payload_rgba(socketTex, input, payloadIndex, rgba)) {
        return rgba;
    }

    return 0;
}

#endif
