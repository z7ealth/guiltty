#version 330 core

// One image placement: a quad from four vertices (a triangle strip), no
// vertex data at all. The core worked out where it goes, in pixels.
uniform vec2 u_viewport; // window size in pixels
uniform vec4 u_dest; // x, y, width, height in window pixels (y down)
uniform vec4 u_src; // the part of the image: u0, v0, u1, v1 (0..1)

out vec2 v_uv;

void main() {
    // Strip order: (0,0) (1,0) (0,1) (1,1)
    vec2 corner = vec2(gl_VertexID & 1, gl_VertexID >> 1);
    vec2 px = u_dest.xy + corner * u_dest.zw;
    vec2 ndc = px / u_viewport * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, -ndc.y, 0.0, 1.0); // pixels grow down, NDC grows up
    v_uv = mix(u_src.xy, u_src.zw, corner);
}
