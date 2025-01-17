#version 460
#include "standard.glsl"

layout(shaderRecordEXT) buffer Sbt {
    GeometryInfo geometryInfo;
    MaterialInfo materialInfo;
    PaletteInfo paletteInfo;
    IrradianceCache irradianceCache;
} sbt;

hitAttributeEXT HitAttribute {
    uint8_t voxelId;
} hitAttributes;

float SRGBToLinear(float color)
{
    // Approximately pow(color, 2.2)
    return color < 0.04045 ? color / 12.92 : pow(abs(color + 0.055) / 1.055, 2.4);
}

vec3 SRGBToXYZ(vec3 srgb) {
    mat3 transform = mat3(
        0.4124564, 0.2126729, 0.0193339,
        0.3575761, 0.7151522, 0.1191920,
        0.1804375, 0.0721750, 0.9503041
    );
    return transform * srgb;
}

void main() {
    Block block = sbt.geometryInfo.blocks[gl_PrimitiveID];
    
    // Calculate nexthit location
    vec3 hitPointObject = gl_HitTEXT * gl_ObjectRayDirectionEXT + gl_ObjectRayOriginEXT;
    vec3 offsetInBox = vec3(hitAttributes.voxelId >> 4, (hitAttributes.voxelId >> 2) & 3, hitAttributes.voxelId & 3);
    vec3 boxCenterObject = block.position.xyz + offsetInBox + vec3(0.5);
    vec3 normalObject = CubedNormalize(hitPointObject - boxCenterObject);
    vec3 normalWorld = gl_ObjectToWorldEXT * vec4(normalObject, 0.0);

    #ifdef SHADER_INT_64
    u32vec2 masked = unpack32(block.mask & ((uint64_t(1) << hitAttributes.voxelId) - 1));
    uint32_t voxelMemoryOffset = bitCount(masked.x) + bitCount(masked.y);
    #else
    u32vec2 masked = u32vec2(
        hitAttributes.voxelId < 32 ? block.mask1 & ((1 << hitAttributes.voxelId) - 1) : block.mask1,
        hitAttributes.voxelId >= 32 ? block.mask2 & ((1 << (hitAttributes.voxelId - 32)) - 1) : 0
    );
    uint32_t voxelMemoryOffset = uint32_t(bitCount(masked.x) + bitCount(masked.y));
    #endif


    uint8_t palette_index = sbt.materialInfo.materials[block.material_ptr + voxelMemoryOffset];
    u8vec4 color = sbt.paletteInfo.palette[palette_index];


    vec3 albedo = color.xyz / 255.0;
    albedo.x = SRGBToLinear(albedo.x);
    albedo.y = SRGBToLinear(albedo.y);
    albedo.z = SRGBToLinear(albedo.z);

    // Store the contribution from photon maps
    imageStore(u_depth, ivec2(gl_LaunchIDEXT.xy), vec4(gl_HitTEXT));
    imageStore(u_normal, ivec2(gl_LaunchIDEXT.xy), vec4(normalWorld, 1.0));
    imageStore(u_albedo, ivec2(gl_LaunchIDEXT.xy), vec4(SRGBToXYZ(albedo), 1.0));

    vec3 hitPointWorld = gl_HitTEXT * gl_WorldRayDirectionEXT + gl_WorldRayOriginEXT;
    vec2 hitPointScreen = (vec2(gl_LaunchIDEXT.xy) + vec2(0.5)) / vec2(gl_LaunchSizeEXT.xy);


    vec4 hitPointNDCLastFrame = u_camera_last_frame.view_proj * vec4(hitPointWorld, 1.0);
    vec3 hitPointNDCLastFrameNormalized = hitPointNDCLastFrame.xyz / hitPointNDCLastFrame.w;
    hitPointNDCLastFrameNormalized.y *= -1.0;
    vec2 hitPointScreenLastFrame = ((hitPointNDCLastFrameNormalized + 1.0) / 2.0).xy;

    vec2 motionVector = hitPointScreenLastFrame - hitPointScreen;
    imageStore(u_motion, ivec2(gl_LaunchIDEXT.xy), vec4(motionVector, 0.0, 0.0));
}
