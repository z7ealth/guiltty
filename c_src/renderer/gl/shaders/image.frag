#version 330 core

// The image's own pixels, already premultiplied by their alpha (images.c),
// so they blend with "one, one minus source alpha".
in vec2 v_uv;
uniform sampler2D u_image;
out vec4 out_color;

void main() {
    out_color = texture(u_image, v_uv);
}
