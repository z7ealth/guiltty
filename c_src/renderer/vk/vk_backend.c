// Vulkan backend: the same picture as the OpenGL one, by the same method
// (two instanced draws over the cells: backgrounds, then blended glyphs),
// with everything GL does behind your back written out.
//
//   instance, surface, device   who we are, where we draw, on which GPU
//   swapchain                   the images the window shows, in turns
//   pipelines                   the shaders and fixed state, baked once
//   atlas image                 the glyph atlas, on the GPU
//   frames in flight            two frames' worth of commands, so the CPU
//                               prepares one while the GPU draws the other
//
// It uses Vulkan 1.3's dynamic rendering (no render pass objects) and
// synchronization2. Read: vkguide.dev, vulkan-tutorial.com ("Swap chain",
// "Rendering and presentation", "Frames in flight"), and the spec's
// "Synchronization and Cache Control".

#include <SDL3/SDL.h>
#include <SDL3/SDL_vulkan.h>
#include <vulkan/vulkan.h>

#include <stdckdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../core/backend.h"

// SPIR-V, compiled from shaders/*.vert and *.frag by glslc at build time
// and baked in. SPIR-V is a stream of 32-bit words: keep them aligned.
alignas(4) static const unsigned char cell_vert_spv[] = {
#embed "shaders/cell.vert.spv"
};
alignas(4) static const unsigned char cell_frag_spv[] = {
#embed "shaders/cell.frag.spv"
};

constexpr uint32_t frames_in_flight = 2;
constexpr uint32_t max_images = 8;

// The push constants, laid out as the shaders' `Frame` block (std430).
struct push {
    float viewport[2];
    float origin[2];
    float cell[2];
    float opacity;
    int32_t pass;
    int32_t cols, atlas_cols, cursor, cursor2;
    int32_t rows, first_row_last, underline_y, strike_y;
    int32_t line_thickness, cursor_shape, pad[2];
    float cursor_color[4];
    float accent[4];
};
static_assert(sizeof(struct push) == 112 && offsetof(struct push, cursor_color) == 80);

struct buffer {
    VkBuffer buffer;
    VkDeviceMemory memory;
    void *map; // host-visible buffers stay mapped
    VkDeviceSize size;
};

// Everything one frame in flight needs of its own.
struct frame_slot {
    VkCommandBuffer cmd;
    VkFence done; // signaled when the GPU has finished this slot's last frame
    VkSemaphore acquired; // the swapchain image is ready to be drawn into
    struct buffer cells; // this frame's copy of the cells
};

struct vk {
    SDL_Window *window;
    VkInstance instance;
    VkDebugUtilsMessengerEXT messenger;
    VkSurfaceKHR surface;
    VkPhysicalDevice gpu;
    VkDevice device;
    uint32_t queue_family;
    VkQueue queue;
    VkCommandPool pool;
    struct frame_slot slots[frames_in_flight];
    uint32_t slot;

    VkSwapchainKHR swapchain;
    VkFormat format;
    VkExtent2D extent;
    uint32_t image_count;
    VkImage images[max_images];
    VkImageView views[max_images];
    VkSemaphore rendered[max_images]; // per image: its frame is drawn, show it
    bool stale; // the window changed: make a new swapchain before drawing
    bool can_capture; // the swapchain images can be copied from (screenshots)

    VkDescriptorSetLayout set_layout;
    VkPipelineLayout layout;
    VkPipeline backgrounds, glyphs;
    VkDescriptorPool descriptor_pool;
    VkDescriptorSet set;
    VkSampler sampler;

    VkImage atlas;
    VkDeviceMemory atlas_memory;
    VkImageView atlas_view;
    struct buffer staging;
    uint32_t atlas_generation;
    int atlas_w, atlas_h;
    int cell_w, cell_h, baseline, line_thickness, atlas_cols;

    struct buffer readback; // a captured frame, on its way to the CPU
};

static int validation_errors;

[[nodiscard]] static bool ok(VkResult result, const char *what) {
    if (result == VK_SUCCESS)
        return true;
    fprintf(stderr, "renderer: vulkan: %s failed (%d)\n", what, result);
    return false;
}

// --- Validation ---

// The validation layers check every call against the spec and report
// mistakes here. Only the debug build turns them on (-DGUILTTY_VK_VALIDATION).
static VKAPI_ATTR VkBool32 VKAPI_CALL on_validation(VkDebugUtilsMessageSeverityFlagBitsEXT severity,
                                                    VkDebugUtilsMessageTypeFlagsEXT,
                                                    const VkDebugUtilsMessengerCallbackDataEXT *data,
                                                    void *) {
    if (severity >= VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT)
        fprintf(stderr, "renderer: vulkan validation: %s\n", data->pMessage);
    if (severity >= VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT)
        validation_errors++;
    return VK_FALSE;
}

static bool validation_wanted(void) {
#ifdef GUILTTY_VK_VALIDATION
    uint32_t count = 0;
    vkEnumerateInstanceLayerProperties(&count, nullptr);
    VkLayerProperties *layers = calloc(count, sizeof *layers);
    bool found = false;
    if (layers != nullptr && vkEnumerateInstanceLayerProperties(&count, layers) == VK_SUCCESS)
        for (uint32_t i = 0; i < count; i++)
            found = found || strcmp(layers[i].layerName, "VK_LAYER_KHRONOS_validation") == 0;
    free(layers);
    if (!found)
        fprintf(stderr, "renderer: vulkan: validation layers not installed\n");
    return found;
#else
    return false;
#endif
}

