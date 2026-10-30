// OpenGL 3.3 core backend. The whole grid is two instanced draw calls: a
// quad per cell, first for the backgrounds, then for the glyphs. Each
// instance reads its cell (struct cell, 12 bytes) as vertex attributes.
// Read: LearnOpenGL "Hello Triangle", "Shaders", "Textures", "Instancing"
// and "Blending".

#include <GL/glcorearb.h>
#include <SDL3/SDL.h>
#include <stddef.h>
#include <stdckdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../core/backend.h"

// The shaders are baked into the binary at compile time with C23 #embed,
// with a trailing NUL so they're C strings.
static const char cell_vert_src[] = {
#embed "shaders/cell.vert" suffix(, '\0')
};
static const char cell_frag_src[] = {
#embed "shaders/cell.frag" suffix(, '\0')
};

// Every GL function we call, loaded at runtime through SDL. Core-profile GL
// has no link-time entry points we can rely on; the driver hands them out.
#define GL_FUNCS(X)                                                                       \
    X(PFNGLCLEARCOLORPROC, ClearColor)                                                    \
    X(PFNGLCLEARPROC, Clear)                                                              \
    X(PFNGLVIEWPORTPROC, Viewport)                                                        \
    X(PFNGLGETERRORPROC, GetError)                                                        \
    X(PFNGLENABLEPROC, Enable)                                                            \
    X(PFNGLDISABLEPROC, Disable)                                                          \
    X(PFNGLBLENDFUNCSEPARATEPROC, BlendFuncSeparate)                                      \
    X(PFNGLUNIFORM1FPROC, Uniform1f)                                                      \
    X(PFNGLCREATESHADERPROC, CreateShader)                                                \
    X(PFNGLSHADERSOURCEPROC, ShaderSource)                                                \
    X(PFNGLCOMPILESHADERPROC, CompileShader)                                              \
    X(PFNGLGETSHADERIVPROC, GetShaderiv)                                                  \
    X(PFNGLGETSHADERINFOLOGPROC, GetShaderInfoLog)                                        \
    X(PFNGLDELETESHADERPROC, DeleteShader)                                                \
    X(PFNGLCREATEPROGRAMPROC, CreateProgram)                                              \
    X(PFNGLATTACHSHADERPROC, AttachShader)                                                \
    X(PFNGLLINKPROGRAMPROC, LinkProgram)                                                  \
    X(PFNGLGETPROGRAMIVPROC, GetProgramiv)                                                \
    X(PFNGLGETPROGRAMINFOLOGPROC, GetProgramInfoLog)                                      \
    X(PFNGLUSEPROGRAMPROC, UseProgram)                                                    \
    X(PFNGLDELETEPROGRAMPROC, DeleteProgram)                                              \
    X(PFNGLGETUNIFORMLOCATIONPROC, GetUniformLocation)                                    \
    X(PFNGLUNIFORM1IPROC, Uniform1i)                                                      \
    X(PFNGLUNIFORM2FPROC, Uniform2f)                                                      \
    X(PFNGLUNIFORM3FPROC, Uniform3f)                                                      \
    X(PFNGLGENVERTEXARRAYSPROC, GenVertexArrays)                                          \
    X(PFNGLBINDVERTEXARRAYPROC, BindVertexArray)                                          \
    X(PFNGLDELETEVERTEXARRAYSPROC, DeleteVertexArrays)                                    \
    X(PFNGLGENBUFFERSPROC, GenBuffers)                                                    \
    X(PFNGLBINDBUFFERPROC, BindBuffer)                                                    \
    X(PFNGLBUFFERDATAPROC, BufferData)                                                    \
    X(PFNGLBUFFERSUBDATAPROC, BufferSubData)                                              \
    X(PFNGLDELETEBUFFERSPROC, DeleteBuffers)                                              \
    X(PFNGLENABLEVERTEXATTRIBARRAYPROC, EnableVertexAttribArray)                          \
    X(PFNGLVERTEXATTRIBPOINTERPROC, VertexAttribPointer)                                  \
    X(PFNGLVERTEXATTRIBIPOINTERPROC, VertexAttribIPointer)                                \
    X(PFNGLVERTEXATTRIBDIVISORPROC, VertexAttribDivisor)                                  \
    X(PFNGLGENTEXTURESPROC, GenTextures)                                                  \
    X(PFNGLBINDTEXTUREPROC, BindTexture)                                                  \
    X(PFNGLACTIVETEXTUREPROC, ActiveTexture)                                              \
    X(PFNGLTEXIMAGE2DPROC, TexImage2D)                                                    \
    X(PFNGLTEXSUBIMAGE2DPROC, TexSubImage2D)                                              \
    X(PFNGLTEXPARAMETERIPROC, TexParameteri)                                              \
    X(PFNGLPIXELSTOREIPROC, PixelStorei)                                                  \
    X(PFNGLDELETETEXTURESPROC, DeleteTextures)                                            \
    X(PFNGLDRAWARRAYSINSTANCEDPROC, DrawArraysInstanced)                                  \
    X(PFNGLREADPIXELSPROC, ReadPixels)

