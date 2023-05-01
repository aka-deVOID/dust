#version 460
#extension GL_EXT_ray_tracing : require
#extension GL_EXT_shader_explicit_arithmetic_types : require
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_scalar_block_layout : require

layout(set = 0, binding = 0) uniform writeonly image2D u_imgOutput;
layout(set = 0, binding = 1) uniform writeonly image2D u_diffuseOutput;
struct Block
{
    u16vec4 position;
    uint64_t mask;
    uint32_t material_ptr;
    uint32_t reserved;
};

layout(buffer_reference, buffer_reference_align = 8, scalar) buffer GeometryInfo {
    Block blocks[];
};
layout(buffer_reference, buffer_reference_align = 1, scalar) buffer MaterialInfo {
    uint8_t materials[];
};
layout(buffer_reference) buffer PaletteInfo {
    u8vec4 palette[];
};

struct IrradianceCacheFace {
    f16vec3 irradiance;
    uint16_t mask;
};
struct IrradianceCacheEntry {
    IrradianceCacheFace faces[6];
    uint16_t lastAccessedFrameIndex[6];
    uint32_t _reerved;
};
layout(buffer_reference, scalar) buffer IrradianceCache {
    IrradianceCacheEntry entries[];
};


layout(push_constant) uniform PushConstants {
    // Indexed by block id
    uint rand;
    uint frameIndex;
} pushConstants;

layout(shaderRecordEXT) buffer Sbt {
    GeometryInfo geometryInfo;
    MaterialInfo materialInfo;
    PaletteInfo paletteInfo;
    IrradianceCache irradianceCache;
} sbt;

layout(location = 0) rayPayloadInEXT vec3 hitLocation;
hitAttributeEXT HitAttribute {
    uint8_t voxelId;
    uint8_t faceId;
} hitAttributes;


vec3 CubedNormalize(vec3 dir) {
    vec3 dir_abs = abs(dir);
    float max_element = max(dir_abs.x, max(dir_abs.y, dir_abs.z));
    return sign(dir) * step(max_element, dir_abs);
}

// Normal points outward for rays exiting the surface, else is flipped.
vec3 OffsetRay(vec3 p, vec3 n) {
    const float int_scale = 256.0;
    i8vec3 of_i = i8vec3(int_scale * n);
    vec3 p_i = intBitsToFloat(floatBitsToInt(p) + i32vec3(
        (p.x < 0) ? -of_i.x : of_i.x,
        (p.y < 0) ? -of_i.y : of_i.y,
        (p.z < 0) ? -of_i.z : of_i.z
    ));
    const float origin = 1.0 / 32.0;
    const float float_scale = 1.0 / 65536.0;
    return vec3(
        abs(p.x) < origin ? p.x + float_scale * n.x : p_i.x,
        abs(p.y) < origin ? p.y + float_scale * n.y : p_i.y,
        abs(p.z) < origin ? p.z + float_scale * n.z : p_i.z
    );
}

void main() {
    Block block = sbt.geometryInfo.blocks[gl_PrimitiveID];
    
    // Calculate nexthit location
    vec3 hitPointObject = gl_HitTEXT * gl_ObjectRayDirectionEXT + gl_ObjectRayOriginEXT;
    vec3 offsetInBox = vec3(hitAttributes.voxelId >> 4, (hitAttributes.voxelId >> 2) & 3, hitAttributes.voxelId & 3);
    vec3 boxCenterObject = block.position.xyz + offsetInBox + vec3(0.5);
    vec3 normalObject = CubedNormalize(hitPointObject - boxCenterObject);
    vec3 normalWorld = gl_ObjectToWorldEXT * vec4(normalObject, 0.0);
    hitLocation = gl_HitTEXT * gl_WorldRayDirectionEXT + gl_WorldRayOriginEXT + normalWorld * 0.01;

    int8_t faceId = int8_t(normalObject.x) * int8_t(3) + int8_t(normalObject.y) * int8_t(2) + int8_t(normalObject.z);
    uint8_t faceIdU = uint8_t(min((faceId > 0 ? (faceId-1) : (6 + faceId)), 5));
    
    IrradianceCacheFace hashEntry = sbt.irradianceCache.entries[gl_PrimitiveID].faces[faceIdU];
    uint16_t lastAccessedFrameIndex = sbt.irradianceCache.entries[gl_PrimitiveID].lastAccessedFrameIndex[faceIdU];
    f16vec3 irradiance = hashEntry.irradiance * float16_t(pow(0.999, uint16_t(pushConstants.frameIndex) - lastAccessedFrameIndex));
    f16vec3 radiance = irradiance / float16_t(bitCount(uint(hashEntry.mask)));


    u32vec2 masked = unpack32(block.mask & ((uint64_t(1) << hitAttributes.voxelId) - 1));
    uint32_t voxelMemoryOffset = bitCount(masked.x) + bitCount(masked.y);

    uint8_t palette_index = sbt.materialInfo.materials[block.material_ptr + voxelMemoryOffset];
    u8vec4 color = sbt.paletteInfo.palette[palette_index];


    vec3 diffuseColor = color.xyz / 255.0;
    // The parameter 0.01 was derived from the 0.999 retention factor. It's not arbitrary.
    vec3 indirectContribution = 0.01 * radiance * diffuseColor;

    // Store the contribution from photon maps
    imageStore(u_imgOutput, ivec2(gl_LaunchIDEXT.xy), vec4(indirectContribution, 1.0));
    imageStore(u_diffuseOutput, ivec2(gl_LaunchIDEXT.xy), vec4(diffuseColor, 1.0));
}