// --- Instance, surface, device ---

[[nodiscard]] static bool create_instance(struct vk *vk) {
    // The extensions SDL needs to make a surface for its window.
    Uint32 sdl_count;
    const char *const *sdl_exts = SDL_Vulkan_GetInstanceExtensions(&sdl_count);
    if (sdl_exts == nullptr) {
        fprintf(stderr, "renderer: vulkan: %s\n", SDL_GetError());
        return false;
    }
    bool validate = validation_wanted();
    const char *exts[16];
    uint32_t n = 0;
    for (Uint32 i = 0; i < sdl_count && n < 15; i++)
        exts[n++] = sdl_exts[i];
    if (validate)
        exts[n++] = VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
    const char *layer = "VK_LAYER_KHRONOS_validation";

    VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "guiltty",
        .apiVersion = VK_API_VERSION_1_3,
    };
    VkInstanceCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
        .enabledExtensionCount = n,
        .ppEnabledExtensionNames = exts,
        .enabledLayerCount = validate ? 1 : 0,
        .ppEnabledLayerNames = &layer,
    };
    if (!ok(vkCreateInstance(&info, nullptr, &vk->instance), "vkCreateInstance"))
        return false;

    if (validate) {
        VkDebugUtilsMessengerCreateInfoEXT m = {
            .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                               VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                           VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                           VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
            .pfnUserCallback = on_validation,
        };
        // An extension function: the loader hands it out by name.
        auto create = (PFN_vkCreateDebugUtilsMessengerEXT)vkGetInstanceProcAddr(
            vk->instance, "vkCreateDebugUtilsMessengerEXT");
        if (create != nullptr)
            (void)ok(create(vk->instance, &m, nullptr, &vk->messenger), "debug messenger");
    }
    return true;
}

// A GPU that can do what we need: Vulkan 1.3 with dynamic rendering and
// synchronization2, the swapchain extension, and a queue that can both
// draw and present to our window's surface. Returns that queue's family.
static bool suitable(struct vk *vk, VkPhysicalDevice gpu, uint32_t *family) {
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(gpu, &props);
    if (props.apiVersion < VK_API_VERSION_1_3)
        return false;

    VkPhysicalDeviceVulkan13Features f13 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES};
    VkPhysicalDeviceFeatures2 f = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &f13};
    vkGetPhysicalDeviceFeatures2(gpu, &f);
    if (!f13.dynamicRendering || !f13.synchronization2 || !f13.shaderDemoteToHelperInvocation)
        return false;

    uint32_t count = 0;
    vkEnumerateDeviceExtensionProperties(gpu, nullptr, &count, nullptr);
    VkExtensionProperties *exts = calloc(count, sizeof *exts);
    bool swapchain = false;
    if (exts != nullptr && vkEnumerateDeviceExtensionProperties(gpu, nullptr, &count, exts) == VK_SUCCESS)
        for (uint32_t i = 0; i < count; i++)
            swapchain = swapchain || strcmp(exts[i].extensionName, VK_KHR_SWAPCHAIN_EXTENSION_NAME) == 0;
    free(exts);
    if (!swapchain)
        return false;

    vkGetPhysicalDeviceQueueFamilyProperties(gpu, &count, nullptr);
    VkQueueFamilyProperties *families = calloc(count, sizeof *families);
    bool found = false;
    if (families != nullptr) {
        vkGetPhysicalDeviceQueueFamilyProperties(gpu, &count, families);
        for (uint32_t i = 0; i < count && !found; i++) {
            VkBool32 present = VK_FALSE;
            vkGetPhysicalDeviceSurfaceSupportKHR(gpu, i, vk->surface, &present);
            if ((families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present) {
                *family = i;
                found = true;
            }
        }
    }
    free(families);
    return found;
}

// The best suitable GPU: a real one before a software one (lavapipe).
// GUILTTY_VK_DEVICE=name picks one whose name contains that text.
[[nodiscard]] static bool pick_gpu(struct vk *vk) {
    uint32_t count = 0;
    vkEnumeratePhysicalDevices(vk->instance, &count, nullptr);
    VkPhysicalDevice *gpus = calloc(count, sizeof *gpus);
    if (gpus == nullptr || vkEnumeratePhysicalDevices(vk->instance, &count, gpus) != VK_SUCCESS) {
        free(gpus);
        return false;
    }
    const char *wanted = SDL_getenv("GUILTTY_VK_DEVICE");
    int best_rank = -1;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t family;
        if (!suitable(vk, gpus[i], &family))
            continue;
        VkPhysicalDeviceProperties props;
        vkGetPhysicalDeviceProperties(gpus[i], &props);
        int rank = props.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU     ? 3
                   : props.deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU ? 2
                                                                                : 1;
        if (wanted != nullptr && strstr(props.deviceName, wanted) != nullptr)
            rank = 10;
        if (rank > best_rank) {
            best_rank = rank;
            vk->gpu = gpus[i];
            vk->queue_family = family;
        }
    }
    free(gpus);
    if (best_rank < 0)
        fprintf(stderr, "renderer: vulkan: no GPU with Vulkan 1.3 can draw to this window\n");
    return best_rank >= 0;
}