struct gl_funcs {
#define X(type, name) type name;
    GL_FUNCS(X)
#undef X
};

struct gl {
    SDL_Window *window;
    SDL_GLContext context;
    struct gl_funcs f;
    GLuint program, vao, cell_buffer, atlas_texture;
    size_t capacity; // cells the buffer can hold
    uint16_t cols, rows; // the grid the buffer holds
    int width, height; // drawable size in pixels
    int cell_w, cell_h, baseline, line_thickness, atlas_cols;
    uint32_t atlas_generation; // of the atlas in the texture
    int atlas_w, atlas_h;
    struct {
        GLint viewport, origin, cell, cols, atlas_cols, cursor, cursor2, pass, atlas,
            cursor_color, underline_y, strike_y, line_thickness, cursor_shape, accent, opacity,
            rows, first_row_last;
    } u; // uniform locations
};

[[nodiscard]] static bool load_funcs(struct gl_funcs *f) {
#define X(type, name)                                                                     \
    f->name = (type)SDL_GL_GetProcAddress("gl" #name);                                    \
    if (f->name == nullptr) {                                                             \
        fprintf(stderr, "renderer: missing gl" #name "\n");                               \
        return false;                                                                     \
    }
    GL_FUNCS(X)
#undef X
    return true;
}

[[nodiscard]] static GLuint compile(struct gl *gl, GLenum kind, const char *src) {
    GLuint shader = gl->f.CreateShader(kind);
    gl->f.ShaderSource(shader, 1, &src, nullptr);
    gl->f.CompileShader(shader);
    GLint ok;
    gl->f.GetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024];
        gl->f.GetShaderInfoLog(shader, sizeof log, nullptr, log);
        fprintf(stderr, "renderer: shader compile failed:\n%s\n", log);
        gl->f.DeleteShader(shader);
        return 0;
    }
    return shader;
}

[[nodiscard]] static bool build_program(struct gl *gl) {
    GLuint vs = compile(gl, GL_VERTEX_SHADER, cell_vert_src);
    GLuint fs = compile(gl, GL_FRAGMENT_SHADER, cell_frag_src);
    if (vs == 0 || fs == 0) {
        gl->f.DeleteShader(vs);
        gl->f.DeleteShader(fs);
        return false;
    }
    gl->program = gl->f.CreateProgram();
    gl->f.AttachShader(gl->program, vs);
    gl->f.AttachShader(gl->program, fs);
    gl->f.LinkProgram(gl->program);
    gl->f.DeleteShader(vs); // the program keeps what it needs
    gl->f.DeleteShader(fs);
    GLint ok;
    gl->f.GetProgramiv(gl->program, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[1024];
        gl->f.GetProgramInfoLog(gl->program, sizeof log, nullptr, log);
        fprintf(stderr, "renderer: shader link failed:\n%s\n", log);
        return false;
    }

#define LOC(field, name) gl->u.field = gl->f.GetUniformLocation(gl->program, name)
    LOC(viewport, "u_viewport");
    LOC(origin, "u_origin");
    LOC(cell, "u_cell");
    LOC(cols, "u_cols");
    LOC(atlas_cols, "u_atlas_cols");
    LOC(cursor, "u_cursor");
    LOC(cursor2, "u_cursor2");
    LOC(pass, "u_pass");
    LOC(atlas, "u_atlas");
    LOC(cursor_color, "u_cursor_color");
    LOC(underline_y, "u_underline_y");
    LOC(strike_y, "u_strike_y");
    LOC(line_thickness, "u_line_thickness");
    LOC(cursor_shape, "u_cursor_shape");
    LOC(accent, "u_accent");
    LOC(opacity, "u_opacity");
    LOC(rows, "u_rows");
    LOC(first_row_last, "u_first_row_last");
#undef LOC
    return true;
}

