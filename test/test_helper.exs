# Tests tagged :vulkan need a Vulkan driver (any: lavapipe, Mesa's software
# one, will do). Without one they're skipped, and say so.
vulkan? =
  match?({_, 0}, System.cmd("sh", ["-c", "vulkaninfo --summary"], stderr_to_stdout: true))

unless vulkan?, do: IO.puts("no Vulkan driver (vulkaninfo failed): skipping the :vulkan tests")
ExUnit.start(exclude: if(vulkan?, do: [], else: [:vulkan]))
