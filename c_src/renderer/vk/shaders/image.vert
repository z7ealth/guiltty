#version 450

// The Vulkan twin of gl/shaders/image.vert: one image placement, a quad
// from four vertices and no vertex data. Push constants share the cells'
// pipeline layout, but this block is laid out for images (struct
// image_push in vk_backend.c).
layout(push_constant, std430) uniform Image {
    vec2 viewport; // window size in pixels
    vec2 pad;
    vec4 dest; // x, y, width, height in window pixels (y down)
    vec4 src; // the part of the image: u0, v0, u1, v1 (0..1)
} u;

layout(location = 0) out vec2 v_uv;

void main() {
    // Strip order: (0,0) (1,0) (0,1) (1,1)
    vec2 corner = vec2(gl_VertexIndex & 1, gl_VertexIndex >> 1);
    vec2 px = u.dest.xy + corner * u.dest.zw;
    // Vulkan's y axis points down, like pixel rows: no flip.
    gl_Position = vec4(px / u.viewport * 2.0 - 1.0, 0.0, 1.0);
    v_uv = mix(u.src.xy, u.src.zw, corner);
}
