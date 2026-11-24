#include <stdbool.h>
#define main geometry_standalone_main
#include "../../../moltenvk/repro/geometry.c"
#undef main

struct target {
  VkImage image;
  VkImageView view;
};
static struct target target(VkFormat format, VkImageUsageFlags usage,
                            VkImageAspectFlags aspect) {
  struct target t;
  VkImageCreateInfo ci = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                          .imageType = VK_IMAGE_TYPE_2D,
                          .format = format,
                          .extent = {32, 32, 1},
                          .mipLevels = 1,
                          .arrayLayers = 1,
                          .samples = VK_SAMPLE_COUNT_1_BIT,
                          .tiling = VK_IMAGE_TILING_OPTIMAL,
                          .usage = usage};
  CK(vkCreateImage(dev, &ci, NULL, &t.image));
  VkMemoryRequirements mr;
  vkGetImageMemoryRequirements(dev, t.image, &mr);
  CK(vkBindImageMemory(dev, t.image,
                       alloc(mr, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT), 0));
  VkImageViewCreateInfo vi = {
      VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = t.image,
      .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = format,
      .subresourceRange = {aspect, 0, 1, 0, 1}};
  CK(vkCreateImageView(dev, &vi, NULL, &t.view));
  return t;
}
int main(int argc, char **argv) {
  if (argc != 2)
    return 2;
  dir = argv[1];
  VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO,
                           .pApplicationName = "Stella renderer test",
                           .apiVersion = VK_API_VERSION_1_3};
  VkInstance instance;
  VkInstanceCreateInfo ic = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                             .pApplicationInfo = &app};
  CK(vkCreateInstance(&ic, NULL, &instance));
  uint32_t n = 1;
  CK(vkEnumeratePhysicalDevices(instance, &n, &pd));
  float priority = 1;
  VkDeviceQueueCreateInfo qi = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                .queueCount = 1, .pQueuePriorities = &priority};
  VkPhysicalDeviceFeatures ft = {
      .depthBounds = VK_TRUE, .wideLines = VK_TRUE, .shaderFloat64 = VK_TRUE};
  VkDeviceCreateInfo dc = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                           .queueCreateInfoCount = 1, .pQueueCreateInfos = &qi,
                           .pEnabledFeatures = &ft};
  CK(vkCreateDevice(pd, &dc, NULL, &dev));
  vkGetDeviceQueue(dev, 0, 0, &queue);
  struct target c = target(VK_FORMAT_R8G8B8A8_UNORM,
                           VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                               VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                           VK_IMAGE_ASPECT_COLOR_BIT);
  struct target z =
      target(VK_FORMAT_D32_SFLOAT, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
             VK_IMAGE_ASPECT_DEPTH_BIT);
  VkAttachmentDescription at[2] = {
      {.format = VK_FORMAT_R8G8B8A8_UNORM,
       .samples = 1,
       .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
       .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
       .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
       .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL},
      {.format = VK_FORMAT_D32_SFLOAT,
       .samples = 1,
       .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
       .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
       .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
       .finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL}};
  VkAttachmentReference cr = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL},
                        zr = {1,
                              VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL};
  VkSubpassDescription sp = {.pipelineBindPoint =
                                 VK_PIPELINE_BIND_POINT_GRAPHICS,
                             .colorAttachmentCount = 1,
                             .pColorAttachments = &cr,
                             .pDepthStencilAttachment = &zr};
  VkRenderPassCreateInfo ri = {VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
                               .attachmentCount = 2, .pAttachments = at,
                               .subpassCount = 1, .pSubpasses = &sp};
  VkRenderPass rp;
  CK(vkCreateRenderPass(dev, &ri, NULL, &rp));
  VkImageView views[] = {c.view, z.view};
  VkFramebuffer fb;
  VkFramebufferCreateInfo fbi = {VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                                 .renderPass = rp,
                                 .attachmentCount = 2,
                                 .pAttachments = views,
                                 .width = 32,
                                 .height = 32,
                                 .layers = 1};
  CK(vkCreateFramebuffer(dev, &fbi, NULL, &fb));
  VkPushConstantRange pc = {VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(float)};
  VkPipelineLayoutCreateInfo li = {
      VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
      .pushConstantRangeCount = 1, .pPushConstantRanges = &pc};
  CK(vkCreatePipelineLayout(dev, &li, NULL, &layout));
  VkPipelineShaderStageCreateInfo st[2] = {
      {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
       .stage = VK_SHADER_STAGE_VERTEX_BIT,
       .module = module("features.vert.spv"), .pName = "main"},
      {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
       .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
       .module = module("features.frag.spv"), .pName = "main"}};
  VkPipelineVertexInputStateCreateInfo vi = {
      VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
  VkPipelineInputAssemblyStateCreateInfo ia = {
      VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
      .topology = VK_PRIMITIVE_TOPOLOGY_LINE_LIST};
  VkViewport vp = {0, 0, 32, 32, 0, 1};
  VkRect2D rect = {{0, 0}, {32, 32}};
  VkPipelineViewportStateCreateInfo vs = {
      VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1,
      .pViewports = &vp, .scissorCount = 1, .pScissors = &rect};
  VkPipelineRasterizationStateCreateInfo rs = {
      VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
      .polygonMode = VK_POLYGON_MODE_FILL,
      .lineWidth = getenv("STATIC_WIDTH") ? 4 : 1};
  VkPipelineMultisampleStateCreateInfo ms = {
      VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
      .rasterizationSamples = 1};
  VkPipelineDepthStencilStateCreateInfo ds = {
      VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
      .depthBoundsTestEnable = !getenv("NO_BOUNDS"), .maxDepthBounds = 1};
  VkPipelineColorBlendAttachmentState ca = {.colorWriteMask = 15};
  VkPipelineColorBlendStateCreateInfo cb = {
      VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
      .attachmentCount = 1, .pAttachments = &ca};
  VkDynamicState dyn[] = {VK_DYNAMIC_STATE_DEPTH_BOUNDS,
                          VK_DYNAMIC_STATE_LINE_WIDTH};
  VkPipelineDynamicStateCreateInfo di = {
      VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
      .dynamicStateCount = getenv("STATIC_WIDTH") ? 1 : 2,
      .pDynamicStates = dyn};
  VkGraphicsPipelineCreateInfo pi = {
      VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
      .stageCount = 2,
      .pStages = st,
      .pVertexInputState = &vi,
      .pInputAssemblyState = &ia,
      .pViewportState = &vs,
      .pRasterizationState = &rs,
      .pMultisampleState = &ms,
      .pDepthStencilState = &ds,
      .pColorBlendState = &cb,
      .pDynamicState = &di,
      .layout = layout,
      .renderPass = rp};
  VkPipeline pipeline;
  CK(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &pi, NULL, &pipeline));
  VkBuffer buf;
  VkBufferCreateInfo bi = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 4096,
                           .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT};
  CK(vkCreateBuffer(dev, &bi, NULL, &buf));
  VkMemoryRequirements br;
  vkGetBufferMemoryRequirements(dev, buf, &br);
  VkDeviceMemory bmem = alloc(br, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                      VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
  CK(vkBindBufferMemory(dev, buf, bmem, 0));
  VkCommandPoolCreateInfo pci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                                 .queueFamilyIndex = 0};
  CK(vkCreateCommandPool(dev, &pci, NULL, &pool));
  VkCommandBuffer cmd;
  VkCommandBufferAllocateInfo cbi = {
      VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
      .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
  CK(vkAllocateCommandBuffers(dev, &cbi, &cmd));
  VkCommandBufferBeginInfo begin = {
      VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
  CK(vkBeginCommandBuffer(cmd, &begin));
  VkClearValue initial[2] = {0};
  initial[1].depthStencil.depth = 0.25f;
  VkRenderPassBeginInfo rbi = {VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                               .renderPass = rp,
                               .framebuffer = fb,
                               .renderArea = rect,
                               .clearValueCount = 2,
                               .pClearValues = initial};
  vkCmdBeginRenderPass(cmd, &rbi, VK_SUBPASS_CONTENTS_INLINE);
  VkClearAttachment clear = {.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT,
                             .clearValue.depthStencil.depth = 0.75f};
  VkClearRect half = {.rect = {{16, 0}, {16, 32}}, .layerCount = 1};
  vkCmdClearAttachments(cmd, 1, &clear, 1, &half);
  vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
  if (!getenv("STATIC_WIDTH"))
    vkCmdSetLineWidth(cmd, 4);
  vkCmdSetDepthBounds(cmd, 0, 0.5f);
  float val = 4097;
  vkCmdPushConstants(cmd, layout, VK_SHADER_STAGE_FRAGMENT_BIT, 0, 4, &val);
  vkCmdDraw(cmd, 2, 1, 0, 0);
  vkCmdEndRenderPass(cmd);
  VkMemoryBarrier mb = {VK_STRUCTURE_TYPE_MEMORY_BARRIER,
                        .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                        .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT};
  vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                       VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, &mb, 0, NULL, 0,
                       NULL);
  VkBufferImageCopy cp = {
      .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
      .imageExtent = {32, 32, 1}};
  vkCmdCopyImageToBuffer(cmd, c.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                         buf, 1, &cp);
  mb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
  mb.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
  vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
                       VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
  CK(vkEndCommandBuffer(cmd));
  VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1,
                     .pCommandBuffers = &cmd};
  CK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
  CK(vkQueueWaitIdle(queue));
  uint8_t *pixels;
  CK(vkMapMemory(dev, bmem, 0, VK_WHOLE_SIZE, 0, (void **)&pixels));
  const bool bounds_enabled = !getenv("NO_BOUNDS");
  int left = 0, right = 0, bad_color = 0, bad_coverage = 0;
  for (int y = 0; y < 32; y++) {
    for (int x = 0; x < 32; x++) {
      const uint8_t *pixel = pixels + (y * 32 + x) * 4;
      const bool expected = y >= 14 && y < 18 && (x < 16 || !bounds_enabled);
      bad_color += pixel[0] != 0;
      bad_coverage += (pixel[1] != 0) != expected;
      if (pixel[1] && x < 16)
        left++;
      if (pixel[1] && x >= 16)
        right++;
    }
  }
  printf("%s width, bounds %s: left %d/64, right %d/%d, incorrect pixels %d, "
         "FP64 failures %d\n",
         getenv("STATIC_WIDTH") ? "static" : "dynamic",
         bounds_enabled ? "on" : "off", left, right, bounds_enabled ? 0 : 64,
         bad_coverage, bad_color);
  return bad_coverage || bad_color;
}