[[nodiscard]] static bool create_device(struct vk *vk) {
    float priority = 1.0f;
    VkDeviceQueueCreateInfo queue = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = vk->queue_family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    VkPhysicalDeviceVulkan13Features f13 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .dynamicRendering = VK_TRUE,
        .synchronization2 = VK_TRUE,
        // glslc compiles `discard` into "demote to helper invocation" for
        // Vulkan 1.3 (required by 1.3, but still has to be turned on).
        .shaderDemoteToHelperInvocation = VK_TRUE,
    };
    const char *ext = VK_KHR_SWAPCHAIN_EXTENSION_NAME;
    VkDeviceCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &f13,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue,
        .enabledExtensionCount = 1,
        .ppEnabledExtensionNames = &ext,
    };
    if (!ok(vkCreateDevice(vk->gpu, &info, nullptr, &vk->device), "vkCreateDevice"))
        return false;
    vkGetDeviceQueue(vk->device, vk->queue_family, 0, &vk->queue);
    return true;
}

// --- Memory and buffers ---

// GPU memory comes in types (fast for the GPU, visible to the CPU, ...).
// Find one this resource may live in, with the properties we need.
static bool memory_type(struct vk *vk, uint32_t allowed, VkMemoryPropertyFlags props, uint32_t *out) {
    VkPhysicalDeviceMemoryProperties mem;
    vkGetPhysicalDeviceMemoryProperties(vk->gpu, &mem);
    for (uint32_t i = 0; i < mem.memoryTypeCount; i++)
        if ((allowed & (1u << i)) && (mem.memoryTypes[i].propertyFlags & props) == props) {
            *out = i;
            return true;
        }
    return false;
}

// A buffer the CPU writes (or reads) directly: host-visible and coherent,
// so no flushes are needed, and mapped for its whole life.
[[nodiscard]] static bool make_buffer(struct vk *vk, VkDeviceSize size, VkBufferUsageFlags usage,
                                      struct buffer *b) {
    *b = (struct buffer){.size = size};
    VkBufferCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = usage,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    if (!ok(vkCreateBuffer(vk->device, &info, nullptr, &b->buffer), "vkCreateBuffer"))
        return false;
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(vk->device, b->buffer, &req);
    uint32_t type;
    if (!memory_type(vk, req.memoryTypeBits,
                     VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &type))
        return false;
    VkMemoryAllocateInfo alloc = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size,
        .memoryTypeIndex = type,
    };
    return ok(vkAllocateMemory(vk->device, &alloc, nullptr, &b->memory), "vkAllocateMemory") &&
           ok(vkBindBufferMemory(vk->device, b->buffer, b->memory, 0), "vkBindBufferMemory") &&
           ok(vkMapMemory(vk->device, b->memory, 0, size, 0, &b->map), "vkMapMemory");
}

static void free_buffer(struct vk *vk, struct buffer *b) {
    if (b->buffer != VK_NULL_HANDLE)
        vkDestroyBuffer(vk->device, b->buffer, nullptr);
    if (b->memory != VK_NULL_HANDLE)
        vkFreeMemory(vk->device, b->memory, nullptr);
    *b = (struct buffer){};
}

// An image layout says how an image is about to be used (drawn into,
// sampled, copied, shown); the GPU may store it differently for each. A
// barrier moves it from one to the next, and makes the second use wait
// for the first.
static void transition(VkCommandBuffer cmd, VkImage image, VkImageLayout from, VkImageLayout to,
                       VkPipelineStageFlags2 src_stage, VkAccessFlags2 src_access,
                       VkPipelineStageFlags2 dst_stage, VkAccessFlags2 dst_access) {
    VkImageMemoryBarrier2 barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = src_stage,
        .srcAccessMask = src_access,
        .dstStageMask = dst_stage,
        .dstAccessMask = dst_access,
        .oldLayout = from,
        .newLayout = to,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    VkDependencyInfo dep = {
        .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &barrier,
    };
    vkCmdPipelineBarrier2(cmd, &dep);
}

// --- The swapchain ---

static void destroy_swapchain_views(struct vk *vk) {
    for (uint32_t i = 0; i < vk->image_count; i++) {
        vkDestroyImageView(vk->device, vk->views[i], nullptr);
        vkDestroySemaphore(vk->device, vk->rendered[i], nullptr);
    }
    vk->image_count = 0;
}

