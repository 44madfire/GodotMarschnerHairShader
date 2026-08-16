# Production Marschner LUTs

The addon ships two direct `ImageTexture3D` resources; release users do not need a LUT-generation step.

- `unity_azimuthal_64.res`: `unity_hdrp_azimuthal_n_v1`, 64 x 64 x 64 RGBA16F, eta 1.55.
- `cinematic_longitudinal_kernel_128x128x64.res`: `deon_physical_longitudinal_log2q_v2`, 128 x 128 x 64 R16F, conditioned beta range 0.05 to 64.

`HairMarschnerLUTAdapter` validates dimensions, format, and rendering RID before binding. LUT regeneration and storage benchmarks remain development workflows on the `development` branch.
