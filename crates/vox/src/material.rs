use bevy_asset::{AssetServer, Handle};
use dust_render::{MaterialType, StandardPipeline};

use crate::VoxPalette;
use dust_render::SpecializedShader;
use rhyolite::{ash::vk, ResidentBuffer};

#[derive(bevy_reflect::TypeUuid)]
#[uuid = "a830cefc-beee-4ee9-89af-3436c0eefe0a"]
pub struct PaletteMaterial {
    palette: Handle<VoxPalette>,

    /// Compacted list of indexes into the palette array.
    data: ResidentBuffer,
}

impl PaletteMaterial {
    pub fn new(palette: Handle<VoxPalette>, data: ResidentBuffer) -> Self {
        Self { palette, data }
    }
}

pub struct PaletteMaterialShaderParams {
    /// Pointer to a list of u64 indexed by block id
    geometry_ptr: u64,

    /// Pointer to a list of u8, indexed by voxel id, each denoting offset into palette_ptr.
    /// Voxel id is defined as block id + offset inside block.
    material_ptr: u64,

    /// Pointer to a list of 256 u8 colors
    palette_ptr: u64,
}

impl dust_render::Material for PaletteMaterial {
    type Pipeline = StandardPipeline;

    const TYPE: MaterialType = MaterialType::Procedural;

    fn rahit_shader(_ray_type: u32, asset_server: &AssetServer) -> Option<SpecializedShader> {
        None
    }

    fn rchit_shader(_ray_type: u32, asset_server: &AssetServer) -> Option<SpecializedShader> {
        Some(SpecializedShader::for_shader(
            asset_server.load("hit.rchit.spv"),
            vk::ShaderStageFlags::CLOSEST_HIT_KHR,
        ))
    }

    fn intersection_shader(
        _ray_type: u32,
        asset_server: &AssetServer,
    ) -> Option<SpecializedShader> {
        Some(SpecializedShader::for_shader(
            asset_server.load("hit.rint.spv"),
            vk::ShaderStageFlags::INTERSECTION_KHR,
        ))
    }

    type ShaderParameters = PaletteMaterialShaderParams;

    fn parameters(&self, _ray_type: u32) -> Self::ShaderParameters {
        PaletteMaterialShaderParams {
            geometry_ptr: 0,
            material_ptr: 0,
            palette_ptr: 0,
        }
    }
}