// The images the window shows, in turns: we draw into one while another is
// on screen. A new one is needed whenever the window's size changes.
[[nodiscard]] static bool create_swapchain(struct vk *vk) {
    VkSurfaceCapabilitiesKHR caps;
    if (!ok(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(vk->gpu, vk->surface, &caps), "surface caps"))
        return false;
    VkExtent2D extent = caps.currentExtent;
    if (extent.width == UINT32_MAX) {
        // The window lets us choose: its size in pixels.
        int w, h;
        SDL_GetWindowSizeInPixels(vk->window, &w, &h);
        extent = (VkExtent2D){(uint32_t)w, (uint32_t)h};
    }
    if (extent.width == 0 || extent.height == 0)
        return true; // minimized: keep the old one until it has a size again

    // Plain 8-bit RGBA, not sRGB: the same color math as the GL backend.
    uint32_t count = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(vk->gpu, vk->surface, &count, nullptr);
    VkSurfaceFormatKHR formats[64];
    count = count < 64 ? count : 64;
    vkGetPhysicalDeviceSurfaceFormatsKHR(vk->gpu, vk->surface, &count, formats);
    VkSurfaceFormatKHR chosen = formats[0];
    for (uint32_t i = 0; i < count; i++)
        if ((formats[i].format == VK_FORMAT_B8G8R8A8_UNORM || formats[i].format == VK_FORMAT_R8G8B8A8_UNORM) &&
            formats[i].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            chosen = formats[i];
            break;
        }

    // A translucent window shows its alpha to the compositor, premultiplied
    // (as the shaders write it), when the compositor takes that.
    bool translucent = SDL_GetWindowFlags(vk->window) & SDL_WINDOW_TRANSPARENT;
    VkCompositeAlphaFlagBitsKHR composite = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    if (translucent && (caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR))
        composite = VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR;
    else if (!(caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR))
        composite = VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;

    uint32_t images = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && images > caps.maxImageCount)
        images = caps.maxImageCount;
    if (images > max_images)
        images = max_images;
    vk->can_capture = caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_SRC_BIT;

    VkSwapchainKHR old = vk->swapchain;
    VkSwapchainCreateInfoKHR info = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = vk->surface,
        .minImageCount = images,
        .imageFormat = chosen.format,
        .imageColorSpace = chosen.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                      (vk->can_capture ? VK_IMAGE_USAGE_TRANSFER_SRC_BIT : 0),
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = caps.currentTransform,
        .compositeAlpha = composite,
        // FIFO waits for the screen's refresh: vsync, and always supported.
        .presentMode = VK_PRESENT_MODE_FIFO_KHR,
        .clipped = VK_TRUE,
        .oldSwapchain = old,
    };
    if (!ok(vkCreateSwapchainKHR(vk->device, &info, nullptr, &vk->swapchain), "vkCreateSwapchainKHR"))
        return false;
    destroy_swapchain_views(vk);
    if (old != VK_NULL_HANDLE)
        vkDestroySwapchainKHR(vk->device, old, nullptr);

    vk->format = chosen.format;
    vk->extent = extent;
    vk->image_count = max_images;
    vkGetSwapchainImagesKHR(vk->device, vk->swapchain, &vk->image_count, vk->images);
    for (uint32_t i = 0; i < vk->image_count; i++) {
        VkImageViewCreateInfo view = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = vk->images[i],
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .format = vk->format,
            .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
        };
        VkSemaphoreCreateInfo sem = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        if (!ok(vkCreateImageView(vk->device, &view, nullptr, &vk->views[i]), "swapchain view") ||
            !ok(vkCreateSemaphore(vk->device, &sem, nullptr, &vk->rendered[i]), "semaphore"))
            return false;
    }
    vk->stale = false;
    return true;
}

// --- Pipelines ---

[[nodiscard]] static VkShaderModule shader(struct vk *vk, const unsigned char *code, size_t size) {
    VkShaderModuleCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = size,
        .pCode = (const uint32_t *)code,
    };
    VkShaderModule module = VK_NULL_HANDLE;
    (void)ok(vkCreateShaderModule(vk->device, &info, nullptr, &module), "shader module");
    return module;
}

// A pipeline is everything about drawing that GL keeps as changeable state
// (shaders, vertex layout, blending), checked and compiled once. We need
// two: backgrounds (no blending) and glyphs (blended over them).
[[nodiscard]] static bool create_pipelines(struct vk *vk) {
    VkDescriptorSetLayoutBinding atlas = {
        .binding = 0,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    VkDescriptorSetLayoutCreateInfo set_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1,
        .pBindings = &atlas,
    };
    VkPushConstantRange push = {
        .stageFlags = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
        .size = sizeof(struct push),
    };
    if (!ok(vkCreateDescriptorSetLayout(vk->device, &set_info, nullptr, &vk->set_layout), "set layout"))
        return false;
    VkPipelineLayoutCreateInfo layout_info = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &vk->set_layout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push,
    };
    if (!ok(vkCreatePipelineLayout(vk->device, &layout_info, nullptr, &vk->layout), "pipeline layout"))
        return false;

    VkShaderModule vert = shader(vk, cell_vert_spv, sizeof cell_vert_spv);
    VkShaderModule frag = shader(vk, cell_frag_spv, sizeof cell_frag_spv);
    bool good = vert != VK_NULL_HANDLE && frag != VK_NULL_HANDLE;
    VkPipelineShaderStageCreateInfo stages[2] = {
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
         .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vert, .pName = "main"},
        {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
         .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag, .pName = "main"},
    };

    // One struct cell per instance (input rate INSTANCE): the vertex shader
    // makes the four corners itself from gl_VertexIndex.
    VkVertexInputBindingDescription binding = {
        .binding = 0, .stride = sizeof(struct cell), .inputRate = VK_VERTEX_INPUT_RATE_INSTANCE};
    VkVertexInputAttributeDescription attrs[4] = {
        {0, 0, VK_FORMAT_R16_UINT, offsetof(struct cell, slot)},
        {1, 0, VK_FORMAT_R16_UINT, offsetof(struct cell, attrs)},
        {2, 0, VK_FORMAT_R8G8B8A8_UNORM, offsetof(struct cell, fg)},
        {3, 0, VK_FORMAT_R8G8B8A8_UNORM, offsetof(struct cell, bg)},
    };
    VkPipelineVertexInputStateCreateInfo input = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = 1,
        .pVertexBindingDescriptions = &binding,
        .vertexAttributeDescriptionCount = 4,
        .pVertexAttributeDescriptions = attrs,
    };
    VkPipelineInputAssemblyStateCreateInfo assembly = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
    };
    VkPipelineViewportStateCreateInfo viewport = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    };
    VkPipelineRasterizationStateCreateInfo raster = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = VK_POLYGON_MODE_FILL,
        .cullMode = VK_CULL_MODE_NONE,
        .lineWidth = 1.0f,
    };
    VkPipelineMultisampleStateCreateInfo multisample = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
    };
    // The window size changes: viewport and scissor are set per frame.
    VkDynamicState dynamic[2] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dynamic_info = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = 2,
        .pDynamicStates = dynamic,
    };
    // Dynamic rendering: no render pass object, just the color format.
    VkPipelineRenderingCreateInfo rendering = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = &vk->format,
    };

    const VkColorComponentFlags rgba = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                                       VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
    // Glyphs blend as in the GL backend: color "over", alpha kept
    // premultiplied for a translucent window.
    VkPipelineColorBlendAttachmentState blends[2] = {
        {.blendEnable = VK_FALSE, .colorWriteMask = rgba},
        {.blendEnable = VK_TRUE,
         .srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA,
         .dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
         .colorBlendOp = VK_BLEND_OP_ADD,
         .srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE,
         .dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
         .alphaBlendOp = VK_BLEND_OP_ADD,
         .colorWriteMask = rgba},
    };
    VkPipeline *out[2] = {&vk->backgrounds, &vk->glyphs};
    for (int i = 0; i < 2 && good; i++) {
        VkPipelineColorBlendStateCreateInfo blend = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .attachmentCount = 1,
            .pAttachments = &blends[i],
        };
        VkGraphicsPipelineCreateInfo info = {
            .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = &rendering,
            .stageCount = 2,
            .pStages = stages,
            .pVertexInputState = &input,
            .pInputAssemblyState = &assembly,
            .pViewportState = &viewport,
            .pRasterizationState = &raster,
            .pMultisampleState = &multisample,
            .pColorBlendState = &blend,
            .pDynamicState = &dynamic_info,
            .layout = vk->layout,
        };
        good = ok(vkCreateGraphicsPipelines(vk->device, VK_NULL_HANDLE, 1, &info, nullptr, out[i]),
                  "pipeline");
    }
    vkDestroyShaderModule(vk->device, vert, nullptr);
    vkDestroyShaderModule(vk->device, frag, nullptr);
    return good;
}