static bool gl_configure(void) {
    return SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3) &&
           SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3) &&
           SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE) &&
           SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1) &&
           // An alpha channel in the framebuffer, for translucent windows.
           SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE, 8);
}

static void gl_shutdown(void *state);

static void *gl_init(SDL_Window *window) {
    struct gl *gl = calloc(1, sizeof *gl);
    if (gl == nullptr)
        return nullptr;
    gl->window = window;

    gl->context = SDL_GL_CreateContext(window);
    if (gl->context == nullptr) {
        fprintf(stderr, "renderer: no OpenGL 3.3 core context: %s\n", SDL_GetError());
        free(gl);
        return nullptr;
    }
    // Wait for vsync on swap: draw at most once per screen refresh.
    SDL_GL_SetSwapInterval(1);
    if (!load_funcs(&gl->f) || !build_program(gl)) {
        gl_shutdown(gl);
        return nullptr;
    }

    // The per-cell buffer. Each attribute advances once per instance
    // (divisor 1) instead of once per vertex. The buffer itself is sized on
    // the first draw, and again whenever the grid grows.
    struct gl_funcs *f = &gl->f;
    f->GenVertexArrays(1, &gl->vao);
    f->BindVertexArray(gl->vao);
    f->GenBuffers(1, &gl->cell_buffer);
    f->BindBuffer(GL_ARRAY_BUFFER, gl->cell_buffer);
    constexpr GLsizei stride = sizeof(struct cell);
    f->VertexAttribIPointer(0, 1, GL_UNSIGNED_SHORT, stride, (void *)offsetof(struct cell, slot));
    f->VertexAttribIPointer(1, 1, GL_UNSIGNED_SHORT, stride, (void *)offsetof(struct cell, attrs));
    // Normalized: the bytes 0..255 arrive in the shader as 0.0..1.0.
    f->VertexAttribPointer(2, 3, GL_UNSIGNED_BYTE, GL_TRUE, stride, (void *)offsetof(struct cell, fg));
    f->VertexAttribPointer(3, 3, GL_UNSIGNED_BYTE, GL_TRUE, stride, (void *)offsetof(struct cell, bg));
    for (GLuint i = 0; i < 4; i++) {
        f->EnableVertexAttribArray(i);
        f->VertexAttribDivisor(i, 1);
    }
    return gl;
}

