use std::sync::Arc;

use crate::{Tree, TreeRoot};

use dust_render::Geometry;
use dust_vdb::{IsLeaf, Node};
use glam::{UVec3, Vec3A};
use rhyolite::ash::vk;
use rhyolite::debug::DebugObject;
use rhyolite::future::{GPUCommandFuture, GPUCommandFutureExt, UnitCommandFuture};
use rhyolite::ResidentBuffer;
use rhyolite_bevy::Allocator;

#[derive(bevy_reflect::TypeUuid, bevy_reflect::TypePath)]
#[uuid = "307feebb-14b8-4135-be09-ae828decc6a4"]
pub struct VoxGeometry {
    tree: Tree,
    size: [u8; 3],
    pub num_blocks: u32,
    pub unit_size: f32,

    /// Array of AABBs, used as Acceleration Strucutre Build Input
    aabb_buffer: Arc<ResidentBuffer>,

    /// Array of `GPUVoxNode`, used during ray tracing.
    /// Its shader device address is written into the SBT Records
    geometry_buffer: Arc<ResidentBuffer>,
}

impl Geometry for VoxGeometry {
    const TYPE: dust_render::GeometryType = dust_render::GeometryType::AABBs;

    type BLASInputBufferFuture = UnitCommandFuture<Arc<ResidentBuffer>>;

    fn blas_input_buffer(&self) -> Self::BLASInputBufferFuture {
        UnitCommandFuture::new(self.aabb_buffer.clone())
    }
}

#[repr(C)]
struct GPUVoxNode {
    x: u16,
    y: u16,
    z: u16,
    w: u16,
    mask: u64,
    material_ptr: u32,
    reserved: u32,
}

impl VoxGeometry {
    pub fn geometry_buffer(&self) -> &Arc<ResidentBuffer> {
        &self.geometry_buffer
    }
    pub fn from_tree(
        tree: Tree,
        size: [u8; 3],
        unit_size: f32,
        allocator: &Allocator,
    ) -> impl GPUCommandFuture<Output = Self> {
        let leaf_extent_int = <<TreeRoot as Node>::LeafType as Node>::EXTENT;
        let leaf_extent: Vec3A = leaf_extent_int.as_vec3a();
        let leaf_extent: Vec3A = unit_size * leaf_extent;

        let (aabbs, nodes): (Vec<vk::AabbPositionsKHR>, Vec<GPUVoxNode>) = tree
            .iter_leaf()
            .map(|(position, d)| {
                let aabb = {
                    let position = position.as_vec3a();
                    let max_position = leaf_extent + position;
                    vk::AabbPositionsKHR {
                        min_x: position.x,
                        min_y: position.y,
                        min_z: position.z,
                        max_x: max_position.x,
                        max_y: max_position.y,
                        max_z: max_position.z,
                    }
                };
                let mut mask = [0_u64; 1];
                d.get_occupancy(&mut mask);
                let mask = mask[0];
                let node = {
                    GPUVoxNode {
                        x: position.x as u16,
                        y: position.y as u16,
                        z: position.z as u16,
                        w: 0,
                        mask,
                        material_ptr: d.material_ptr,
                        reserved: 0,
                    }
                };
                (aabb, node)
            })
            .unzip();
        let aabb_buffer = {
            let size = std::mem::size_of_val(aabbs.as_slice());
            assert_eq!(size, aabbs.len() * 24);
            let data = unsafe { std::slice::from_raw_parts(aabbs.as_ptr() as *const u8, size) };
            allocator
                .create_dynamic_asset_buffer_with_data(
                    data,
                    vk::BufferUsageFlags::SHADER_DEVICE_ADDRESS
                        | vk::BufferUsageFlags::ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_KHR,
                    16,
                )
                .unwrap()
                .map(|buffer| {
                    buffer.inspect(|buffer| {
                        buffer.set_name("Vox BLAS Input AABB Buffer").unwrap();
                    })
                })
        };
        let geometry_buffer = {
            let size = std::mem::size_of_val(nodes.as_slice());
            assert_eq!(size, nodes.len() * 24);
            let data = unsafe { std::slice::from_raw_parts(nodes.as_ptr() as *const u8, size) };
            allocator
                .create_dynamic_asset_buffer_with_data(
                    data,
                    vk::BufferUsageFlags::SHADER_DEVICE_ADDRESS,
                    16,
                )
                .unwrap()
                .map(|buffer| {
                    buffer.inspect(|buffer| {
                        buffer.set_name("Vox Geometry Buffer").unwrap();
                    })
                })
        };
        let num_blocks = aabbs.len() as u32;
        let future =
            aabb_buffer
                .join(geometry_buffer)
                .map(move |(aabb_buffer, geometry_buffer)| Self {
                    tree,
                    size,
                    unit_size,
                    aabb_buffer: Arc::new(aabb_buffer.into_inner()),
                    geometry_buffer: Arc::new(geometry_buffer.into_inner()),
                    num_blocks,
                });
        future
    }
    pub fn set(&mut self, coords: UVec3, value: Option<bool>) {
        self.tree.set_value(coords, value)
    }
    pub fn get(&mut self, coords: UVec3) -> Option<bool> {
        self.tree.get_value(coords)
    }
}