// --- Commands ---

// Record some commands, run them, and wait: for the rare uploads (a new
// glyph in the atlas), where simple beats fast.
[[nodiscard]] static bool run_now(struct vk *vk, void (*record)(struct vk *, VkCommandBuffer, void *),
                                  void *arg) {
    VkCommandBufferAllocateInfo alloc = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = vk->pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VkCommandBuffer cmd;
    if (!ok(vkAllocateCommandBuffers(vk->device, &alloc, &cmd), "command buffer"))
        return false;
    VkCommandBufferBeginInfo begin = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    vkBeginCommandBuffer(cmd, &begin);
    record(vk, cmd, arg);
    vkEndCommandBuffer(cmd);
    VkCommandBufferSubmitInfo cmd_info = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
                                          .commandBuffer = cmd};
    VkSubmitInfo2 submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
                            .commandBufferInfoCount = 1,
                            .pCommandBufferInfos = &cmd_info};
    bool good = ok(vkQueueSubmit2(vk->queue, 1, &submit, VK_NULL_HANDLE), "submit") &&
                ok(vkQueueWaitIdle(vk->queue), "wait");
    vkFreeCommandBuffers(vk->device, vk->pool, 1, &cmd);
    return good;
}

// --- The atlas ---

struct band {
    int top, rows;
    bool fresh; // the image was just made: its old contents don't matter
};

static void record_atlas_copy(struct vk *vk, VkCommandBuffer cmd, void *arg) {
    const struct band *band = arg;
    transition(cmd, vk->atlas,
               band->fresh ? VK_IMAGE_LAYOUT_UNDEFINED : VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
               VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT, 0,
               VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_WRITE_BIT);
    VkBufferImageCopy region = {
        .bufferOffset = (VkDeviceSize)band->top * (VkDeviceSize)vk->atlas_w * 4,
        .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
        .imageOffset = {0, band->top, 0},
        .imageExtent = {(uint32_t)vk->atlas_w, (uint32_t)band->rows, 1},
    };
    vkCmdCopyBufferToImage(cmd, vk->staging.buffer, vk->atlas, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1,
                           &region);
    transition(cmd, vk->atlas, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
               VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_PIPELINE_STAGE_2_COPY_BIT,
               VK_ACCESS_2_TRANSFER_WRITE_BIT, VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
               VK_ACCESS_2_SHADER_SAMPLED_READ_BIT);
}

static void destroy_atlas(struct vk *vk) {
    if (vk->atlas_view != VK_NULL_HANDLE)
        vkDestroyImageView(vk->device, vk->atlas_view, nullptr);
    if (vk->atlas != VK_NULL_HANDLE)
        vkDestroyImage(vk->device, vk->atlas, nullptr);
    if (vk->atlas_memory != VK_NULL_HANDLE)
        vkFreeMemory(vk->device, vk->atlas_memory, nullptr);
    free_buffer(vk, &vk->staging);
    vk->atlas_view = VK_NULL_HANDLE;
    vk->atlas = VK_NULL_HANDLE;
    vk->atlas_memory = VK_NULL_HANDLE;
}

