#version 450

// The image's pixels, premultiplied by their alpha (images.c).
layout(set = 0, binding = 0) uniform sampler2D u_image;
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

void main() {
    out_color = texture(u_image, v_uv);
}