static bool gl_upload_atlas(void *state, const struct atlas *atlas) {
    struct gl *gl = state;
    gl->cell_w = atlas->cell_w;
    gl->cell_h = atlas->cell_h;
    gl->baseline = atlas->baseline;
    gl->line_thickness = atlas->line_thickness;
    gl->atlas_cols = atlas->slots_per_row;
    gl->f.ActiveTexture(GL_TEXTURE0);

    bool same = gl->atlas_texture != 0 && atlas->generation == gl->atlas_generation &&
                atlas->width == gl->atlas_w && atlas->height == gl->atlas_h;
    if (same) {
        // New glyphs since the last frame: upload just the band of rows
        // they're in.
        if (atlas->dirty_top > atlas->dirty_bottom)
            return true;
        gl->f.BindTexture(GL_TEXTURE_2D, gl->atlas_texture);
        size_t offset = (size_t)atlas->dirty_top * (size_t)atlas->width * 4;
        gl->f.TexSubImage2D(GL_TEXTURE_2D, 0, 0, atlas->dirty_top, atlas->width,
                            atlas->dirty_bottom - atlas->dirty_top + 1, GL_RGBA, GL_UNSIGNED_BYTE,
                            atlas->pixels + offset);
        return gl->f.GetError() == GL_NO_ERROR;
    }

    // A new font, or the atlas was reset: replace the whole texture.
    if (gl->atlas_texture != 0)
        gl->f.DeleteTextures(1, &gl->atlas_texture);
    gl->f.GenTextures(1, &gl->atlas_texture);
    gl->f.BindTexture(GL_TEXTURE_2D, gl->atlas_texture);
    gl->f.TexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, atlas->width, atlas->height, 0, GL_RGBA,
                     GL_UNSIGNED_BYTE, atlas->pixels);
    gl->f.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    gl->f.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    gl->atlas_generation = atlas->generation;
    gl->atlas_w = atlas->width;
    gl->atlas_h = atlas->height;
    return gl->f.GetError() == GL_NO_ERROR;
}

static void gl_resize(void *state, int width_px, int height_px) {
    struct gl *gl = state;
    gl->width = width_px;
    gl->height = height_px;
    gl->f.Viewport(0, 0, width_px, height_px);
}

static float unit(uint8_t v) { return (float)v / 255.0f; }

// Read the frame just drawn (still in the back buffer). GL numbers rows
// from the bottom; the capture wants the top row first.
static void capture(struct gl *gl, uint8_t *out) {
    size_t row = (size_t)gl->width * 4;
    gl->f.ReadPixels(0, 0, gl->width, gl->height, GL_RGBA, GL_UNSIGNED_BYTE, out);
    uint8_t *tmp = malloc(row);
    if (tmp == nullptr)
        return;
    for (int top = 0, bottom = gl->height - 1; top < bottom; top++, bottom--) {
        memcpy(tmp, out + (size_t)top * row, row);
        memcpy(out + (size_t)top * row, out + (size_t)bottom * row, row);
        memcpy(out + (size_t)bottom * row, tmp, row);
    }
    free(tmp);
}