// The atlas lives in GPU memory the CPU can't see (device-local, fastest
// to sample). New glyphs go through a staging buffer the CPU can write,
// then a copy command.
[[nodiscard]] static bool create_atlas(struct vk *vk, int w, int h) {
    destroy_atlas(vk);
    VkDeviceSize bytes;
    if (ckd_mul(&bytes, (VkDeviceSize)w * (VkDeviceSize)h, (VkDeviceSize)4) ||
        !make_buffer(vk, bytes, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &vk->staging))
        return false;
    VkImageCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .extent = {(uint32_t)w, (uint32_t)h, 1},
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    if (!ok(vkCreateImage(vk->device, &info, nullptr, &vk->atlas), "atlas image"))
        return false;
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(vk->device, vk->atlas, &req);
    uint32_t type;
    if (!memory_type(vk, req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &type))
        return false;
    VkMemoryAllocateInfo alloc = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                  .allocationSize = req.size,
                                  .memoryTypeIndex = type};
    VkImageViewCreateInfo view = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    if (!ok(vkAllocateMemory(vk->device, &alloc, nullptr, &vk->atlas_memory), "atlas memory") ||
        !ok(vkBindImageMemory(vk->device, vk->atlas, vk->atlas_memory, 0), "bind atlas"))
        return false;
    view.image = vk->atlas;
    if (!ok(vkCreateImageView(vk->device, &view, nullptr, &vk->atlas_view), "atlas view"))
        return false;
    vk->atlas_w = w;
    vk->atlas_h = h;

    // Point the shaders' u_atlas at it.
    VkDescriptorImageInfo image = {
        .sampler = vk->sampler,
        .imageView = vk->atlas_view,
        .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
    VkWriteDescriptorSet write = {
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = vk->set,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = &image,
    };
    vkUpdateDescriptorSets(vk->device, 1, &write, 0, nullptr);
    return true;
}

static bool vk_upload_atlas(void *state, const struct atlas *atlas) {
    struct vk *vk = state;
    vk->cell_w = atlas->cell_w;
    vk->cell_h = atlas->cell_h;
    vk->baseline = atlas->baseline;
    vk->line_thickness = atlas->line_thickness;
    vk->atlas_cols = atlas->slots_per_row;

    bool same = vk->atlas != VK_NULL_HANDLE && atlas->generation == vk->atlas_generation &&
                atlas->width == vk->atlas_w && atlas->height == vk->atlas_h;
    if (same && atlas->dirty_top > atlas->dirty_bottom)
        return true; // nothing new

    // The GPU may still be drawing with the atlas or reading the staging
    // buffer: wait. New glyphs are rare; this keeps the uploads simple.
    vkDeviceWaitIdle(vk->device);
    struct band band = {.top = 0, .rows = atlas->height, .fresh = !same};
    if (!same) {
        if (!create_atlas(vk, atlas->width, atlas->height))
            return false;
        vk->atlas_generation = atlas->generation;
    } else {
        band.top = atlas->dirty_top;
        band.rows = atlas->dirty_bottom - atlas->dirty_top + 1;
    }
    size_t row = (size_t)atlas->width * 4;
    memcpy((uint8_t *)vk->staging.map + (size_t)band.top * row, atlas->pixels + (size_t)band.top * row,
           (size_t)band.rows * row);
    return run_now(vk, record_atlas_copy, &band);
}

// --- Setup and teardown ---

static bool vk_configure(void) { return true; }

static void vk_shutdown(void *state);

static void *vk_init(SDL_Window *window) {
    struct vk *vk = calloc(1, sizeof *vk);
    if (vk == nullptr)
        return nullptr;
    vk->window = window;
    if (!create_instance(vk) || !SDL_Vulkan_CreateSurface(window, vk->instance, nullptr, &vk->surface) ||
        !pick_gpu(vk) || !create_device(vk))
        goto fail;

    VkCommandPoolCreateInfo pool = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = vk->queue_family,
    };
    if (!ok(vkCreateCommandPool(vk->device, &pool, nullptr, &vk->pool), "command pool"))
        goto fail;
    for (uint32_t i = 0; i < frames_in_flight; i++) {
        VkCommandBufferAllocateInfo alloc = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = vk->pool,
            .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        // Signaled at first, so the first wait on it doesn't block forever.
        VkFenceCreateInfo fence = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
                                   .flags = VK_FENCE_CREATE_SIGNALED_BIT};
        VkSemaphoreCreateInfo sem = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        if (!ok(vkAllocateCommandBuffers(vk->device, &alloc, &vk->slots[i].cmd), "command buffer") ||
            !ok(vkCreateFence(vk->device, &fence, nullptr, &vk->slots[i].done), "fence") ||
            !ok(vkCreateSemaphore(vk->device, &sem, nullptr, &vk->slots[i].acquired), "semaphore"))
            goto fail;
    }

    VkSamplerCreateInfo sampler = {
        .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = VK_FILTER_NEAREST,
        .minFilter = VK_FILTER_NEAREST,
        .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    };
    VkDescriptorPoolSize size = {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1};
    VkDescriptorPoolCreateInfo dpool = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
                                        .maxSets = 1,
                                        .poolSizeCount = 1,
                                        .pPoolSizes = &size};
    if (!ok(vkCreateSampler(vk->device, &sampler, nullptr, &vk->sampler), "sampler") ||
        !ok(vkCreateDescriptorPool(vk->device, &dpool, nullptr, &vk->descriptor_pool), "descriptor pool") ||
        !create_swapchain(vk) || !create_pipelines(vk))
        goto fail;
    VkDescriptorSetAllocateInfo set = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                                       .descriptorPool = vk->descriptor_pool,
                                       .descriptorSetCount = 1,
                                       .pSetLayouts = &vk->set_layout};
    if (!ok(vkAllocateDescriptorSets(vk->device, &set, &vk->set), "descriptor set"))
        goto fail;
    return vk;
fail:
    vk_shutdown(vk);
    return nullptr;
}

static void vk_shutdown(void *state) {
    struct vk *vk = state;
    if (vk == nullptr)
        return;
    if (vk->device != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(vk->device);
        destroy_atlas(vk);
        free_buffer(vk, &vk->readback);
        for (uint32_t i = 0; i < frames_in_flight; i++) {
            free_buffer(vk, &vk->slots[i].cells);
            if (vk->slots[i].done != VK_NULL_HANDLE)
                vkDestroyFence(vk->device, vk->slots[i].done, nullptr);
            if (vk->slots[i].acquired != VK_NULL_HANDLE)
                vkDestroySemaphore(vk->device, vk->slots[i].acquired, nullptr);
        }
        vkDestroyPipeline(vk->device, vk->backgrounds, nullptr);
        vkDestroyPipeline(vk->device, vk->glyphs, nullptr);
        vkDestroyPipelineLayout(vk->device, vk->layout, nullptr);
        vkDestroyDescriptorPool(vk->device, vk->descriptor_pool, nullptr);
        vkDestroyDescriptorSetLayout(vk->device, vk->set_layout, nullptr);
        vkDestroySampler(vk->device, vk->sampler, nullptr);
        destroy_swapchain_views(vk);
        vkDestroySwapchainKHR(vk->device, vk->swapchain, nullptr);
        vkDestroyCommandPool(vk->device, vk->pool, nullptr);
        vkDestroyDevice(vk->device, nullptr);
    }
    if (vk->surface != VK_NULL_HANDLE)
        SDL_Vulkan_DestroySurface(vk->instance, vk->surface, nullptr);
    if (vk->messenger != VK_NULL_HANDLE) {
        auto destroy = (PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(
            vk->instance, "vkDestroyDebugUtilsMessengerEXT");
        if (destroy != nullptr)
            destroy(vk->instance, vk->messenger, nullptr);
    }
    if (vk->instance != VK_NULL_HANDLE)
        vkDestroyInstance(vk->instance, nullptr);
    if (validation_errors > 0)
        fprintf(stderr, "renderer: vulkan: %d validation errors\n", validation_errors);
    free(vk);
}

static void vk_resize(void *state, int, int) {
    struct vk *vk = state;
    vk->stale = true; // the next frame makes a swapchain of the new size
}

// --- A frame ---

static float unit(uint8_t v) { return (float)v / 255.0f; }

static void fill_push(const struct vk *vk, const struct frame *frame, struct push *p) {
    int cursor = frame->cursor_visible ? frame->cursor_row * frame->cols + frame->cursor_col : -1;
    *p = (struct push){
        .viewport = {(float)vk->extent.width, (float)vk->extent.height},
        .origin = {(float)frame->origin_x, (float)frame->origin_y},
        .cell = {(float)vk->cell_w, (float)vk->cell_h},
        .opacity = frame->opacity,
        .cols = frame->cols,
        .atlas_cols = vk->atlas_cols,
        .cursor = cursor,
        .cursor2 = cursor >= 0 && frame->cursor_wide ? cursor + 1 : -1,
        .rows = frame->rows,
        .first_row_last = frame->first_row_last ? 1 : 0,
        // Underline just below the baseline; strikethrough through the
        // middle of lowercase letters. As in the GL backend.
        .underline_y = vk->baseline + 1,
        .strike_y = vk->baseline - vk->cell_h / 4,
        .line_thickness = vk->line_thickness,
        .cursor_shape = frame->cursor_shape,
        .cursor_color = {unit(frame->cursor_rgb[0]), unit(frame->cursor_rgb[1]), unit(frame->cursor_rgb[2]), 1},
        .accent = {unit(frame->accent_rgb[0]), unit(frame->accent_rgb[1]), unit(frame->accent_rgb[2]), 1},
    };
}

// Copy the drawn image to the readback buffer, for a screenshot.
static void record_capture(struct vk *vk, VkCommandBuffer cmd, VkImage image) {
    transition(cmd, image, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
               VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
               VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_READ_BIT);
    VkBufferImageCopy region = {
        .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
        .imageExtent = {vk->extent.width, vk->extent.height, 1},
    };
    vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, vk->readback.buffer, 1, &region);
    transition(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
               VK_PIPELINE_STAGE_2_COPY_BIT, VK_ACCESS_2_TRANSFER_READ_BIT, VK_PIPELINE_STAGE_2_NONE, 0);
}