static void gl_draw_frame(void *state, const struct frame *frame) {
    struct gl *gl = state;
    struct gl_funcs *f = &gl->f;
    size_t ncells = (size_t)frame->cols * frame->rows;
    size_t bytes;
    if (ckd_mul(&bytes, ncells, sizeof(struct cell)))
        return;

    // The compositor expects premultiplied alpha: color already scaled by
    // its opacity.
    float a = frame->opacity;
    f->ClearColor(unit(frame->clear_rgb[0]) * a, unit(frame->clear_rgb[1]) * a,
                  unit(frame->clear_rgb[2]) * a, a);
    f->Clear(GL_COLOR_BUFFER_BIT);

    // Damage tracking: the GPU keeps last frame's cells, so upload only the
    // rows that changed. A new grid size changes every cell's position in
    // the buffer, so then everything goes (growing the buffer if needed).
    f->BindBuffer(GL_ARRAY_BUFFER, gl->cell_buffer);
    if (ncells > gl->capacity) {
        f->BufferData(GL_ARRAY_BUFFER, (GLsizeiptr)bytes, frame->cells, GL_DYNAMIC_DRAW);
        gl->capacity = ncells;
    } else if (frame->cols != gl->cols || frame->rows != gl->rows) {
        f->BufferSubData(GL_ARRAY_BUFFER, 0, (GLsizeiptr)bytes, frame->cells);
    } else if (frame->dirty_first <= frame->dirty_last) {
        size_t row_bytes = (size_t)frame->cols * sizeof(struct cell);
        size_t first = (size_t)frame->dirty_first, count = (size_t)(frame->dirty_last - frame->dirty_first + 1);
        f->BufferSubData(GL_ARRAY_BUFFER, (GLintptr)(first * row_bytes), (GLsizeiptr)(count * row_bytes),
                         frame->cells + first * frame->cols);
    }
    gl->cols = frame->cols;
    gl->rows = frame->rows;

    int cursor = frame->cursor_visible ? frame->cursor_row * frame->cols + frame->cursor_col : -1;
    int cursor2 = cursor >= 0 && frame->cursor_wide ? cursor + 1 : -1;
    f->UseProgram(gl->program);
    f->Uniform2f(gl->u.viewport, (float)gl->width, (float)gl->height);
    f->Uniform2f(gl->u.origin, (float)frame->origin_x, (float)frame->origin_y);
    f->Uniform2f(gl->u.cell, (float)gl->cell_w, (float)gl->cell_h);
    f->Uniform1i(gl->u.cols, frame->cols);
    f->Uniform1i(gl->u.atlas_cols, gl->atlas_cols);
    f->Uniform1i(gl->u.cursor, cursor);
    f->Uniform1i(gl->u.cursor2, cursor2);
    f->Uniform1i(gl->u.atlas, 0);
    f->Uniform3f(gl->u.cursor_color, unit(frame->cursor_rgb[0]), unit(frame->cursor_rgb[1]),
                 unit(frame->cursor_rgb[2]));
    // Underline just below the baseline; strikethrough through the middle
    // of lowercase letters.
    f->Uniform1i(gl->u.underline_y, gl->baseline + 1);
    f->Uniform1i(gl->u.strike_y, gl->baseline - gl->cell_h / 4);
    f->Uniform1i(gl->u.line_thickness, gl->line_thickness);
    f->Uniform1i(gl->u.cursor_shape, frame->cursor_shape);
    f->Uniform3f(gl->u.accent, unit(frame->accent_rgb[0]), unit(frame->accent_rgb[1]),
                 unit(frame->accent_rgb[2]));
    f->Uniform1f(gl->u.opacity, frame->opacity);
    f->Uniform1i(gl->u.rows, frame->rows);
    f->Uniform1i(gl->u.first_row_last, frame->first_row_last ? 1 : 0);

    f->BindVertexArray(gl->vao);
    f->ActiveTexture(GL_TEXTURE0);
    f->BindTexture(GL_TEXTURE_2D, gl->atlas_texture);

    // Pass 0: backgrounds, opaque.
    f->Disable(GL_BLEND);
    f->Uniform1i(gl->u.pass, 0);
    f->DrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, (GLsizei)ncells);

    // Pass 1: glyphs, blended by coverage (out_color's alpha). Color: the
    // usual "over". Alpha: the glyph makes its pixels more opaque, never
    // less, and keeps what's there premultiplied.
    f->Enable(GL_BLEND);
    f->BlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    f->Uniform1i(gl->u.pass, 1);
    f->DrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, (GLsizei)ncells);

    if (frame->capture != nullptr)
        capture(gl, frame->capture);
    SDL_GL_SwapWindow(gl->window);
}

static void gl_shutdown(void *state) {
    struct gl *gl = state;
    if (gl == nullptr)
        return;
    if (gl->f.DeleteTextures != nullptr) {
        gl->f.DeleteTextures(1, &gl->atlas_texture);
        gl->f.DeleteBuffers(1, &gl->cell_buffer);
        gl->f.DeleteVertexArrays(1, &gl->vao);
        gl->f.DeleteProgram(gl->program);
    }
    if (gl->context != nullptr)
        SDL_GL_DestroyContext(gl->context);
    free(gl);
}

const struct backend renderer_backend = {
    .name = "gl",
    .window_flags = SDL_WINDOW_OPENGL,
    .configure = gl_configure,
    .init = gl_init,
    .upload_atlas = gl_upload_atlas,
    .draw_frame = gl_draw_frame,
    .resize = gl_resize,
    .shutdown = gl_shutdown,
};