static void vk_draw_frame(void *state, const struct frame *frame) {
    struct vk *vk = state;
    if (vk->stale) {
        vkDeviceWaitIdle(vk->device);
        if (!create_swapchain(vk))
            return;
    }
    if (vk->image_count == 0 || vk->atlas == VK_NULL_HANDLE)
        return;

    // Wait until the GPU is done with this slot's previous frame: its
    // command buffer and its cells are about to be reused.
    struct frame_slot *slot = &vk->slots[vk->slot];
    vkWaitForFences(vk->device, 1, &slot->done, VK_TRUE, UINT64_MAX);

    uint32_t index;
    VkResult acquired =
        vkAcquireNextImageKHR(vk->device, vk->swapchain, UINT64_MAX, slot->acquired, VK_NULL_HANDLE, &index);
    if (acquired == VK_ERROR_OUT_OF_DATE_KHR) {
        vk->stale = true;
        return;
    }
    if (acquired != VK_SUCCESS && acquired != VK_SUBOPTIMAL_KHR)
        return;

    size_t ncells = (size_t)frame->cols * frame->rows, bytes;
    if (ckd_mul(&bytes, ncells, sizeof(struct cell)))
        return;
    if (slot->cells.size < bytes) {
        free_buffer(vk, &slot->cells);
        if (!make_buffer(vk, bytes, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, &slot->cells))
            return;
    }
    // Every frame copies all the cells into this slot's buffer: a few
    // hundred kilobytes at most, and simpler than tracking each slot's
    // dirty rows.
    memcpy(slot->cells.map, frame->cells, bytes);

    bool capture = frame->capture != nullptr && vk->can_capture;
    VkDeviceSize capture_bytes = (VkDeviceSize)vk->extent.width * vk->extent.height * 4;
    if (capture && vk->readback.size < capture_bytes) {
        free_buffer(vk, &vk->readback);
        capture = make_buffer(vk, capture_bytes, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &vk->readback);
    }

    vkResetFences(vk->device, 1, &slot->done);
    VkCommandBuffer cmd = slot->cmd;
    vkResetCommandBuffer(cmd, 0);
    VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                      .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
    vkBeginCommandBuffer(cmd, &begin);

    VkImage image = vk->images[index];
    transition(cmd, image, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
               VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, 0,
               VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT);

    // Clear to the padding's color (premultiplied, like everything else).
    float a = frame->opacity;
    VkRenderingAttachmentInfo color = {
        .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .imageView = vk->views[index],
        .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue.color.float32 = {unit(frame->clear_rgb[0]) * a, unit(frame->clear_rgb[1]) * a,
                                     unit(frame->clear_rgb[2]) * a, a},
    };
    VkRenderingInfo rendering = {
        .sType = VK_STRUCTURE_TYPE_RENDERING_INFO,
        .renderArea = {{0, 0}, vk->extent},
        .layerCount = 1,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color,
    };
    vkCmdBeginRendering(cmd, &rendering);
    VkViewport viewport = {0, 0, (float)vk->extent.width, (float)vk->extent.height, 0, 1};
    VkRect2D scissor = {{0, 0}, vk->extent};
    vkCmdSetViewport(cmd, 0, 1, &viewport);
    vkCmdSetScissor(cmd, 0, 1, &scissor);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, vk->layout, 0, 1, &vk->set, 0, nullptr);
    VkDeviceSize offset = 0;
    vkCmdBindVertexBuffers(cmd, 0, 1, &slot->cells.buffer, &offset);

    struct push push;
    fill_push(vk, frame, &push);
    const VkShaderStageFlags stages = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT;
    // Pass 0: backgrounds. Pass 1: glyphs, blended on top.
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, vk->backgrounds);
    vkCmdPushConstants(cmd, vk->layout, stages, 0, sizeof push, &push);
    vkCmdDraw(cmd, 4, (uint32_t)ncells, 0, 0);
    push.pass = 1;
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, vk->glyphs);
    vkCmdPushConstants(cmd, vk->layout, stages, 0, sizeof push, &push);
    vkCmdDraw(cmd, 4, (uint32_t)ncells, 0, 0);
    vkCmdEndRendering(cmd);

    if (capture)
        record_capture(vk, cmd, image);
    else
        transition(cmd, image, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
                   VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
                   VK_PIPELINE_STAGE_2_NONE, 0);
    vkEndCommandBuffer(cmd);

    // Draw once the image is ours (acquired); say when it's drawn
    // (rendered); and signal the slot's fence when the GPU is done.
    VkSemaphoreSubmitInfo wait = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
                                  .semaphore = slot->acquired,
                                  .stageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT};
    VkSemaphoreSubmitInfo signal = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
                                    .semaphore = vk->rendered[index],
                                    .stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT};
    VkCommandBufferSubmitInfo cmd_info = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
                                          .commandBuffer = cmd};
    VkSubmitInfo2 submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .waitSemaphoreInfoCount = 1,
        .pWaitSemaphoreInfos = &wait,
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &cmd_info,
        .signalSemaphoreInfoCount = 1,
        .pSignalSemaphoreInfos = &signal,
    };
    if (!ok(vkQueueSubmit2(vk->queue, 1, &submit, slot->done), "submit"))
        return;

    VkPresentInfoKHR present = {
        .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &vk->rendered[index],
        .swapchainCount = 1,
        .pSwapchains = &vk->swapchain,
        .pImageIndices = &index,
    };
    VkResult shown = vkQueuePresentKHR(vk->queue, &present);
    if (shown == VK_ERROR_OUT_OF_DATE_KHR || shown == VK_SUBOPTIMAL_KHR)
        vk->stale = true;

    if (capture) {
        // Wait for the copy, then hand over RGBA, whatever order the
        // swapchain's format keeps its channels in.
        vkWaitForFences(vk->device, 1, &slot->done, VK_TRUE, UINT64_MAX);
        const uint8_t *src = vk->readback.map;
        bool bgra = vk->format == VK_FORMAT_B8G8R8A8_UNORM;
        for (size_t i = 0; i < (size_t)vk->extent.width * vk->extent.height; i++) {
            frame->capture[i * 4 + 0] = src[i * 4 + (bgra ? 2 : 0)];
            frame->capture[i * 4 + 1] = src[i * 4 + 1];
            frame->capture[i * 4 + 2] = src[i * 4 + (bgra ? 0 : 2)];
            frame->capture[i * 4 + 3] = src[i * 4 + 3];
        }
    }
    vk->slot = (vk->slot + 1) % frames_in_flight;
}

const struct backend renderer_backend = {
    .name = "vulkan",
    .window_flags = SDL_WINDOW_VULKAN,
    .configure = vk_configure,
    .init = vk_init,
    .upload_atlas = vk_upload_atlas,
    .draw_frame = vk_draw_frame,
    .resize = vk_resize,
    .shutdown = vk_shutdown,
};
